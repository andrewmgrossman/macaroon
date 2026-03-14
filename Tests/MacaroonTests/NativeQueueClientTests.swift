import Foundation
import Testing
@testable import Macaroon

@Suite("NativeQueueClientTests")
struct NativeQueueClientTests {
    @Test
    func subscribedMessageMapsQueueSnapshot() async throws {
        let client = NativeQueueClient()
        let update = try await client.process(
            message: queueMessage(
                verb: .continue,
                name: "Subscribed",
                requestID: "0",
                body: """
                {"zone_id":"zone-1","title":"Up Next","count":2,"now_playing_queue_item_id":"queue-2","items":[{"queue_item_id":"queue-1","three_line":{"line1":"Track One","line2":"Artist One","line3":"Album One"}},{"queue_item_id":"queue-2","three_line":{"line1":"Track Two","line2":"Artist Two","line3":"Album Two"}}]}
                """
            ),
            zoneOrOutputID: "zone-1",
            previousState: nil
        )

        #expect(update?.kind == .snapshot)
        #expect(update?.queue?.zoneID == "zone-1")
        #expect(update?.queue?.title == "Up Next")
        #expect(update?.queue?.currentQueueItemID == "queue-2")
        #expect(update?.queue?.items.count == 2)
        #expect(update?.queue?.items.last?.isCurrent == true)
    }

    @Test
    func changedMessageAppliesIndexedQueueChanges() async throws {
        let client = NativeQueueClient()
        let previous = QueueState(
            zoneID: "zone-2",
            title: "Queue",
            totalCount: 1,
            currentQueueItemID: nil,
            items: [
                QueueItemSummary(
                    queueItemID: "zone-2-item-1",
                    title: "Zone 2 Track 1",
                    subtitle: "Artist",
                    detail: "Album",
                    imageKey: nil,
                    length: nil,
                    isCurrent: false
                )
            ]
        )

        let update = try await client.process(
            message: queueMessage(
                verb: .continue,
                name: "Changed",
                requestID: "0",
                body: """
                {"zone_id":"zone-2","changes":[{"operation":"insert","index":1,"items":[{"queue_item_id":"zone-2-item-2","three_line":{"line1":"Zone 2 Track 2","line2":"Artist","line3":"Album"}}]}]}
                """
            ),
            zoneOrOutputID: "zone-2",
            previousState: previous
        )

        #expect(update?.kind == .changed)
        #expect(update?.queue?.zoneID == "zone-2")
        #expect(update?.queue?.items.map(\.queueItemID) == ["zone-2-item-1", "zone-2-item-2"])
    }

    @Test
    func unsubscribedMessageClearsQueue() async throws {
        let client = NativeQueueClient()
        let update = try await client.process(
            message: queueMessage(
                verb: .complete,
                name: "Unsubscribed",
                requestID: "0",
                body: nil
            ),
            zoneOrOutputID: "zone-1",
            previousState: nil
        )

        #expect(update?.kind == .snapshot)
        #expect(update?.queue == nil)
    }

    @Test
    func playFromHereSendsExpectedPayload() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "0",
                body: nil,
                contentType: nil
            )
        ])
        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeQueueClient()
        try await client.playFromHere(
            session: session,
            zoneOrOutputID: "zone-1",
            queueItemID: "queue-2"
        )

        let sent = await transport.sentMessages()
        let request = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(request.name == "com.roonlabs.transport:2/play_from_here")
        let body = try JSONDecoder().decode(QueuePlayFromHereBody.self, from: try #require(request.body))
        #expect(body.zone_or_output_id == "zone-1")
        #expect(body.queue_item_id == "queue-2")
    }

    @Test
    func subscribedMessageDecodesNumericQueueItemIDsAndLengths() async throws {
        let client = NativeQueueClient()
        let update = try await client.process(
            message: queueMessage(
                verb: .continue,
                name: "Subscribed",
                requestID: "0",
                body: """
                {"items":[{"queue_item_id":44,"length":208,"image_key":"1b6e88d2e47f7f56ed9a2d5696e6b227","one_line":{"line1":"paper tiger - Beck"},"two_line":{"line1":"paper tiger","line2":"Beck"},"three_line":{"line1":"paper tiger","line2":"Beck","line3":"(Beck and the Flaming Lips - October 14, 2002)"}},{"queue_item_id":45,"length":197,"image_key":"1b6e88d2e47f7f56ed9a2d5696e6b227","one_line":{"line1":"it's all in your mind - Beck"},"two_line":{"line1":"it's all in your mind","line2":"Beck"},"three_line":{"line1":"it's all in your mind","line2":"Beck","line3":"(Beck and the Flaming Lips - October 14, 2002)"}}]}
                """
            ),
            zoneOrOutputID: "zone-1",
            previousState: nil
        )

        #expect(update?.queue?.items.map(\.queueItemID) == ["44", "45"])
        #expect(update?.queue?.items.map(\.length) == [208, 197])
        #expect(update?.queue?.items.first?.title == "paper tiger")
    }
}

private func queueMessage(
    verb: MooVerb,
    name: String,
    requestID: String,
    body: String?
) throws -> MooMessageEnvelope {
    try MooCodec.decodeMessage(
        MooCodec.encodeMessage(
            verb: verb,
            name: name,
            requestID: requestID,
            body: body.map { Data($0.utf8) },
            contentType: body == nil ? nil : "application/json"
        )
    )
}

private struct QueuePlayFromHereBody: Decodable {
    var zone_or_output_id: String
    var queue_item_id: String
}
