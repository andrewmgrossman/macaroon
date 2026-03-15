import Foundation

enum MooVerb: String, Equatable, Sendable {
    case request = "REQUEST"
    case `continue` = "CONTINUE"
    case complete = "COMPLETE"
}

struct MooRequestEnvelope: Equatable, Sendable {
    var requestID: String
    var endpoint: String
    var body: Data?
    var contentType: String?

    init(requestID: String, endpoint: String, body: Data?, contentType: String? = nil) {
        self.requestID = requestID
        self.endpoint = endpoint
        self.body = body
        self.contentType = contentType
    }
}

struct MooResponseEnvelope: Equatable, Sendable {
    var requestID: String?
    var event: String?
    var body: Data?
}

struct MooMessageEnvelope: Equatable, Sendable {
    var verb: MooVerb
    var name: String
    var requestID: String?
    var service: String?
    var headers: [String: String]
    var contentType: String?
    var body: Data?
}

enum MooCodecError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidFirstLine
    case invalidContentLength
    case invalidContentType
    case missingRequestID
}

enum MooCodec {
    static func encode(_ request: MooRequestEnvelope) throws -> Data {
        try encodeMessage(
            verb: .request,
            name: request.endpoint,
            requestID: request.requestID,
            body: request.body,
            contentType: request.contentType
        )
    }

    static func encodeMessage(
        verb: MooVerb,
        name: String,
        requestID: String,
        body: Data?,
        contentType: String?
    ) throws -> Data {
        var lines = [
            "MOO/1 \(verb.rawValue) \(name)",
            "Request-Id: \(requestID)"
        ]

        if let body {
            lines.append("Content-Length: \(body.count)")
            lines.append("Content-Type: \(contentType ?? "application/json")")
        }

        var data = Data((lines.joined(separator: "\n") + "\n\n").utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    static func decode(_ payload: Data) throws -> MooResponseEnvelope {
        let message = try decodeMessage(payload)
        return MooResponseEnvelope(requestID: message.requestID, event: message.name, body: message.body)
    }

    static func decodeMessage(_ payload: Data) throws -> MooMessageEnvelope {
        let headerSeparator = try headerSeparatorRange(in: payload)
        let headerData = payload[..<headerSeparator.lowerBound]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw MooCodecError.invalidHeader
        }

        let lines = headerString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let firstLine = lines.first else {
            throw MooCodecError.invalidHeader
        }

        let components = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components[0] == "MOO/1",
              let verb = MooVerb(rawValue: String(components[1]))
        else {
            throw MooCodecError.invalidFirstLine
        }

        let name = components.dropFirst(2).joined(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw MooCodecError.invalidHeader
            }
            headers[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        guard let requestID = headers["Request-Id"] else {
            throw MooCodecError.missingRequestID
        }

        let contentLength = try parseContentLength(from: headers)
        let contentType = headers["Content-Type"]
        let bodyStart = headerSeparator.upperBound
        let body: Data?
        if let contentLength {
            if contentLength > 0, contentType == nil {
                throw MooCodecError.invalidContentType
            }
            guard bodyStart + contentLength <= payload.endIndex else {
                throw MooCodecError.invalidContentLength
            }
            body = contentLength == 0 ? nil : Data(payload[bodyStart..<(bodyStart + contentLength)])
        } else {
            body = bodyStart < payload.endIndex ? Data(payload[bodyStart...]) : nil
        }

        let service: String?
        if verb == .request {
            let nameParts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            service = nameParts.count == 2 ? String(nameParts[0]) : nil
        } else {
            service = nil
        }

        return MooMessageEnvelope(
            verb: verb,
            name: name,
            requestID: requestID,
            service: service,
            headers: headers,
            contentType: contentType,
            body: body
        )
    }

    private static func headerSeparatorRange(in payload: Data) throws -> Range<Int> {
        if let lfRange = payload.range(of: Data("\n\n".utf8)) {
            return lfRange
        }
        if let crlfRange = payload.range(of: Data("\r\n\r\n".utf8)) {
            return crlfRange
        }
        throw MooCodecError.invalidHeader
    }

    private static func parseContentLength(from headers: [String: String]) throws -> Int? {
        guard let rawValue = headers["Content-Length"] else {
            return nil
        }
        guard let length = Int(rawValue), length >= 0 else {
            throw MooCodecError.invalidContentLength
        }
        return length
    }
}

struct SoodDiscoveryMessage: Equatable, Sendable {
    var uniqueID: String
    var displayName: String
    var host: String
    var port: Int
}

enum SoodCodecError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidVersion
    case invalidLength
}

enum SoodCodec {
    static let serviceID = "00720724-5143-4a9b-abac-0e50cba674bb"
    static let port = 9003
    static let multicastAddress = "239.255.90.90"

