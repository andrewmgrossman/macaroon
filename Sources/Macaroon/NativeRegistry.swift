import Foundation

struct NativeRegistryConnectionResult: Equatable, Sendable {
    var core: CoreSummary
    var persistedState: PersistedSessionState
}

enum NativeRegistryError: LocalizedError, Equatable, Sendable {
    case unsupportedAutoConnect
    case unsupportedResponse(String)
    case authorizationRequired(CoreSummary?)

    var errorDescription: String? {
        switch self {
        case .unsupportedAutoConnect:
            return "The native bridge only supports saved-endpoint or manual websocket connection right now."
        case let .unsupportedResponse(name):
            return "The Roon registry responded with an unsupported result: \(name)."
        case let .authorizationRequired(core):
            if let core {
                return "Authorization is still required for \(core.displayName)."
            }
            return "Authorization is still required."
        }
    }
}

protocol NativeMooTransportProtocol: Actor {
    func connect(to endpoint: RoonCoreEndpoint) async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}

extension RoonWebSocketTransport: NativeMooTransportProtocol {}

struct NativeRegistryExtensionIdentity: Codable, Sendable {
    var extension_id: String
    var display_name: String
    var display_version: String
    var publisher: String
    var email: String
    var website: String
    var required_services: [String]
    var optional_services: [String]
    var provided_services: [String]
    var token: String?

    static func macaroon(token: String?) -> NativeRegistryExtensionIdentity {
        NativeRegistryExtensionIdentity(
            extension_id: "com.andrewmg.macaroon",
            display_name: "Macaroon",
            display_version: "0.1.0",
            publisher: "Andrew McG",
            email: "andrew@example.com",
            website: "https://example.invalid/macaroon",
            required_services: [
                "com.roonlabs.browse:1",
                "com.roonlabs.image:1",
                "com.roonlabs.transport:2"
            ],
            optional_services: [],
            provided_services: [
                "com.roonlabs.pairing:1",
                "com.roonlabs.ping:1"
            ],
            token: token
        )
    }
}

private struct NativeRegistryInfoResponse: Codable {
    var core_id: String
    var display_name: String
    var display_version: String
}

private struct NativeRegistryRegisterResponse: Codable {
    var core_id: String
    var display_name: String
    var display_version: String
    var token: String
}

private actor NativeRegistryRegisterAwaiter {
    private var firstMessage: MooMessageEnvelope?
    private var continuation: CheckedContinuation<MooMessageEnvelope, Never>?

    func yield(_ message: MooMessageEnvelope) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: message)
        } else if firstMessage == nil {
            firstMessage = message
        }
    }

    func firstResponse() async -> MooMessageEnvelope {
        if let firstMessage {
            return firstMessage
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

struct NativePairingStatePayload: Codable {
    var paired_core_id: String?
}

actor NativeRegistryClient {
    private let transportFactory: @Sendable () -> any NativeMooTransportProtocol
    private var session: NativeMooSession?

    init(transportFactory: @escaping @Sendable () -> any NativeMooTransportProtocol = { RoonWebSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    func activeSession() -> NativeMooSession? {
        session
    }

    func connectSavedEndpoint(
        endpoint: CoreEndpoint,
        persistedState: PersistedSessionState
    ) async throws -> NativeRegistryConnectionResult {
        guard let pairedCoreID = persistedState.pairedCoreID,
              persistedState.endpoints[pairedCoreID] != nil
        else {
            throw NativeRegistryError.unsupportedAutoConnect
        }

        return try await connect(
            endpoint: RoonCoreEndpoint(host: endpoint.host, port: endpoint.port),
            token: persistedState.tokens[pairedCoreID],
            persistedState: persistedState
        )
    }

    func connectManual(
        host: String,
        port: Int,
        persistedState: PersistedSessionState
    ) async throws -> NativeRegistryConnectionResult {
        return try await connect(
            endpoint: RoonCoreEndpoint(host: host, port: port),
            token: nil,
            persistedState: persistedState
        )
    }

    func disconnect() async {
        await session?.disconnect()
        session = nil
    }

    private func connect(
        endpoint: RoonCoreEndpoint,
        token: String?,
        persistedState: PersistedSessionState
    ) async throws -> NativeRegistryConnectionResult {
        await disconnect()

        let session = NativeMooSession(
            transportFactory: transportFactory,
            currentPairedCoreID: persistedState.pairedCoreID
        )
        self.session = session
        try await session.connect(to: endpoint)

        let infoMessage = try await session.request(
            "com.roonlabs.registry:1/info",
            body: Optional<EmptyParams>.none
        )
        let infoResponse = try decodeBody(NativeRegistryInfoResponse.self, from: infoMessage)
        await session.setCurrentCoreID(infoResponse.core_id)

        let registerBody = NativeRegistryExtensionIdentity.macaroon(token: token)
        let registerAwaiter = NativeRegistryRegisterAwaiter()
        try await session.observeRequest(
            "com.roonlabs.registry:1/register",
            body: registerBody
        ) { message in
            Task {
                await registerAwaiter.yield(message)
            }
        }
        let registerMessage = await registerAwaiter.firstResponse()

        guard registerMessage.name == "Registered" else {
            let core = CoreSummary(
                coreID: infoResponse.core_id,
                displayName: infoResponse.display_name,
                displayVersion: infoResponse.display_version,
                host: endpoint.host,
                port: endpoint.port
            )
            throw NativeRegistryError.authorizationRequired(core)
        }

        let registerResponse = try decodeBody(NativeRegistryRegisterResponse.self, from: registerMessage)
        let nextPairedCoreID = persistedState.pairedCoreID ?? registerResponse.core_id
        let nextPersistedState = PersistedSessionState(
            pairedCoreID: nextPairedCoreID,
            tokens: persistedState.tokens.merging([registerResponse.core_id: registerResponse.token]) { _, new in new },
            endpoints: persistedState.endpoints.merging([
                registerResponse.core_id: CoreEndpoint(host: endpoint.host, port: endpoint.port)
            ]) { _, new in new }
        )
        await session.setCurrentPairedCoreID(nextPersistedState.pairedCoreID)

        return NativeRegistryConnectionResult(
            core: CoreSummary(
                coreID: registerResponse.core_id,
                displayName: registerResponse.display_name,
                displayVersion: registerResponse.display_version,
                host: endpoint.host,
                port: endpoint.port
            ),
            persistedState: nextPersistedState
        )
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, from message: MooMessageEnvelope) throws -> T {
        guard let body = message.body else {
            throw NativeRegistryError.unsupportedResponse(message.name)
        }
        return try JSONDecoder().decode(T.self, from: body)
    }
}
