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

    @Test
    func zonesChangedRemovalFallsBackToRemainingZoneAndResubscribesQueue() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
        let firstZoneID = "zone-a-\(UUID().uuidString)"
        let secondZoneID = "zone-b-\(UUID().uuidString)"
        model.start()
        await Task.yield()

        controller.emit(.zonesSnapshot(ZonesSnapshotEvent(zones: [
            makeZoneSummary(id: firstZoneID, name: "Desk"),
            makeZoneSummary(id: secondZoneID, name: "Living Room")
        ])))
        await Task.yield()

        #expect(model.selectedZoneID == firstZoneID)
        #expect(model.zones.map(\.zoneID) == [firstZoneID, secondZoneID])

        controller.emit(.zonesChanged(ZonesChangedEvent(
            zones: [],
            removedZoneIDs: [firstZoneID]
        )))
        await Task.yield()

        #expect(model.zones.map(\.zoneID) == [secondZoneID])
        #expect(model.selectedZoneID == secondZoneID)
        #expect(controller.subscribeQueueCalls == [
            .init(zoneOrOutputID: firstZoneID, maxItemCount: 300),
            .init(zoneOrOutputID: secondZoneID, maxItemCount: 300)
        ])
    }

    @Test
    func zonesChangedRemovalOfFinalZoneClearsSelectionAndQueueState() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
        let onlyZoneID = "zone-solo-\(UUID().uuidString)"
        model.start()
        await Task.yield()

        controller.emit(.zonesSnapshot(ZonesSnapshotEvent(zones: [
            makeZoneSummary(id: onlyZoneID, name: "Desk")
        ])))
        await Task.yield()

        model.queueState = QueueState(
            zoneID: onlyZoneID,
            title: "Queue",
            totalCount: 1,
            currentQueueItemID: "queue-item-1",
            items: [
                QueueItemSummary(
                    queueItemID: "queue-item-1",
                    title: "Track",
                    subtitle: "Artist",
                    detail: "Album",
                    imageKey: nil,
                    length: 180,
                    isCurrent: true
                )
            ]
        )

        controller.emit(.zonesChanged(ZonesChangedEvent(
            zones: [],
            removedZoneIDs: [onlyZoneID]
        )))
        await Task.yield()

        #expect(model.zones.isEmpty)
        #expect(model.selectedZoneID == nil)
        #expect(model.queueState == nil)
        #expect(controller.subscribeQueueCalls == [
            .init(zoneOrOutputID: onlyZoneID, maxItemCount: 300)
        ])
    }

    @Test
    func returningToBrowseListPreloadsLastVisibleBrowsePage() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
        model.start()
        await Task.yield()

        let listPage = BrowsePage(
            hierarchy: .artists,
            list: BrowseList(
                title: "Artists",
                subtitle: nil,
                count: 320,
                level: 0,
                displayOffset: 0
            ),
            items: (0..<100).map { index in
                BrowseItem(
                    title: "Artist \(index)",
                    subtitle: nil,
                    imageKey: "artist-\(index)",
                    itemKey: "artist-\(index)",
                    hint: "list",
                    inputPrompt: nil
                )
            },
            offset: 0,
            selectedZoneID: nil
        )
        let detailPage = BrowsePage(
            hierarchy: .artists,
            list: BrowseList(
                title: "Artist Detail",
                subtitle: nil,
                count: 1,
                level: 1,
                displayOffset: 0
            ),
            items: [
                BrowseItem(
                    title: "Play Artist",
                    subtitle: nil,
                    imageKey: nil,
                    itemKey: "play-artist",
                    hint: "action",
                    inputPrompt: nil
                )
            ],
            offset: 0,
            selectedZoneID: nil
        )

        controller.emit(.browseListChanged(BrowseListChangedEvent(page: listPage)))
        await Task.yield()

        model.noteBrowseItemVisible(150, for: listPage)

        controller.emit(.browseListChanged(BrowseListChangedEvent(page: detailPage)))
        await Task.yield()

        controller.emit(.browseListChanged(BrowseListChangedEvent(page: listPage)))
        await Task.yield()
        await Task.yield()

        let sortedLoadCalls = controller.browseLoadPageCalls.sorted { lhs, rhs in
            lhs.offset < rhs.offset
        }
        #expect(sortedLoadCalls == [
            .init(hierarchy: .artists, offset: 100, count: 100),
            .init(hierarchy: .artists, offset: 200, count: 100)
        ])
    }

    @Test
    func typeSelectDisplaysTypedQueryAndClearsAfterResetInterval() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
        model.start()
        await Task.yield()

        model.selectedHierarchy = .artists
        controller.emit(.browseListChanged(BrowseListChangedEvent(page: BrowsePage(
            hierarchy: .artists,
            list: BrowseList(
                title: "Artists",
                subtitle: nil,
                count: 2,
                level: 0,
                displayOffset: 0
            ),
            items: [
                BrowseItem(title: "Bill Evans", subtitle: nil, imageKey: nil, itemKey: "bill-evans", hint: "list", inputPrompt: nil),
                BrowseItem(title: "Bob Dylan", subtitle: nil, imageKey: nil, itemKey: "bob-dylan", hint: "list", inputPrompt: nil)
            ],
            offset: 0,
            selectedZoneID: nil
        ))))
        await Task.yield()

        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("b"))) == true)
        #expect(model.typeSelectQueryDisplay == "b")

        try await Task.sleep(for: .milliseconds(1100))

        #expect(model.typeSelectQueryDisplay == nil)
    }

    @Test
    func typeSelectCapturesSpacesOnlyWhileSequenceIsActive() async throws {
        let controller = RecordingSessionController()
        let model = AppModel(sessionControllerFactory: { controller })
        model.start()
        await Task.yield()

        model.selectedHierarchy = .artists
        controller.emit(.browseListChanged(BrowseListChangedEvent(page: BrowsePage(
            hierarchy: .artists,
            list: BrowseList(
                title: "Artists",
                subtitle: nil,
                count: 3,
                level: 0,
                displayOffset: 0
            ),
            items: [
                BrowseItem(title: "Bill Evans", subtitle: nil, imageKey: nil, itemKey: "bill-evans", hint: "list", inputPrompt: nil),
                BrowseItem(title: "Bill J Jones", subtitle: nil, imageKey: nil, itemKey: "bill-j-jones", hint: "list", inputPrompt: nil),
                BrowseItem(title: "Bob Dylan", subtitle: nil, imageKey: nil, itemKey: "bob-dylan", hint: "list", inputPrompt: nil)
            ],
            offset: 0,
            selectedZoneID: nil
        ))))
        await Task.yield()

        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("b"))) == true)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("i"))) == true)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("l"))) == true)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("l"))) == true)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent(" "))) == true)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent("J"))) == true)
        #expect(model.typeSelectQueryDisplay == "bill j")

        try await Task.sleep(for: .milliseconds(1100))

        #expect(model.typeSelectQueryDisplay == nil)
        #expect(model.handleTypeSelectKeyEvent(try #require(makeKeyDownEvent(" "))) == false)
    }

    @Test
    func loadWikipediaLoadsArtistArticleWithoutBlockingOrGlobalError() async throws {
        let controller = RecordingSessionController()
        let cacheStore = WikipediaCacheStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("macaroon-wikipedia-\(UUID().uuidString)", isDirectory: true)
        )
        let client = WikipediaClient(fetchData: wikipediaStubFetchData(), cacheStore: cacheStore)
        let model = AppModel(
            sessionControllerFactory: { controller },
            wikipediaClient: client
        )

        model.loadWikipedia(for: .artist(name: "Nirvana"))
        let loadedState = await waitForWikipediaState(
            in: model,
            target: .artist(name: "Nirvana"),
            timeoutMilliseconds: 500
        )

        guard case let .loaded(article) = loadedState else {
            Issue.record("Expected Wikipedia article to load for artist")
            return
        }

        #expect(article.pageTitle == "Nirvana")
        #expect(model.errorState == nil)
    }

    @Test
    func toggleWikipediaExpansionChangesState() async throws {
        let model = AppModel(sessionControllerFactory: { RecordingSessionController() })
        let target = WikipediaLookupTarget.album(title: "Sea Change", artist: "Beck")

        #expect(model.isWikipediaExpanded(for: target) == false)
        model.toggleWikipediaExpansion(for: target)
        #expect(model.isWikipediaExpanded(for: target) == true)
        model.toggleWikipediaExpansion(for: target)
        #expect(model.isWikipediaExpanded(for: target) == false)
    }

    @Test
    func cancelWikipediaLoadIgnoresStaleResult() async throws {
        let controller = RecordingSessionController()
        let cacheStore = WikipediaCacheStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("macaroon-wikipedia-\(UUID().uuidString)", isDirectory: true)
        )
        let client = WikipediaClient(
            fetchData: { url in
                try await Task.sleep(for: .milliseconds(200))
                return try await wikipediaStubFetchData()(url)
            },
            cacheStore: cacheStore
        )
        let model = AppModel(
            sessionControllerFactory: { controller },
            wikipediaClient: client
        )
        let target = WikipediaLookupTarget.artist(name: "Nirvana")

        model.loadWikipedia(for: target)
        model.cancelWikipediaLoad(for: target)
        try await Task.sleep(for: .milliseconds(260))

        #expect(model.wikipediaState(for: target) == .idle)
    }

    @Test
    func unavailableWikipediaResultDoesNotRaiseGlobalError() async throws {
        let controller = RecordingSessionController()
        let cacheStore = WikipediaCacheStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("macaroon-wikipedia-\(UUID().uuidString)", isDirectory: true)
        )
        let client = WikipediaClient(
            fetchData: { url in
                let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "list" })?
                    .value
                if action == "search" {
                    return """
                    {"query":{"search":[]}}
                    """.data(using: .utf8)!
                }
                return Data()
            },
            cacheStore: cacheStore
        )
        let model = AppModel(
            sessionControllerFactory: { controller },
            wikipediaClient: client
        )
        let target = WikipediaLookupTarget.artist(name: "No Match")

        model.loadWikipedia(for: target)
        let finalState = await waitForWikipediaState(
            in: model,
            target: target,
            timeoutMilliseconds: 500
        )

        #expect(finalState == .unavailable)
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

    struct SubscribeQueueCall: Equatable {
        var zoneOrOutputID: String
        var maxItemCount: Int
    }

    struct BrowseLoadPageCall: Equatable {
        var hierarchy: BrowseHierarchy
        var offset: Int
        var count: Int
    }

    typealias ImageFetcher = @MainActor @Sendable (String, Int, Int, String) async throws -> ImageFetchedResult

    var eventHandler: (@MainActor (RoonSessionEvent) -> Void)?
    var contextActionsCalls: [(BrowseHierarchy, String, String?)] = []
    var performActionCalls: [PerformActionCall] = []
    var browseHomeCalls: [BrowseHomeCall] = []
    var browseRefreshCalls: [BrowseRefreshCall] = []
    var browseOpenServiceCalls: [BrowseOpenServiceCall] = []
    var subscribeQueueCalls: [SubscribeQueueCall] = []
    var browseLoadPageCalls: [BrowseLoadPageCall] = []
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
    func subscribeQueue(zoneOrOutputID: String, maxItemCount: Int) async throws {
        subscribeQueueCalls.append(.init(zoneOrOutputID: zoneOrOutputID, maxItemCount: maxItemCount))
    }
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
    func browseLoadPage(hierarchy: BrowseHierarchy, offset: Int, count: Int) async throws {
        browseLoadPageCalls.append(.init(hierarchy: hierarchy, offset: offset, count: count))
    }
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

    func emit(_ event: RoonSessionEvent) {
        eventHandler?(event)
    }
}

