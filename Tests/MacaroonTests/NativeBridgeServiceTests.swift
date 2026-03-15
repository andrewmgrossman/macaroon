import Foundation
import Testing
@testable import Macaroon

@Suite("NativeBridgeServiceTests")
struct NativeBridgeServiceTests {
    @Test
    @MainActor
    func requestThrowsNotImplemented() async {
        let service = NativeRoonBridgeService()

        await #expect(throws: NativeBridgeError.notImplemented(method: "connect.auto")) {
            _ = try await service.request(
                "connect.auto",
                params: ConnectAutoParams(persistedState: .empty),
                as: EmptyResult.self
            )
        }
    }

    @Test
    func nativeBridgeDefaultsOn() {
        #expect(NativeBridgeRuntimeConfiguration.isEnabled == true)
    }

    @Test
    @MainActor
    func imageFetchFailsWithoutConnectedCore() async {
        let service = NativeRoonBridgeService()

        await #expect(throws: NativeImageError.missingCoreEndpoint) {
            _ = try await service.request(
                "image.fetch",
                params: ImageFetchParams(
                    imageKey: "image-key",
                    width: 104,
                    height: 104,
                    format: "image/jpeg"
                ),
                as: ImageFetchedResult.self
            )
        }
    }

    @Test
    @MainActor
    func transportCommandRoutesThroughBridgeAfterConnect() async throws {
        let transport = MockNativeMooTransport(messages: [
            try registryInfoMessage(requestID: "0"),
            try registryRegisteredMessage(requestID: "1"),
            try bridgeSuccessMessage(requestID: "2")
        ])
        let registryClient = NativeRegistryClient(transportFactory: { transport })
        let service = NativeRoonBridgeService(registryClient: registryClient)

        try await service.send(
            "connect.manual",
            params: ConnectManualParams(
                host: "10.0.7.148",
                port: 9330,
                persistedState: .empty
            )
        )
        try await service.send(
            "transport.command",
            params: TransportCommandParams(
                zoneOrOutputID: "zone-1",
                command: .playPause
            )
        )

        let sent = try await decodedSentMessages(from: transport)
        #expect(sent.count == 3)
        #expect(sent[2].name == "com.roonlabs.transport:2/control")
    }

    @Test
    @MainActor
    func imageFetchUsesConnectedCoreAndDisconnectClearsState() async throws {
        let transport = MockNativeMooTransport(messages: [
            try registryInfoMessage(requestID: "0"),
            try registryRegisteredMessage(requestID: "1")
        ])
        let registryClient = NativeRegistryClient(transportFactory: { transport })
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-native-bridge-image-\(UUID().uuidString)", isDirectory: true)
        let settingsStore = ArtworkCacheSettingsStore(defaults: UserDefaults(suiteName: "macaroon-native-bridge-image-\(UUID().uuidString)")!)
        let cacheStore = ArtworkCacheStore(
            directoryURL: cacheDirectory,
            settingsStore: settingsStore
        )
        let imageClient = NativeImageClient(
            fetch: { _ in
                NativeImageFetchResponse(contentType: "image/jpeg", data: Data("image".utf8))
            },
            cacheStore: cacheStore
        )
        let service = NativeRoonBridgeService(
            registryClient: registryClient,
            imageClient: imageClient
        )

        try await service.send(
            "connect.manual",
            params: ConnectManualParams(
                host: "10.0.7.148",
                port: 9330,
                persistedState: .empty
            )
        )

        let result = try await service.request(
            "image.fetch",
            params: ImageFetchParams(
                imageKey: "image-key",
                width: 104,
                height: 104,
                format: "image/jpeg"
            ),
            as: ImageFetchedResult.self
        )
        #expect(FileManager.default.fileExists(atPath: result.localURL))

        try await service.send("core.disconnect", params: DisconnectParams())

        await #expect(throws: NativeImageError.missingCoreEndpoint) {
            _ = try await service.request(
                "image.fetch",
                params: ImageFetchParams(
                    imageKey: "image-key",
                    width: 104,
                    height: 104,
                    format: "image/jpeg"
                ),
                as: ImageFetchedResult.self
            )
        }
    }

    @Test
    @MainActor
    func queueSubscribeIgnoresStaleCallbacksAndEmitsCurrentZoneEvents() async throws {
        let transport = MockNativeMooTransport(messages: [
            try registryInfoMessage(requestID: "0"),
            try registryRegisteredMessage(requestID: "1"),
            try queueSubscribedMessage(requestID: "2", zoneID: "zone-1", title: "Queue 1", items: [
                ("zone-1-item-1", "Zone 1 Track 1")
            ]),
            try queueSubscribedMessage(requestID: "3", zoneID: "zone-2", title: "Queue 2", items: [
                ("zone-2-item-1", "Zone 2 Track 1")
            ])
        ])
        let registryClient = NativeRegistryClient(transportFactory: { transport })
        let service = NativeRoonBridgeService(registryClient: registryClient)

        var events: [BridgeEventEnvelope] = []
        service.eventHandler = { message in
            guard case let .event(event) = message else {
                return
            }
            events.append(event)
        }

        try await service.send(
            "connect.manual",
            params: ConnectManualParams(
                host: "10.0.7.148",
                port: 9330,
                persistedState: .empty
            )
        )
        try await service.send(
            "queue.subscribe",
            params: QueueSubscribeParams(zoneOrOutputID: "zone-1", maxItemCount: 300)
        )
        try await service.send(
            "queue.subscribe",
            params: QueueSubscribeParams(zoneOrOutputID: "zone-2", maxItemCount: 300)
        )

        await transport.pushIncoming(try MooCodec.encodeMessage(
            verb: .continue,
            name: "Changed",
            requestID: "2",
            body: Data("""
            {"zone_id":"zone-1","changes":[{"operation":"insert","index":1,"items":[{"queue_item_id":"zone-1-item-2","three_line":{"line1":"Stale Zone 1 Track 2","line2":"Artist","line3":"Album"}}]}]}
            """.utf8),
            contentType: "application/json"
        ))
        await transport.pushIncoming(try MooCodec.encodeMessage(
            verb: .continue,
            name: "Changed",
            requestID: "3",
            body: Data("""
            {"zone_id":"zone-2","changes":[{"operation":"insert","index":1,"items":[{"queue_item_id":"zone-2-item-2","three_line":{"line1":"Zone 2 Track 2","line2":"Artist","line3":"Album"}}]}]}
            """.utf8),
            contentType: "application/json"
        ))

        try await Task.sleep(for: .milliseconds(50))

        let queueSnapshots = events.compactMap { event -> QueueState? in
            guard case let .queueSnapshot(payload) = event else {
                return nil
            }
            return payload.queue
        }
        let queueChanges = events.compactMap { event -> QueueState? in
            guard case let .queueChanged(payload) = event else {
                return nil
            }
            return payload.queue
        }

        #expect(queueSnapshots.last?.zoneID == "zone-2")
        #expect(queueSnapshots.last?.items.map(\.queueItemID) == ["zone-2-item-1"])
        #expect(queueChanges.count == 1)
        #expect(queueChanges.last?.zoneID == "zone-2")
        #expect(queueChanges.last?.items.map(\.queueItemID) == ["zone-2-item-1", "zone-2-item-2"])

        let sent = try await decodedSentMessages(from: transport)
        let firstQueueBody = try JSONDecoder().decode(QueueSubscribeBody.self, from: try #require(sent[2].body))
        let secondQueueBody = try JSONDecoder().decode(QueueSubscribeBody.self, from: try #require(sent[3].body))
        #expect(firstQueueBody.zone_or_output_id == "zone-1")
        #expect(firstQueueBody.max_item_count == 300)
        #expect(firstQueueBody.subscription_key == 1)
        #expect(secondQueueBody.zone_or_output_id == "zone-2")
        #expect(secondQueueBody.max_item_count == 300)
        #expect(secondQueueBody.subscription_key == 2)
    }

    @Test
    @MainActor
    func zonesChangedDeduplicatesZoneIDsAcrossSeekUpdates() async throws {
        let transport = MockNativeMooTransport(messages: [
            try registryInfoMessage(requestID: "0"),
            try registryRegisteredMessage(requestID: "1"),
            try zonesSubscribedMessage(requestID: "2")
        ])
        let registryClient = NativeRegistryClient(transportFactory: { transport })
        let service = NativeRoonBridgeService(registryClient: registryClient)

        var events: [BridgeEventEnvelope] = []
        service.eventHandler = { message in
            guard case let .event(event) = message else {
                return
            }
            events.append(event)
        }

        try await service.send(
            "connect.manual",
            params: ConnectManualParams(
                host: "10.0.7.148",
                port: 9330,
                persistedState: .empty
            )
        )
        try await service.send("zones.subscribe", params: ZonesSubscribeParams())

        await transport.pushIncoming(try MooCodec.encodeMessage(
            verb: .continue,
            name: "Changed",
            requestID: "2",
            body: Data("""
            {"zones_changed":[{"zone_id":"zone-1","display_name":"Desk","state":"playing","outputs":[],"is_previous_allowed":true,"is_next_allowed":true,"is_pause_allowed":true,"is_play_allowed":true,"is_seek_allowed":true,"now_playing":{"three_line":{"line1":"Track","line2":"Artist","line3":"Album"},"seek_position":12,"length":200}}],"zones_seek_changed":[{"zone_id":"zone-1","seek_position":13}]}
            """.utf8),
            contentType: "application/json"
        ))

        try await Task.sleep(for: .milliseconds(50))

        let zoneChangedEvents = events.compactMap { event -> [ZoneSummary]? in
            guard case let .zonesChanged(payload) = event else {
                return nil
            }
            return payload.zones
        }
        #expect(zoneChangedEvents.last?.count == 1)
        #expect(zoneChangedEvents.last?.first?.zoneID == "zone-1")
        #expect(zoneChangedEvents.last?.first?.nowPlaying?.seekPosition == 13)
    }
}

private func decodedSentMessages(from transport: MockNativeMooTransport) async throws -> [MooMessageEnvelope] {
    let rawSent = await transport.sentMessages()
    return try rawSent.map { try MooCodec.decodeMessage($0) }
}

private func registryInfoMessage(requestID: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .complete,
        name: "Success",
        requestID: requestID,
        body: Data("""
        {"core_id":"core-1","display_name":"m1mini","display_version":"2.62"}
        """.utf8),
        contentType: "application/json"
    )
}

