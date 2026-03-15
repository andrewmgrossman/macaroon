import Foundation
import Testing
@testable import Macaroon

@Suite("NativeRegistryClientTests")
struct NativeRegistryClientTests {
    @Test
    func savedEndpointConnectPerformsInfoAndRegister() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "0",
                body: Data("""
                {"core_id":"core-1","display_name":"m1mini","display_version":"2.62"}
                """.utf8),
                contentType: "application/json"
            ),
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Registered",
                requestID: "1",
                body: Data("""
                {"core_id":"core-1","display_name":"m1mini","display_version":"2.62","token":"token-2"}
                """.utf8),
                contentType: "application/json"
            )
        ])

        let client = NativeRegistryClient(transportFactory: { transport })
        let persisted = PersistedSessionState(
            pairedCoreID: "core-1",
            tokens: ["core-1": "token-1"],
            endpoints: ["core-1": .init(host: "10.0.7.148", port: 9330)]
        )

        let result = try await client.connectSavedEndpoint(
            endpoint: CoreEndpoint(host: "10.0.7.148", port: 9330),
            persistedState: persisted
        )

        #expect(result.core.displayName == "m1mini")
        #expect(result.persistedState.tokens["core-1"] == "token-2")

        let sent = await transport.sentMessages()
        #expect(sent.count == 2)

        let infoRequest = try MooCodec.decodeMessage(sent[0])
        #expect(infoRequest.name == "com.roonlabs.registry:1/info")

        let registerRequest = try MooCodec.decodeMessage(sent[1])
        #expect(registerRequest.name == "com.roonlabs.registry:1/register")
        let body = try JSONDecoder().decode(NativeRegistryExtensionIdentity.self, from: try #require(registerRequest.body))
        #expect(body.token == "token-1")
        #expect(body.required_services == [
            "com.roonlabs.browse:1",
            "com.roonlabs.image:1",
            "com.roonlabs.transport:2"
        ])
        #expect(body.provided_services.contains("com.roonlabs.pairing:1"))
    }

    @Test
    func manualConnectWithoutAuthorizationRaisesAuthorizationRequired() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "0",
                body: Data("""
                {"core_id":"core-1","display_name":"m1mini","display_version":"2.62"}
                """.utf8),
                contentType: "application/json"
            ),
            try MooCodec.encodeMessage(
                verb: .continue,
                name: "Unauthorized",
                requestID: "1",
                body: Data("""
                {"message":"authorize first"}
                """.utf8),
                contentType: "application/json"
            )
        ])

        let client = NativeRegistryClient(transportFactory: { transport })

        await #expect(throws: NativeRegistryError.authorizationRequired(CoreSummary(
            coreID: "core-1",
            displayName: "m1mini",
            displayVersion: "2.62",
            host: "10.0.7.148",
            port: 9330
        ))) {
            _ = try await client.connectManual(
                host: "10.0.7.148",
                port: 9330,
                persistedState: .empty
            )
        }

        let sent = await transport.sentMessages()
        #expect(sent.count == 2)
        let registerRequest = try MooCodec.decodeMessage(sent[1])
        #expect(registerRequest.name == "com.roonlabs.registry:1/register")
    }

    @Test
    func mooSessionDeliversSubscriptionMessages() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .continue,
                name: "Subscribed",
                requestID: "0",
                body: Data("""
                {"zones":[{"zone_id":"zone-1","display_name":"Desk","state":"paused","outputs":[],"is_previous_allowed":true,"is_next_allowed":true,"is_pause_allowed":false,"is_play_allowed":true,"is_seek_allowed":true}]}
                """.utf8),
                contentType: "application/json"
            )
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        let collector = MessageCollector()
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))
        try await session.subscribe(
            "com.roonlabs.transport:2/subscribe_zones",
            body: ["subscription_key": 0]
        ) { message in
            Task {
                await collector.append(message)
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        let received = await collector.messages()
        #expect(received.count == 1)
        #expect(received.first?.name == "Subscribed")

        let sent = await transport.sentMessages()
        let subscribeRequest = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(subscribeRequest.name == "com.roonlabs.transport:2/subscribe_zones")
    }
}

actor MockNativeMooTransport: NativeMooTransportProtocol {
    private var queuedMessages: [Data]
    private var availableMessages: [Data] = []
    private var waitingContinuations: [CheckedContinuation<Data, Error>] = []
    private var sent: [Data] = []
    private(set) var connectedEndpoint: RoonCoreEndpoint?

    init(messages: [Data]) {
        self.queuedMessages = messages
    }

    func connect(to endpoint: RoonCoreEndpoint) async throws {
        connectedEndpoint = endpoint
    }

    func disconnect() async {}

    func pushIncoming(_ data: Data) {
        if waitingContinuations.isEmpty == false {
            let continuation = waitingContinuations.removeFirst()
            continuation.resume(returning: data)
        } else {
            availableMessages.append(data)
        }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        guard queuedMessages.isEmpty == false else {
            return
        }

        let next = queuedMessages.removeFirst()
        if waitingContinuations.isEmpty == false {
            let continuation = waitingContinuations.removeFirst()
            continuation.resume(returning: next)
        } else {
            availableMessages.append(next)
        }
    }

    func receive() async throws -> Data {
        if availableMessages.isEmpty == false {
            return availableMessages.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func sentMessages() -> [Data] {
        sent
    }
}

actor MessageCollector {
    private var storedMessages: [MooMessageEnvelope] = []

    func append(_ message: MooMessageEnvelope) {
        storedMessages.append(message)
    }

    func messages() -> [MooMessageEnvelope] {
        storedMessages
    }
}
