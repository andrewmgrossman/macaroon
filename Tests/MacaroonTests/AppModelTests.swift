import AppKit
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

    @Test
    func loadArtworkUsesMemoryCacheOnRepeatAccess() async throws {
        let defaults = UserDefaults(suiteName: "macaroon-appmodel-artwork-\(UUID().uuidString)")!
        let settingsStore = ArtworkCacheSettingsStore(defaults: defaults)
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-appmodel-artwork-\(UUID().uuidString)", isDirectory: true)
        let cacheStore = ArtworkCacheStore(directoryURL: cacheDirectory, settingsStore: settingsStore)
        let fetchCount = AppModelLockedCounter()
        let imageClient = NativeImageClient(
            fetch: { _ in
                await fetchCount.increment()
                return NativeImageFetchResponse(
                    contentType: "image/jpeg",
                    data: makeJPEGData()
                )
            },
            cacheStore: cacheStore
        )
        let model = AppModel(
            bridgeFactory: { RecordingBridgeService() },
            artworkCacheStore: cacheStore,
            nativeImageClient: imageClient,
            artworkSettingsStore: settingsStore
        )
        model.currentCore = CoreSummary(
            coreID: "core-1",
            displayName: "m1mini",
            displayVersion: "2.62",
            host: "10.0.7.148",
            port: 9330
        )

        let first = await model.loadArtwork(imageKey: "repeat-image", width: 44, height: 44)
        let second = await model.loadArtwork(imageKey: "repeat-image", width: 44, height: 44)

        #expect(first != nil)
        #expect(second != nil)
        #expect(await fetchCount.value == 1)
        #expect(model.artworkCacheUsageBytes > 0)
    }

    @Test
    func clearArtworkCacheClearsDiskAndUsage() async throws {
        let defaults = UserDefaults(suiteName: "macaroon-appmodel-artwork-\(UUID().uuidString)")!
        let settingsStore = ArtworkCacheSettingsStore(defaults: defaults)
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-appmodel-artwork-\(UUID().uuidString)", isDirectory: true)
        let cacheStore = ArtworkCacheStore(directoryURL: cacheDirectory, settingsStore: settingsStore)
        let imageClient = NativeImageClient(
            fetch: { _ in
                NativeImageFetchResponse(
                    contentType: "image/jpeg",
                    data: makeJPEGData()
                )
            },
            cacheStore: cacheStore
        )
        let model = AppModel(
            bridgeFactory: { RecordingBridgeService() },
            artworkCacheStore: cacheStore,
            nativeImageClient: imageClient,
            artworkSettingsStore: settingsStore
        )
        model.currentCore = CoreSummary(
            coreID: "core-1",
            displayName: "m1mini",
            displayVersion: "2.62",
            host: "10.0.7.148",
            port: 9330
        )

        _ = await model.loadArtwork(imageKey: "clear-image", width: 44, height: 44)
        #expect(model.artworkCacheUsageBytes > 0)

        await model.clearArtworkCache()
        let stats = try await cacheStore.stats()

        #expect(model.artworkCacheUsageBytes == 0)
        #expect(stats.entryCount == 0)
        #expect(stats.totalBytes == 0)
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

private func makeJPEGData() -> Data {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
    image.unlockFocus()
    let tiffData = image.tiffRepresentation!
    let representation = NSBitmapImageRep(data: tiffData)!
    return representation.representation(using: .jpeg, properties: [:])!
}

actor AppModelLockedCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
