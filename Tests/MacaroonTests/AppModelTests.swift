import AppKit
import Foundation
import Testing
@testable import Macaroon

@Suite("AppModelTests")
@MainActor
struct AppModelTests {
    @Test
    func performPreferredActionDirectlyExecutesInternetRadioActionItems() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
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

        #expect(controller.contextActionsCalls.isEmpty)
        #expect(controller.performActionCalls == [
            .init(
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
        let controller = RecordingSessionController(imageFetcher: { imageKey, width, height, format in
            try await imageClient.fetchImage(
                imageKey: imageKey,
                width: width,
                height: height,
                format: format,
                core: CoreSummary(
                    coreID: "core-1",
                    displayName: "m1mini",
                    displayVersion: "2.62",
                    host: "10.0.7.148",
                    port: 9330
                )
            )
        })
        let model = AppModel(
            sessionControllerFactory: { controller },
            artworkCacheStore: cacheStore,
            nativeImageClient: imageClient,
            artworkSettingsStore: settingsStore
        )
        model.start()
        await Task.yield()

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
        let controller = RecordingSessionController(imageFetcher: { imageKey, width, height, format in
            try await imageClient.fetchImage(
                imageKey: imageKey,
                width: width,
                height: height,
                format: format,
                core: CoreSummary(
                    coreID: "core-1",
                    displayName: "m1mini",
                    displayVersion: "2.62",
                    host: "10.0.7.148",
                    port: 9330
                )
            )
        })
        let model = AppModel(
            sessionControllerFactory: { controller },
            artworkCacheStore: cacheStore,
            nativeImageClient: imageClient,
            artworkSettingsStore: settingsStore
        )
        model.start()
        await Task.yield()

        _ = await model.loadArtwork(imageKey: "clear-image", width: 44, height: 44)
        #expect(model.artworkCacheUsageBytes > 0)

        await model.clearArtworkCache()
        let stats = try await cacheStore.stats()

        #expect(model.artworkCacheUsageBytes == 0)
        #expect(stats.entryCount == 0)
        #expect(stats.totalBytes == 0)
    }

    @Test
    func performPreferredActionRecoversQuietlyFromStaleBrowseItem() async throws {
        let controller = RecordingSessionController()
        controller.contextActionsError = staleItemError()
        let model = AppModel(sessionControllerFactory: { controller })
        model.start()
        await Task.yield()

        model.selectedHierarchy = .albums
        model.selectedZoneID = "zone-1"
        model.performPreferredAction(
            for: BrowseItem(
                title: "Sea Change",
                subtitle: "Beck",
                imageKey: nil,
                itemKey: "484:5",
                hint: "action_list",
                inputPrompt: nil
            ),
            preferredActionTitles: ["Play Now"]
        )

        await Task.yield()
        await Task.yield()

        #expect(controller.browseRefreshCalls == [.init(hierarchy: .albums, zoneOrOutputID: "zone-1")])
        #expect(model.errorState == nil)
    }

    @Test
    func playSearchResultRecoversByRestartingSearchOnStaleItem() async throws {
        let controller = RecordingSessionController()
        controller.performSearchMatchActionError = staleItemError()
        let model = AppModel(sessionControllerFactory: { controller })
        model.start()
        await Task.yield()

        model.selectedHierarchy = .search
        model.selectedZoneID = "zone-1"
        model.searchText = "beck"
        model.playSearchResult(query: "beck", category: .albums, matchTitle: "Sea Change")

        await Task.yield()
        await Task.yield()

        #expect(controller.browseHomeCalls == [.init(hierarchy: .search, zoneOrOutputID: "zone-1")])
        #expect(model.errorState == nil)
    }
}

@MainActor
private final class RecordingSessionController: RoonSessionController {
    struct PerformActionCall: Equatable {
        var hierarchy: BrowseHierarchy
        var sessionKey: String
        var itemKey: String
        var zoneOrOutputID: String?
        var contextItemKey: String?
        var actionTitle: String?
    }

    struct BrowseHomeCall: Equatable {
        var hierarchy: BrowseHierarchy
        var zoneOrOutputID: String?
    }

    struct BrowseRefreshCall: Equatable {
        var hierarchy: BrowseHierarchy
        var zoneOrOutputID: String?
    }

    struct BrowseOpenServiceCall: Equatable {
        var title: String
        var zoneOrOutputID: String?
    }

    typealias ImageFetcher = @MainActor @Sendable (String, Int, Int, String) async throws -> ImageFetchedResult