private func staleItemError() -> NSError {
    NSError(domain: "Roon", code: 500, userInfo: [NSLocalizedDescriptionKey: "InvalidItemKey"])
}

private func makeZoneSummary(id: String, name: String) -> ZoneSummary {
    ZoneSummary(
        zoneID: id,
        displayName: name,
        state: "paused",
        outputs: [],
        capabilities: .unavailable,
        nowPlaying: nil
    )
}

private func makeKeyDownEvent(_ characters: String) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )
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

private func wikipediaStubFetchData() -> WikipediaFetchDataClosure {
    { url in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let list = queryItems.first(where: { $0.name == "list" })?.value
        let titles = queryItems.first(where: { $0.name == "titles" })?.value

        if list == "search" {
            let query = queryItems.first(where: { $0.name == "srsearch" })?.value ?? ""
            if query.contains("Nirvana") {
                return """
                {"query":{"search":[{"title":"Nirvana"}]}}
                """.data(using: .utf8)!
            }

            if query.contains("Sea Change") {
                return """
                {"query":{"search":[{"title":"Sea Change"}]}}
                """.data(using: .utf8)!
            }

            return """
            {"query":{"search":[]}}
            """.data(using: .utf8)!
        }

        switch titles {
        case "Nirvana":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 1,
                    "title": "Nirvana",
                    "fullurl": "https://en.wikipedia.org/wiki/Nirvana_(band)",
                    "extract": "Nirvana was an American rock band formed in Aberdeen, Washington, in 1987. The band consisted of Kurt Cobain, Krist Novoselic and Dave Grohl.",
                    "categories": [
                      { "title": "Category:American rock music groups" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        case "Sea Change":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 2,
                    "title": "Sea Change",
                    "fullurl": "https://en.wikipedia.org/wiki/Sea_Change",
                    "extract": "Sea Change is the eighth studio album by Beck, released in 2002. It marked a shift toward a more introspective style.",
                    "categories": [
                      { "title": "Category:2002 albums" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        default:
            return """
            {"query":{"pages":[]}}
            """.data(using: .utf8)!
        }
    }
}

@MainActor
private func waitForWikipediaState(
    in model: AppModel,
    target: WikipediaLookupTarget,
    timeoutMilliseconds: Int
) async -> WikipediaSectionState {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
    var state = model.wikipediaState(for: target)
    while Date() < deadline {
        if state != .idle && state != .loading {
            return state
        }
        try? await Task.sleep(for: .milliseconds(20))
        state = model.wikipediaState(for: target)
    }
    return state
}