    static func discoveryProbe(transactionID: UUID = UUID()) -> Data {
        encode(type: UInt8(ascii: "Q"), properties: [
            "query_service_id": serviceID,
            "_tid": transactionID.uuidString.lowercased()
        ])
    }

    static func decode(_ payload: Data, fromHost host: String, port: Int) throws -> SoodDiscoveryMessage? {
        guard payload.count >= 6, String(decoding: payload.prefix(4), as: UTF8.self) == "SOOD" else {
            throw SoodCodecError.invalidHeader
        }
        guard payload[4] == 2 else {
            throw SoodCodecError.invalidVersion
        }

        let properties = try decodeProperties(in: payload)
        guard properties["service_id"] == serviceID,
              let uniqueID = properties["unique_id"],
              let displayName = properties["display_name"] ?? properties["displayname"],
              let portString = properties["http_port"],
              let httpPort = Int(portString)
        else {
            return nil
        }

        let replyHost = properties["_replyaddr"] ?? host
        return SoodDiscoveryMessage(
            uniqueID: uniqueID,
            displayName: displayName,
            host: replyHost,
            port: httpPort
        )
    }

    private static func encode(type: UInt8, properties: [String: String]) -> Data {
        var data = Data("SOOD".utf8)
        data.append(2)
        data.append(type)

        for key in properties.keys.sorted() {
            guard let value = properties[key] else { continue }
            let keyData = Data(key.utf8)
            let valueData = Data(value.utf8)
            data.append(UInt8(keyData.count))
            data.append(keyData)
            data.append(UInt8((valueData.count >> 8) & 0xff))
            data.append(UInt8(valueData.count & 0xff))
            data.append(valueData)
        }
        return data
    }

    private static func decodeProperties(in payload: Data) throws -> [String: String] {
        var properties: [String: String] = [:]
        var index = 6

        while index < payload.count {
            let nameLength = Int(payload[index])
            index += 1

            guard nameLength > 0, index + nameLength <= payload.count else {
                throw SoodCodecError.invalidLength
            }

            let name = String(decoding: payload[index..<(index + nameLength)], as: UTF8.self)
            index += nameLength

            guard index + 2 <= payload.count else {
                throw SoodCodecError.invalidLength
            }

            let valueLength = (Int(payload[index]) << 8) | Int(payload[index + 1])
            index += 2

            if valueLength == 0xffff {
                properties[name] = ""
                continue
            }

            guard index + valueLength <= payload.count else {
                throw SoodCodecError.invalidLength
            }

            let value = valueLength == 0
                ? ""
                : String(decoding: payload[index..<(index + valueLength)], as: UTF8.self)
            index += valueLength
            properties[name] = value
        }

        return properties
    }
}

struct RoonCoreEndpoint: Equatable, Sendable {
    var host: String
    var port: Int
}

actor RoonDiscoveryClient {
    func start() async {}
    func stop() async {}
}

actor RoonWebSocketTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func connect(to endpoint: RoonCoreEndpoint) async throws {
        await disconnect()

        let session = URLSession(configuration: .ephemeral)
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)/api") else {
            throw URLError(.badURL)
        }

        MacaroonDebugLogger.logProtocol(
            "websocket.connect",
            details: [
                "url": url.absoluteString
            ]
        )
        let task = session.webSocketTask(with: url)
        task.resume()

        self.session = session
        self.task = task
    }

    func disconnect() async {
        MacaroonDebugLogger.logProtocol("websocket.disconnect")
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func send(_ data: Data) async throws {
        guard let task else {
            throw NativeSessionTransportError.unavailable
        }

        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        guard let task else {
            throw NativeSessionTransportError.unavailable
        }

        let message = try await task.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw URLError(.cannotDecodeContentData)
        }
    }

    func sendPing() async throws {
        guard let task else {
            throw NativeSessionTransportError.unavailable
        }
        MacaroonDebugLogger.logProtocol("websocket.ping")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    MacaroonDebugLogger.logError("websocket.ping_failed", error: error)
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
