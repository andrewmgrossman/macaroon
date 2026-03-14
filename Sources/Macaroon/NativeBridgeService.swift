import Foundation

enum NativeBridgeError: LocalizedError, Equatable, Sendable {
    case notImplemented(method: String)

    var errorDescription: String? {
        switch self {
        case let .notImplemented(method):
            return "The experimental native bridge does not implement '\(method)' yet."
        }
    }
}

enum NativeBridgeRuntimeConfiguration {
    static var isEnabled: Bool {
        let rawValue = ProcessInfo.processInfo.environment["MACAROON_EXPERIMENTAL_NATIVE_BRIDGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return rawValue == "1" || rawValue == "true" || rawValue == "yes"
    }
}

@MainActor
final class NativeRoonBridgeService: BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)?

    private var isStarted = false

    func start() async throws {
        isStarted = true
    }

    func stop() async {
        isStarted = false
    }

    func send<Params: Encodable>(_ method: String, params: Params) async throws {
        throw NativeBridgeError.notImplemented(method: method)
    }

    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        throw NativeBridgeError.notImplemented(method: method)
    }
}
