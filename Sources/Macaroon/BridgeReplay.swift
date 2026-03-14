import Foundation

struct BridgeReplayRecordedLine: Decodable, Sendable {
    var timestamp: String?
    var kind: String
    var payload: String
}

struct BridgeReplayRecordedRequest: Decodable, Sendable {
    var id: UUID
    var method: String
}

enum BridgeReplayEntry: Sendable {
    case outbound(id: UUID, method: String)
    case inbound(BridgeInboundMessage)
}

enum BridgeReplayError: LocalizedError, Equatable, Sendable {
    case invalidTranscriptLine(String)
    case exhaustedTranscript
    case unexpectedRequestOrder(expected: String, received: String)
    case missingResponse(method: String)

    var errorDescription: String? {
        switch self {
        case let .invalidTranscriptLine(line):
            return "Unable to decode replay transcript line: \(line)"
        case .exhaustedTranscript:
            return "The replay transcript was exhausted."
        case let .unexpectedRequestOrder(expected, received):
            return "Replay expected '\(expected)' but received '\(received)'."
        case let .missingResponse(method):
            return "Replay transcript did not contain a response for '\(method)'."
        }
    }
}

struct BridgeReplayTranscript: Sendable {
    let entries: [BridgeReplayEntry]

    static func load(from url: URL) throws -> BridgeReplayTranscript {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        let rawLines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        let entries = try rawLines.map { line in
            let recorded = try decoder.decode(BridgeReplayRecordedLine.self, from: Data(line.utf8))
            switch recorded.kind {
            case "outbound", "request":
                let request = try decoder.decode(BridgeReplayRecordedRequest.self, from: Data(recorded.payload.utf8))
                return BridgeReplayEntry.outbound(id: request.id, method: request.method)
            case "inbound", "response", "event", "error":
                guard let inbound = try BridgeMessageDecoder.decodeInboundMessage(Data(recorded.payload.utf8), decoder: decoder) else {
                    throw BridgeReplayError.invalidTranscriptLine(line)
                }
                return BridgeReplayEntry.inbound(inbound)
            default:
                throw BridgeReplayError.invalidTranscriptLine(line)
            }
        }

        return BridgeReplayTranscript(entries: entries)
    }
}

@MainActor
final class ReplayBridgeService: BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)?

    private let transcript: BridgeReplayTranscript
    private var playbackIndex = 0
    private var pendingResponses: [UUID: CheckedContinuation<Data?, Error>] = [:]

    init(transcript: BridgeReplayTranscript) {
        self.transcript = transcript
    }

    convenience init(transcriptURL: URL) throws {
        try self.init(transcript: BridgeReplayTranscript.load(from: transcriptURL))
    }

    func start() async throws {}

    func stop() async {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        continuations.forEach { $0.resume(throwing: BridgeRuntimeError.processUnavailable) }
    }

    func send<Params: Encodable>(_ method: String, params: Params) async throws {
        let requestID = try claimNextRequest(method: method)
        pumpTranscript()

        if let continuation = pendingResponses.removeValue(forKey: requestID) {
            continuation.resume(returning: nil)
        }
    }

    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        let requestID = try claimNextRequest(method: method)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            pendingResponses[requestID] = continuation
            pumpTranscript()
        }

        if Result.self == EmptyResult.self, response == nil {
            return EmptyResult() as! Result
        }

        guard let response else {
            throw BridgeReplayError.missingResponse(method: method)
        }
        return try JSONDecoder().decode(Result.self, from: response)
    }

    private func claimNextRequest(method: String) throws -> UUID {
        pumpTranscript()

        guard playbackIndex < transcript.entries.count else {
            throw BridgeReplayError.exhaustedTranscript
        }

        guard case let .outbound(id, expectedMethod) = transcript.entries[playbackIndex] else {
            throw BridgeReplayError.exhaustedTranscript
        }

        guard expectedMethod == method else {
            throw BridgeReplayError.unexpectedRequestOrder(expected: expectedMethod, received: method)
        }

        playbackIndex += 1
        return id
    }

    private func pumpTranscript() {
        while playbackIndex < transcript.entries.count {
            switch transcript.entries[playbackIndex] {
            case .outbound:
                return
            case let .inbound(message):
                playbackIndex += 1
                switch message {
                case let .response(id, result, error):
                    guard let continuation = pendingResponses.removeValue(forKey: id) else {
                        continue
                    }

                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                case .event:
                    eventHandler?(message)
                }
            }
        }
    }
}
