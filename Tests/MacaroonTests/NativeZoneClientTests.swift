import Foundation
import Testing
@testable import Macaroon

@Suite("NativeZoneClientTests")
struct NativeZoneClientTests {
    @Test
    func subscribedMessageMapsZoneSnapshot() async throws {
        let client = NativeZoneClient()
        let update = try await client.process(
            message: try zoneMessage(
                name: "Subscribed",
                body: """
                {"zones":[{"zone_id":"zone-1","display_name":"Desk","state":"playing","outputs":[{"output_id":"output-1","zone_id":"zone-1","display_name":"DAC","volume":{"type":"number","min":0,"max":100,"value":41,"is_muted":false}}],"is_previous_allowed":true,"is_next_allowed":true,"is_pause_allowed":true,"is_play_allowed":true,"is_seek_allowed":true,"now_playing":{"three_line":{"line1":"Track","line2":"Artist","line3":"Album"},"seek_position":12,"length":200,"image_key":"image-1"}}]}
                """
            ),
            previousZonesByID: [:]
        )

        #expect(update?.kind == .snapshot)
        #expect(update?.zones.map(\.zoneID) == ["zone-1"])
        #expect(update?.zones.first?.nowPlaying?.title == "Track")
        #expect(update?.zones.first?.outputs.first?.volume?.value == 41)
        #expect(update?.liveZonesByID["zone-1"]?.displayName == "Desk")
    }

    @Test
    func changedMessageAppliesChangedRemovedAndSeekUpdates() async throws {
        let client = NativeZoneClient()
        let previous = [
            "zone-1": ZoneSummary(
                zoneID: "zone-1",
                displayName: "Desk",
                state: "playing",
                outputs: [],
                capabilities: .unavailable,
                nowPlaying: NowPlaying(
                    title: "Track",
                    subtitle: "Artist",
                    detail: "Album",
                    imageKey: nil,
                    seekPosition: 12,
                    length: 200,
                    lines: nil
                )
            ),
            "zone-old": ZoneSummary(
                zoneID: "zone-old",
                displayName: "Old",
                state: "paused",
                outputs: [],
                capabilities: .unavailable,
                nowPlaying: nil
            )
        ]

        let update = try await client.process(
            message: try zoneMessage(
                name: "Changed",
                body: """
                {"zones_removed":["zone-old"],"zones_added":[{"zone_id":"zone-2","display_name":"Living Room","state":"paused","outputs":[],"is_previous_allowed":false,"is_next_allowed":true,"is_pause_allowed":false,"is_play_allowed":true,"is_seek_allowed":false}],"zones_seek_changed":[{"zone_id":"zone-1","seek_position":13}]}
                """
            ),
            previousZonesByID: previous
        )

        #expect(update?.kind == .changed)
        #expect(update?.removedZoneIDs == ["zone-old"])
        #expect(update?.zones.map(\.zoneID).sorted() == ["zone-1", "zone-2"])
        #expect(update?.liveZonesByID["zone-old"] == nil)
        #expect(update?.liveZonesByID["zone-1"]?.nowPlaying?.seekPosition == 13)
        #expect(update?.liveZonesByID["zone-2"]?.displayName == "Living Room")
    }

    @Test
    func invalidZonePayloadThrowsDecodeFailure() async throws {
        let client = NativeZoneClient()

        await #expect(throws: (any Error).self) {
            _ = try await client.process(
                message: try zoneMessage(
                    name: "Subscribed",
                    body: """
                    {"zones":[{"zone_id":42}]}
                    """
                ),
                previousZonesByID: [:]
            )
        }
    }
}

private func zoneMessage(name: String, body: String) throws -> MooMessageEnvelope {
    try MooCodec.decodeMessage(MooCodec.encodeMessage(
        verb: .continue,
        name: name,
        requestID: "0",
        body: Data(body.utf8),
        contentType: "application/json"
    ))
}
