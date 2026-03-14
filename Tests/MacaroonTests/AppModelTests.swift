import Foundation
import Testing
@testable import Macaroon

@Suite("AppModelTests")
@MainActor
struct AppModelTests {
    @Test
    func performPreferredActionDirectlyExecutesInternetRadioActionItems() async throws {
        let bridge = RecordingBridgeService()
        let model = AppModel(bridgeFactory: { bridge })
        model.start()
        await Task.yield()

        model.selectedHierarchy = .internetRadio
        model.selectedZoneID = "zone-1"
        model.performPreferredAction(
            for: BrowseItem(
                title: "Ichiban Rock and Soul from WFMU",
                subtitle: nil,
                imageKey: nil,
                itemKey: "514:5",
                hint: "action",
                inputPrompt: nil
            ),
            preferredActionTitles: ["Play Now"]
        )

        await Task.yield()
        await Task.yield()

        #expect(bridge.requestedMethods.isEmpty)
        #expect(bridge.sentMethods.contains("browse.performAction"))
        #expect(bridge.sentPerformActionParams == [
            BrowsePerformActionParams(
                hierarchy: .internetRadio,
                sessionKey: "internet_radio:514:5",
                itemKey: "514:5",
                zoneOrOutputID: "zone-1",
                contextItemKey: nil,
                actionTitle: nil
            )
        ])
    }
}

@MainActor
private final class RecordingBridgeService: BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)?
    var requestedMethods: [String] = []
    var sentMethods: [String] = []
    var sentPerformActionParams: [BrowsePerformActionParams] = []

    func start() async throws {}

    func stop() async {}

    func send<Params: Encodable>(_ method: String, params: Params) async throws {
        sentMethods.append(method)
        if let params = params as? BrowsePerformActionParams {
            sentPerformActionParams.append(params)
        }
    }

    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        requestedMethods.append(method)
        throw NSError(domain: "RecordingBridgeService", code: 1)
    }
}
