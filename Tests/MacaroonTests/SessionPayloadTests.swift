import Foundation
import Testing
@testable import Macaroon

struct SessionPayloadTests {
    @Test
    func connectionStatusPayloadRoundTrip() throws {
        let payload = ConnectionStatusPayload.connected(
            CoreSummary(
                coreID: "core-1",
                displayName: "Primary Core",
                displayVersion: "2.0",
                host: "192.168.1.4",
                port: 9100
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionStatusPayload.self, from: data)

        #expect(decoded == payload)
    }

    @Test
    func browseListChangedEventRoundTrip() throws {
        let event = BrowseListChangedEvent(page: BrowsePage(
            hierarchy: .browse,
            list: BrowseList(
                title: "Library",
                subtitle: "All music",
                count: 2,
                level: 0,
                displayOffset: 0,
                hint: nil
            ),
            items: [
                BrowseItem(
                    title: "Albums",
                    subtitle: "42 items",
                    imageKey: nil,
                    itemKey: "albums",
                    hint: "list",
                    inputPrompt: nil
                )
            ],
            offset: 0,
            selectedZoneID: "zone-1"
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BrowseListChangedEvent.self, from: data)

        #expect(decoded.page.items.count == 1)
        #expect(decoded.page.list.title == "Library")
    }
}