    var eventHandler: (@MainActor (RoonSessionEvent) -> Void)?
    var contextActionsCalls: [(BrowseHierarchy, String, String?)] = []
    var performActionCalls: [PerformActionCall] = []
    var browseHomeCalls: [BrowseHomeCall] = []
    var browseRefreshCalls: [BrowseRefreshCall] = []
    var browseOpenServiceCalls: [BrowseOpenServiceCall] = []
    var contextActionsError: Error?
    var performSearchMatchActionError: Error?
    private let imageFetcher: ImageFetcher?

    init(imageFetcher: ImageFetcher? = nil) {
        self.imageFetcher = imageFetcher
    }

    func start() async throws {}
    func stop() async {}
    func connectAutomatically(persistedState: PersistedSessionState) async throws {}
    func connectManually(host: String, port: Int, persistedState: PersistedSessionState) async throws {}
    func disconnect() async {}
    func subscribeZones() async throws {}
    func subscribeQueue(zoneOrOutputID: String, maxItemCount: Int) async throws {}
    func queuePlayFromHere(zoneOrOutputID: String, queueItemID: String) async throws {}
    func browseHome(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws {
        browseHomeCalls.append(.init(hierarchy: hierarchy, zoneOrOutputID: zoneOrOutputID))
    }
    func browseOpen(hierarchy: BrowseHierarchy, zoneOrOutputID: String?, itemKey: String?) async throws {}
    func browseOpenService(title: String, zoneOrOutputID: String?) async throws {
        browseOpenServiceCalls.append(.init(title: title, zoneOrOutputID: zoneOrOutputID))
    }
    func browseBack(hierarchy: BrowseHierarchy, levels: Int, zoneOrOutputID: String?) async throws {}
    func browseRefresh(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws {
        browseRefreshCalls.append(.init(hierarchy: hierarchy, zoneOrOutputID: zoneOrOutputID))
    }
    func browseLoadPage(hierarchy: BrowseHierarchy, offset: Int, count: Int) async throws {}
    func browseSubmitInput(hierarchy: BrowseHierarchy, itemKey: String, input: String, zoneOrOutputID: String?) async throws {}
    func browseOpenSearchMatch(query: String, categoryTitle: String, matchTitle: String, zoneOrOutputID: String?) async throws {}
    func browseServices() async throws -> BrowseServicesResult { BrowseServicesResult(services: []) }
    func browseSearchSections(query: String, zoneOrOutputID: String?) async throws -> SearchResultsPage {
        SearchResultsPage(query: query, topHit: nil, sections: [])
    }

    func browseContextActions(hierarchy: BrowseHierarchy, itemKey: String, zoneOrOutputID: String?) async throws -> BrowseActionMenuResult {
        contextActionsCalls.append((hierarchy, itemKey, zoneOrOutputID))
        if let contextActionsError {
            throw contextActionsError
        }
        throw NSError(domain: "RecordingSessionController", code: 1)
    }

    func browsePerformAction(
        hierarchy: BrowseHierarchy,
        sessionKey: String,
        itemKey: String,
        zoneOrOutputID: String?,
        contextItemKey: String?,
        actionTitle: String?
    ) async throws {
        performActionCalls.append(.init(
            hierarchy: hierarchy,
            sessionKey: sessionKey,
            itemKey: itemKey,
            zoneOrOutputID: zoneOrOutputID,
            contextItemKey: contextItemKey,
            actionTitle: actionTitle
        ))
    }

    func browsePerformSearchMatchAction(
        query: String,
        categoryTitle: String,
        matchTitle: String,
        preferredActionTitles: [String],
        zoneOrOutputID: String?
    ) async throws {
        if let performSearchMatchActionError {
            throw performSearchMatchActionError
        }
    }

    func transportCommand(zoneOrOutputID: String, command: TransportCommand) async throws {}
    func transportSeek(zoneOrOutputID: String, how: String, seconds: Double) async throws {}
    func transportChangeVolume(outputID: String, how: VolumeChangeMode, value: Double) async throws {}
    func transportMute(outputID: String, how: OutputMuteMode) async throws {}

    func fetchArtwork(imageKey: String, width: Int, height: Int, format: String) async throws -> ImageFetchedResult {
        guard let imageFetcher else {
            throw NSError(domain: "RecordingSessionController", code: 2)
        }
        return try await imageFetcher(imageKey, width, height, format)
    }
}

private func staleItemError() -> NSError {
    NSError(domain: "Roon", code: 500, userInfo: [NSLocalizedDescriptionKey: "InvalidItemKey"])
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
