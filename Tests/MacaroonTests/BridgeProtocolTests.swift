import Foundation
import Testing
@testable import Macaroon

struct BridgeProtocolTests {
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
    func decodesBrowseListChangedEvent() throws {
        let json = """
        {
          "event": "browse.listChanged",
          "payload": {
            "page": {
              "hierarchy": "browse",
              "list": {
                "title": "Library",
                "subtitle": "All music",
                "count": 2,
                "level": 0,
                "displayOffset": 0,
                "hint": null
              },
              "items": [
                {
                  "title": "Albums",
                  "subtitle": "42 items",
                  "imageKey": null,
                  "itemKey": "albums",
                  "hint": "list",
                  "inputPrompt": null
                }
              ],
              "offset": 0,
              "selectedZoneID": "zone-1"
            }
          }
        }
        """

        let event = try JSONDecoder().decode(BridgeEvent<BrowseListChangedEvent>.self, from: Data(json.utf8))

        #expect(event.event == "browse.listChanged")
        #expect(event.payload.page.items.count == 1)
        #expect(event.payload.page.list.title == "Library")
    }
}