private func registryRegisteredMessage(requestID: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .complete,
        name: "Registered",
        requestID: requestID,
        body: Data("""
        {"core_id":"core-1","display_name":"m1mini","display_version":"2.62","token":"token-1"}
        """.utf8),
        contentType: "application/json"
    )
}

private func bridgeSuccessMessage(requestID: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .complete,
        name: "Success",
        requestID: requestID,
        body: nil,
        contentType: nil
    )
}

private func queueSubscribedMessage(
    requestID: String,
    zoneID: String,
    title: String,
    items: [(String, String)]
) throws -> Data {
    let itemJSON = items.map { itemID, title in
        """
        {"queue_item_id":"\(itemID)","three_line":{"line1":"\(title)","line2":"Artist","line3":"Album"}}
        """
    }.joined(separator: ",")

    return try MooCodec.encodeMessage(
        verb: .continue,
        name: "Subscribed",
        requestID: requestID,
        body: Data("""
        {"zone_id":"\(zoneID)","title":"\(title)","count":\(items.count),"items":[\(itemJSON)]}
        """.utf8),
        contentType: "application/json"
    )
}

private func zonesSubscribedMessage(requestID: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .continue,
        name: "Subscribed",
        requestID: requestID,
        body: Data("""
        {"zones":[{"zone_id":"zone-1","display_name":"Desk","state":"paused","outputs":[],"is_previous_allowed":true,"is_next_allowed":true,"is_pause_allowed":false,"is_play_allowed":true,"is_seek_allowed":true}]}
        """.utf8),
        contentType: "application/json"
    )
}

private struct QueueSubscribeBody: Decodable {
    var zone_or_output_id: String
    var max_item_count: Int
    var subscription_key: Int
}
