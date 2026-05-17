import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private enum BrowseNavigationAction: Equatable {
        case openItem(hierarchy: BrowseHierarchy, itemKey: String)
        case openBrowseService(title: String)
        case search(query: String)
        case openSearchMatch(query: String, categoryTitle: String, matchTitle: String)
    }

    private enum HistoryMode {
        case none
        case newAction
        case replayForward
    }

    private struct PendingSeekState {
        var target: Double
        var appliedAt: Date
        var length: Double?
    }

    private struct BrowseRequestID: Equatable, Sendable {
        var rawValue: Int
        var navigationGeneration: Int
    }

    private struct PendingBrowseVisibleRange {
        var pageIdentity: String
        var page: BrowsePage
        var lowerBound: Int
        var upperBound: Int
        var latestIndex: Int
        var shouldPrefetchArtwork: Bool
    }

    var connectionStatus: ConnectionStatus {
        get { connectionPlaybackState.connectionStatus }
        set {
            connectionPlaybackState.connectionStatus = newValue
            MacaroonDebugLogger.logApp(
                "app.connection_status_changed",
                details: ["summary": newValue.summary]
            )
        }
    }
    var currentCore: CoreSummary? {
        get { connectionPlaybackState.currentCore }
        set { connectionPlaybackState.currentCore = newValue }
    }
    var manualConnect: ManualConnectConfiguration {
        get { connectionPlaybackState.manualConnect }
        set { connectionPlaybackState.manualConnect = newValue }
    }
    var selectedHierarchy: BrowseHierarchy {
        get { browsePresentationState.selectedHierarchy }
        set { browsePresentationState.selectedHierarchy = newValue }
    }
    var browsePage: BrowsePage? {
        get { browsePresentationState.browsePage }
        set { browsePresentationState.browsePage = newValue }
    }
    var browseItemsByIndex: [Int: BrowseItem] {
        get { browsePresentationState.browseItemsByIndex }
        set { browsePresentationState.browseItemsByIndex = newValue }
    }
    var browseServices: [BrowseServiceSummary] {
        get { browsePresentationState.browseServices }
        set { browsePresentationState.browseServices = newValue }
    }
    var selectedBrowseServiceTitle: String? {
        get { browsePresentationState.selectedBrowseServiceTitle }
        set { browsePresentationState.selectedBrowseServiceTitle = newValue }
    }
    var zones: [ZoneSummary] {
        get { connectionPlaybackState.zones }
        set { connectionPlaybackState.zones = newValue }
    }
    var selectedZoneID: String? {
        get { connectionPlaybackState.selectedZoneID }
        set {
            connectionPlaybackState.selectedZoneID = newValue
            MacaroonDebugLogger.logApp(
                "app.selected_zone_changed",
                details: ["zone_id": newValue ?? "<nil>"]
            )
        }
    }
    var queueState: QueueState? {
        get { queuePresentationState.queueState }
        set { queuePresentationState.queueState = newValue }
    }
    var isQueueSidebarVisible: Bool {
        get { queuePresentationState.isQueueSidebarVisible }
        set {
            queuePresentationState.isQueueSidebarVisible = newValue
            MacaroonDebugLogger.logApp(
                "app.queue_sidebar_toggled",
                details: ["visible": newValue ? "true" : "false"]
            )
        }
    }
    var errorState: ErrorState? {
        didSet {
            guard let errorState else {
                return
            }
            MacaroonDebugLogger.logError(
                "app.error_state",
                details: [
                    "title": errorState.title,
                    "selected_hierarchy": selectedHierarchy.rawValue,
                    "selected_zone_id": selectedZoneID ?? "<nil>",
                    "core": currentCore?.displayName ?? "<nil>"
                ],
                message: errorState.message
            )
        }
    }
    var sessionStatusText: String {
        get { connectionPlaybackState.sessionStatusText }
        set { connectionPlaybackState.sessionStatusText = newValue }
    }
    var autoConnectionIssue: String? {
        get { connectionPlaybackState.autoConnectionIssue }
        set { connectionPlaybackState.autoConnectionIssue = newValue }
    }
    var searchText: String {
        get { browsePresentationState.searchText }
        set { browsePresentationState.searchText = newValue }
    }
    var searchResultsPage: SearchResultsPage? {
        get { browsePresentationState.searchResultsPage }
        set { browsePresentationState.searchResultsPage = newValue }
    }
    var artworkCacheUsageBytes: Int {
        get { artworkPresentationState.artworkCacheUsageBytes }
        set { artworkPresentationState.artworkCacheUsageBytes = newValue }
    }
    var artworkCacheLimitBytes: Int {
        get { artworkPresentationState.artworkCacheLimitBytes }
        set { artworkPresentationState.artworkCacheLimitBytes = newValue }
    }
    var searchFocusRequestID: Int {
        get { browsePresentationState.searchFocusRequestID }
        set { browsePresentationState.searchFocusRequestID = newValue }
    }
    var dismissTransientUIRequestID = 0
    var typeSelectQueryDisplay: String? {
        get { browsePresentationState.typeSelectQueryDisplay }
        set { browsePresentationState.typeSelectQueryDisplay = newValue }
    }
    var browseScrollTargetIndex: Int? {
        get { browsePresentationState.browseScrollTargetIndex }
        set { browsePresentationState.browseScrollTargetIndex = newValue }
    }
    var browseScrollTargetRequestID: Int {
        get { browsePresentationState.browseScrollTargetRequestID }
        set { browsePresentationState.browseScrollTargetRequestID = newValue }
    }
    var browsePageGeneration: Int {
        get { browsePresentationState.browsePageGeneration }
        set { browsePresentationState.browsePageGeneration = newValue }
    }
    var wikipediaStates: [String: WikipediaSectionState] = [:]

    var artworkCacheUsageDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: Int64(artworkCacheUsageBytes))
    }

    var artworkCacheLimitDisplay: String {
        Self.byteCountFormatter.string(fromByteCount: Int64(artworkCacheLimitBytes))
    }

    var artworkCacheLimitMegabytes: Double {
        Double(artworkCacheLimitBytes) / (1024 * 1024)
    }

    private let connectionPlaybackState = ConnectionPlaybackStateStore()
    private let browsePresentationState = BrowsePresentationStateStore()
    private let queuePresentationState = QueuePresentationStateStore()
    private let artworkPresentationState = ArtworkPresentationStateStore()

    @ObservationIgnored
    private var sessionController: RoonSessionController?
    @ObservationIgnored
    private var sessionEventTask: Task<Void, Never>?
    @ObservationIgnored
    private var sessionEventContinuation: AsyncStream<RoonSessionEvent>.Continuation?
    @ObservationIgnored
    private var sessionStore = SessionStateStore()
    @ObservationIgnored
    private let artworkSettingsStore: ArtworkCacheSettingsStore
    @ObservationIgnored
    private let artworkCacheStore: ArtworkCacheStore
    @ObservationIgnored
    private let nativeImageClient: NativeImageClient
    @ObservationIgnored
    private let wikipediaClient: WikipediaClient
    @ObservationIgnored
    private let artworkPipeline: ArtworkPipeline
    @ObservationIgnored
    private var hasAttemptedAutoConnect = false
    @ObservationIgnored
    private var connectionMonitorTask: Task<Void, Never>?
    @ObservationIgnored
    private var userInitiatedDisconnect = false
    @ObservationIgnored
    private var pendingSearchQuery: String?
    @ObservationIgnored
    private var searchRootBrowsePage: BrowsePage?
    @ObservationIgnored
    private var nowPlayingUpdatedAt: [String: Date] = [:]
    @ObservationIgnored
    private var volumeUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var artworkCacheStatsRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingSeekStates: [String: PendingSeekState] = [:]
    @ObservationIgnored
    private var queueSubscriptionZoneID: String?
    @ObservationIgnored
    private var hasLoadedBrowseServices = false
    @ObservationIgnored
    private var searchSectionsTask: Task<Void, Never>?
    @ObservationIgnored
    private let sessionControllerFactory: @MainActor () -> RoonSessionController
    @ObservationIgnored
    private var browseRequestSequence = 0
    @ObservationIgnored
    private var browseNavigationGeneration = 0
    @ObservationIgnored
    private var navigationTrail: [BrowseNavigationAction] = []
    @ObservationIgnored
    private var forwardNavigationTrail: [BrowseNavigationAction] = []
    @ObservationIgnored
    private var pageScrollOffsets: [String: CGFloat] = [:]
    @ObservationIgnored
    private var browseVisibleIndices: [String: Int] = [:]
    @ObservationIgnored
    private var pendingBrowseVisibleRange: PendingBrowseVisibleRange?
    @ObservationIgnored
    private var browseVisibleRangeTask: Task<Void, Never>?
    @ObservationIgnored
    private var typeSelectBuffer = ""
    @ObservationIgnored
    private var typeSelectResetTask: Task<Void, Never>?
    @ObservationIgnored
    private var typeSelectGeneration = 0
    @ObservationIgnored
    private var wikipediaLoadTasks: [String: Task<Void, Never>] = [:]
    private var expandedWikipediaTargets: Set<String> = []

    private let browsePageSize = 100
    private let browseArtworkPrefetchRadius = 12
    private let browseGridArtworkPixelSize = 344
    private let pendingSeekGraceInterval: TimeInterval = 2.0
    private let preferredZoneIDDefaultsKey = "Macaroon.PreferredZoneID"
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    init(
        sessionControllerFactory: @escaping @MainActor () -> RoonSessionController = AppModel.defaultSessionControllerFactory,
        artworkCacheStore: ArtworkCacheStore = .shared,
        nativeImageClient: NativeImageClient? = nil,
        wikipediaClient: WikipediaClient? = nil,
        artworkPipeline: ArtworkPipeline = ArtworkPipeline(),
        artworkSettingsStore: ArtworkCacheSettingsStore = ArtworkCacheSettingsStore(),
        sessionStore: SessionStateStore = SessionStateStore()
    ) {
        let artworkSettings = artworkSettingsStore.load()
        self.sessionControllerFactory = sessionControllerFactory
        self.artworkSettingsStore = artworkSettingsStore
        self.artworkCacheStore = artworkCacheStore
        self.nativeImageClient = nativeImageClient ?? NativeImageClient(cacheStore: artworkCacheStore)
        self.wikipediaClient = wikipediaClient ?? WikipediaClient()
        self.artworkPipeline = artworkPipeline
        self.sessionStore = sessionStore
        self.artworkCacheLimitBytes = artworkSettings.maxBytes
        self.selectedZoneID = UserDefaults.standard.string(forKey: preferredZoneIDDefaultsKey)
        configureArtworkMemoryCacheLimit()
    }

    func start() {
        guard sessionController == nil else {
            return
        }

        MacaroonDebugLogger.logApp(
            "app.start",
            details: [
                "runtime": "native",
                "debug_log_directory": DebugLoggingConfiguration.isCompiled ? MacaroonDebugLogger.sessionDirectoryPath : "<disabled>"
            ]
        )
        MacaroonLog.app.info("Starting native session")

        let controller = sessionControllerFactory()
        let eventStream = AsyncStream(RoonSessionEvent.self, bufferingPolicy: .bufferingNewest(256)) { continuation in
            sessionEventContinuation = continuation
        }
        controller.eventHandler = { [weak self] event in
            self?.sessionEventContinuation?.yield(event)
        }
        sessionEventTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                self?.handleSessionEvent(event)
            }
        }

        sessionController = controller

        Task {
            await refreshArtworkCacheStats()
        }

        Task {
            do {
                sessionStatusText = "Starting native session"
                try await controller.start()
                sessionStatusText = "Native session running"
                autoConnectOnLaunchIfNeeded()
            } catch {
                sessionStatusText = "Failed to start native session"
                errorState = ErrorState(title: "Session Launch Failed", message: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let sessionController else {
            return
        }

        invalidateBrowseRequests()
        Task {
            await sessionController.stop()
        }
        self.sessionController = nil
        sessionEventContinuation?.finish()
        sessionEventContinuation = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        browseVisibleRangeTask?.cancel()
        browseVisibleRangeTask = nil
        artworkCacheStatsRefreshTask?.cancel()
        artworkCacheStatsRefreshTask = nil
    }

    func prepareForTermination() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        browseVisibleRangeTask?.cancel()
        browseVisibleRangeTask = nil
        artworkCacheStatsRefreshTask?.cancel()
        artworkCacheStatsRefreshTask = nil
        invalidateBrowseRequests()
        Task {
            try? await artworkCacheStore.flush()
        }

        guard let sessionController else {
            return
        }

        Task {
            await sessionController.stop()
        }

        self.sessionController = nil
        sessionEventContinuation?.finish()
        sessionEventContinuation = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
    }

    func connectAutomatically() {
        start()
        userInitiatedDisconnect = false
        connectionStatus = .connecting(mode: "discovery")
        autoConnectionIssue = nil
        MacaroonDebugLogger.logApp("app.connect_automatic")
        MacaroonLog.connection.info("Automatic connect requested")

        Task {
            do {
                let state = try sessionStore.load()
                try await sessionController?.connectAutomatically(persistedState: state)
                startConnectionResolutionMonitor()
            } catch {
                errorState = ErrorState(title: "Auto Connect Failed", message: error.localizedDescription)
            }
        }
    }

    func connectManually() {
        start()
        userInitiatedDisconnect = false
        connectionStatus = .connecting(mode: "manual")
        autoConnectionIssue = nil
        MacaroonDebugLogger.logApp(
            "app.connect_manual",
            details: [
                "host": manualConnect.host,
                "port": String(manualConnect.port)
            ]
        )
        MacaroonLog.connection.info("Manual connect requested host=\(self.manualConnect.host, privacy: .public) port=\(self.manualConnect.port, privacy: .public)")

        Task {
            do {
                let state = try sessionStore.load()
                try await sessionController?.connectManually(
                    host: manualConnect.host,
                    port: manualConnect.port,
                    persistedState: state
                )
            } catch {
                errorState = ErrorState(title: "Manual Connect Failed", message: error.localizedDescription)
            }
        }
    }

    func retryConnectionAfterAuthorization() {
        if case let .authorizing(core) = connectionStatus,
           let host = core?.host,
           let port = core?.port {
            manualConnect = ManualConnectConfiguration(host: host, port: port)
            connectManually()
            return
        }

        connectAutomatically()
    }

    func disconnect() {
        userInitiatedDisconnect = true
        invalidateBrowseRequests()
        MacaroonDebugLogger.logApp("app.disconnect")
        Task {
            await sessionController?.disconnect()
        }
    }

    func subscribeToZones() {
        MacaroonDebugLogger.logApp("app.subscribe_zones")
        Task {
            do {
                try await sessionController?.subscribeZones()
            } catch {
                errorState = ErrorState(title: "Zone Subscription Failed", message: error.localizedDescription)
            }
        }
    }

    func subscribeToQueue() {
        guard let selectedZoneID else {
            queueState = nil
            queueSubscriptionZoneID = nil
            return
        }
        guard queueSubscriptionZoneID != selectedZoneID else {
            return
        }

        queueSubscriptionZoneID = selectedZoneID
        queueState = nil
        MacaroonDebugLogger.logApp(
            "app.subscribe_queue",
            details: ["zone_id": selectedZoneID]
        )

        Task {
            do {
                try await sessionController?.subscribeQueue(zoneOrOutputID: selectedZoneID, maxItemCount: 300)
            } catch {
                errorState = ErrorState(title: "Queue Subscription Failed", message: error.localizedDescription)
            }
        }
    }

    func openHierarchy(_ hierarchy: BrowseHierarchy) {
        selectedHierarchy = hierarchy
        selectedBrowseServiceTitle = nil
        navigationTrail.removeAll()
        forwardNavigationTrail.removeAll()
        searchSectionsTask?.cancel()
        searchRootBrowsePage = nil
        if hierarchy != .search {
            searchResultsPage = nil
        }
        if hierarchy != .search {
            pendingSearchQuery = nil
        }
        MacaroonDebugLogger.logApp(
            "app.open_hierarchy",
            details: ["hierarchy": hierarchy.rawValue, "zone_id": selectedZoneID ?? "<nil>"]
        )
        let requestID = beginBrowseNavigationRequest()
        Task {
            do {
                let snapshot = try await sessionController?.browseHome(hierarchy: hierarchy, zoneOrOutputID: selectedZoneID)
                applyBrowseSnapshot(snapshot, requestID: requestID)
            } catch {
                guard isCurrentBrowseRequest(requestID) else {
                    return
                }
                errorState = ErrorState(title: "Browse Failed", message: error.localizedDescription)
            }
        }
    }

    func openBrowseService(_ service: BrowseServiceSummary) {
        performNavigation(.openBrowseService(title: service.title), historyMode: .newAction)
    }

    func goHome() {
        if let selectedBrowseServiceTitle, selectedHierarchy == .browse {
            openBrowseService(BrowseServiceSummary(title: selectedBrowseServiceTitle))
            return
        }
        openHierarchy(selectedHierarchy)
    }

    func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return
        }
        performNavigation(.search(query: query), historyMode: .newAction)
    }

    func openNowPlayingArtist() {
        guard
            let artistName = selectedZone?.nowPlaying?.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            artistName.isEmpty == false
        else {
            return
        }

        openArtist(named: artistName)
    }

    func openArtist(named artistName: String) {
        let artistName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard artistName.isEmpty == false else {
            return
        }
        performNavigation(
            .openSearchMatch(query: artistName, categoryTitle: "Artists", matchTitle: artistName),
            historyMode: .newAction
        )
    }

    func openNowPlayingAlbum() {
        guard
            let albumTitle = selectedZone?.nowPlaying?.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            albumTitle.isEmpty == false
        else {
            return
        }

        performNavigation(
            .openSearchMatch(query: albumTitle, categoryTitle: "Albums", matchTitle: albumTitle),
            historyMode: .newAction
        )
    }

    func openSearchResult(
        query: String,
        category: SearchResultsSectionKind,
        matchTitle: String
    ) {
        performNavigation(
            .openSearchMatch(query: query, categoryTitle: category.title, matchTitle: matchTitle),
            historyMode: .newAction
        )
    }

    func playSearchResult(
        query: String,
        category: SearchResultsSectionKind,
        matchTitle: String,
        preferredActionTitles: [String] = ["Play Now"]
    ) {
        MacaroonDebugLogger.logApp(
            "app.play_search_result",
            details: [
                "query": query,
                "category": category.rawValue,
                "match_title": matchTitle
            ]
        )

        Task {
            do {
                try await sessionController?.browsePerformSearchMatchAction(
                    query: query,
                    categoryTitle: category.title,
                    matchTitle: matchTitle,
                    preferredActionTitles: preferredActionTitles,
                    zoneOrOutputID: selectedZoneID
                )
            } catch {
                if await recoverFromStaleBrowseItemError(error) == false {
                    errorState = ErrorState(title: "Playback Action Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func openItem(_ item: BrowseItem) {
        guard let itemKey = item.itemKey else {
            return
        }
        performNavigation(.openItem(hierarchy: selectedHierarchy, itemKey: itemKey), historyMode: .newAction)
    }

    func goBack() {
        MacaroonDebugLogger.logApp("app.go_back", details: ["hierarchy": selectedHierarchy.rawValue])
        let requestID = beginBrowseNavigationRequest()
        Task {
            let movedAction = navigationTrail.popLast()
            if let movedAction {
                forwardNavigationTrail.append(movedAction)
            }

            if shouldRestoreSearchResultsOnBack {
                restoreSearchResultsPage()
                return
            }

            do {
                let snapshot = try await sessionController?.browseBack(
                    hierarchy: selectedHierarchy,
                    levels: 1,
                    zoneOrOutputID: selectedZoneID
                )
                applyBrowseSnapshot(snapshot, requestID: requestID)
            } catch {
                guard isCurrentBrowseRequest(requestID) else {
                    return
                }
                if let movedAction = forwardNavigationTrail.popLast() {
                    navigationTrail.append(movedAction)
                }
                errorState = ErrorState(title: "Browse Back Failed", message: error.localizedDescription)
            }
        }
    }

    func goForward() {
        guard let action = forwardNavigationTrail.popLast() else {
            return
        }
        performNavigation(action, historyMode: .replayForward)
    }

    func refreshBrowse() {
        MacaroonDebugLogger.logApp("app.refresh_browse", details: ["hierarchy": selectedHierarchy.rawValue])
        let requestID = beginBrowseNavigationRequest()
        Task {
            do {
                let snapshot = try await sessionController?.browseRefresh(hierarchy: selectedHierarchy, zoneOrOutputID: selectedZoneID)
                applyBrowseSnapshot(snapshot, requestID: requestID)
            } catch {
                guard isCurrentBrowseRequest(requestID) else {
                    return
                }
                errorState = ErrorState(title: "Refresh Failed", message: error.localizedDescription)
            }
        }
    }

    func loadPage(offset: Int, count: Int = 100) {
        browsePresentationState.activeBrowseLoadOffsets.insert(offset)
        MacaroonDebugLogger.logApp(
            "app.load_page",
            details: [
                "hierarchy": selectedHierarchy.rawValue,
                "offset": String(offset),
                "count": String(count)
            ]
        )
        MacaroonLog.browse.debug("Loading browse page hierarchy=\(self.selectedHierarchy.rawValue, privacy: .public) offset=\(offset, privacy: .public) count=\(count, privacy: .public)")
        let requestID = beginBrowsePageRequest()
        Task {
            do {
                let snapshot = try await sessionController?.browseLoadPage(
                    hierarchy: selectedHierarchy,
                    offset: offset,
                    count: count
                )
                guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                    browsePresentationState.activeBrowseLoadOffsets.remove(offset)
                    return
                }
            } catch {
                browsePresentationState.activeBrowseLoadOffsets.remove(offset)
                guard isCurrentBrowseRequest(requestID) else {
                    return
                }
                errorState = ErrorState(title: "Page Load Failed", message: error.localizedDescription)
            }
        }
    }

    func browseItem(at index: Int) -> BrowseItem? {
        browseItemsByIndex[index]
    }

    var browsePromptItem: BrowseItem? {
        if let promptItem = browseItemsByIndex[0], promptItem.inputPrompt != nil {
            return promptItem
        }
        return browsePage?.items.first(where: { $0.inputPrompt != nil })
    }

    func ensureBrowseItemsLoaded(for index: Int) {
        guard let browsePage else {
            return
        }
        guard index >= 0, index < browsePage.list.count else {
            return
        }

        let currentPageOffset = (index / browsePageSize) * browsePageSize
        let candidateOffsets = [
            max(currentPageOffset - browsePageSize, 0),
            currentPageOffset,
            min(currentPageOffset + browsePageSize, max(browsePage.list.count - 1, 0))
        ]

        for offset in Set(candidateOffsets) {
            requestBrowsePageIfNeeded(offset: offset)
        }
    }

    func performPreferredAction(for item: BrowseItem, preferredActionTitles: [String]) {
        guard let itemKey = item.itemKey else {
            return
        }
        MacaroonDebugLogger.logApp(
            "app.perform_preferred_action",
            details: [
                "hierarchy": selectedHierarchy.rawValue,
                "item_key": itemKey,
                "title": item.title,
                "preferred_actions": preferredActionTitles.joined(separator: ",")
            ]
        )

        Task {
            do {
                guard let sessionController else {
                    return
                }

                if item.hint == "action",
                   preferredActionTitles.contains(where: { $0.caseInsensitiveCompare("Play Now") == .orderedSame }) {
                    try await sessionController.browsePerformAction(
                        hierarchy: selectedHierarchy,
                        sessionKey: "\(selectedHierarchy.rawValue):\(itemKey)",
                        itemKey: itemKey,
                        zoneOrOutputID: selectedZoneID,
                        contextItemKey: nil,
                        actionTitle: nil
                    )
                    return
                }

                let menu = try await sessionController.browseContextActions(
                    hierarchy: selectedHierarchy,
                    itemKey: itemKey,
                    zoneOrOutputID: selectedZoneID
                )

                guard let action = preferredActionTitles.compactMap({ title in
                    menu.actions.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
                }).first else {
                    errorState = ErrorState(
                        title: "Action Unavailable",
                        message: "Roon did not expose a supported playback action for \(item.title)."
                    )
                    return
                }

                try await sessionController.browsePerformAction(
                    hierarchy: selectedHierarchy,
                    sessionKey: menu.sessionKey,
                    itemKey: itemKey,
                    zoneOrOutputID: selectedZoneID,
                    contextItemKey: itemKey,
                    actionTitle: action.title
                )
            } catch {
                if item.hint == "action",
                   preferredActionTitles.contains(where: { $0.caseInsensitiveCompare("Play Now") == .orderedSame }),
                   error.localizedDescription.contains("No action list available for the selected item.") {
                    do {
                        try await sessionController?.browsePerformAction(
                            hierarchy: selectedHierarchy,
                            sessionKey: "\(selectedHierarchy.rawValue):\(itemKey)",
                            itemKey: itemKey,
                            zoneOrOutputID: selectedZoneID,
                            contextItemKey: nil,
                            actionTitle: nil
                        )
                            return
                    } catch {
                        if await recoverFromStaleBrowseItemError(error) == false {
                            errorState = ErrorState(title: "Playback Action Failed", message: error.localizedDescription)
                        }
                        return
                    }
                }
                if await recoverFromStaleBrowseItemError(error) == false {
                    errorState = ErrorState(title: "Playback Action Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func requestSearchFocus() {
        searchFocusRequestID += 1
    }

    func dismissTransientUI() {
        if isQueueSidebarVisible {
            isQueueSidebarVisible = false
        }
        if errorState != nil {
            errorState = nil
        }
        dismissTransientUIRequestID += 1
    }

    func handleTypeSelectKeyEvent(_ event: NSEvent) -> Bool {
        guard canHandleTypeSelect else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) || modifiers.contains(.function) {
            return false
        }

        if NSApplication.shared.keyWindow?.firstResponder is NSTextView {
            return false
        }

        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first
        else {
            return false
        }

        let nextCharacter: String
        if CharacterSet.alphanumerics.contains(scalar) {
            nextCharacter = String(scalar).lowercased()
        } else if scalar == " ", typeSelectBuffer.isEmpty == false {
            nextCharacter = " "
        } else {
            return false
        }

        typeSelectBuffer.append(nextCharacter)
        typeSelectQueryDisplay = typeSelectBuffer
        typeSelectGeneration += 1
        let generation = typeSelectGeneration
        let query = typeSelectBuffer

        typeSelectResetTask?.cancel()
        typeSelectResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, generation == self.typeSelectGeneration else {
                return
            }
            self.typeSelectBuffer = ""
            self.typeSelectQueryDisplay = nil
        }

        Task { @MainActor [weak self] in
            await self?.jumpToBrowsePrefix(query, generation: generation)
        }

        return true
    }

    func submitPrompt(for item: BrowseItem, value: String) {
        guard let itemKey = item.itemKey else {
            return
        }
        MacaroonDebugLogger.logApp(
            "app.submit_prompt",
            details: [
                "hierarchy": selectedHierarchy.rawValue,
                "item_key": itemKey,
                "value": value
            ]
        )

        Task {
            do {
                try await sessionController?.browseSubmitInput(
                    hierarchy: selectedHierarchy,
                    itemKey: itemKey,
                    input: value,
                    zoneOrOutputID: selectedZoneID
                )
            } catch {
                errorState = ErrorState(title: "Search Failed", message: error.localizedDescription)
            }
        }
    }

    func transport(_ command: TransportCommand) {
        guard let selectedZoneID else {
            errorState = ErrorState(title: "No Zone Selected", message: "Choose a zone before sending transport commands.")
            return
        }
        MacaroonDebugLogger.logApp(
            "app.transport_command",
            details: [
                "zone_id": selectedZoneID,
                "command": command.rawValue
            ]
        )

        Task {
            do {
                try await sessionController?.transportCommand(zoneOrOutputID: selectedZoneID, command: command)
            } catch {
                errorState = ErrorState(title: "Transport Failed", message: error.localizedDescription)
            }
        }
    }

    func seek(to seconds: Double) {
        guard let selectedZoneID else {
            return
        }

        let targetSeconds = clampedSeekPosition(for: selectedZoneID, seconds: seconds)
        applyOptimisticSeek(zoneID: selectedZoneID, seconds: targetSeconds)
        MacaroonDebugLogger.logApp(
            "app.seek",
            details: [
                "zone_id": selectedZoneID,
                "seconds": String(targetSeconds)
            ]
        )

        Task {
            do {
                try await sessionController?.transportSeek(
                    zoneOrOutputID: selectedZoneID,
                    how: "absolute",
                    seconds: targetSeconds
                )
            } catch {
                pendingSeekStates.removeValue(forKey: selectedZoneID)
                errorState = ErrorState(title: "Seek Failed", message: error.localizedDescription)
            }
        }
    }

    func setVolume(_ value: Double, immediate: Bool = false) {
        guard let output = selectedVolumeOutput else {
            return
        }

        volumeUpdateTask?.cancel()
        let sendValue = value
        volumeUpdateTask = Task { [weak self] in
            if immediate == false {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard Task.isCancelled == false else {
                return
            }
            await self?.sendVolumeChange(outputID: output.outputID, how: .absolute, value: sendValue)
        }
    }

    func stepVolume(by delta: Double) {
        guard let output = selectedVolumeOutput else {
            return
        }

        volumeUpdateTask?.cancel()
        Task {
            await sendVolumeChange(outputID: output.outputID, how: .relative, value: delta)
        }
    }

    func toggleMute() {
        guard let output = selectedVolumeOutput else {
            return
        }

        let targetMode: OutputMuteMode = output.volume?.isMuted == true ? .unmute : .mute
        MacaroonDebugLogger.logApp(
            "app.toggle_mute",
            details: [
                "output_id": output.outputID,
                "target_mode": targetMode.rawValue
            ]
        )

        Task {
            do {
                try await sessionController?.transportMute(outputID: output.outputID, how: targetMode)
            } catch {
                errorState = ErrorState(title: "Mute Failed", message: error.localizedDescription)
            }
        }
    }

    func toggleQueueSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isQueueSidebarVisible.toggle()
        }
    }

    func hideQueueSidebar() {
        guard isQueueSidebarVisible else {
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            isQueueSidebarVisible = false
        }
    }

    func selectZone(_ zoneID: String?) {
        selectedZoneID = zoneID
        UserDefaults.standard.set(zoneID, forKey: preferredZoneIDDefaultsKey)
        queueSubscriptionZoneID = nil
        subscribeToQueue()
    }

    func playQueueItem(_ item: QueueItemSummary) {
        guard let selectedZoneID else {
            return
        }
        MacaroonDebugLogger.logApp(
            "app.play_queue_item",
            details: [
                "zone_id": selectedZoneID,
                "queue_item_id": item.queueItemID,
                "title": item.title
            ]
        )

        Task {
            do {
                try await sessionController?.queuePlayFromHere(
                    zoneOrOutputID: selectedZoneID,
                    queueItemID: item.queueItemID
                )
            } catch {
                errorState = ErrorState(title: "Queue Playback Failed", message: error.localizedDescription)
            }
        }
    }

    var selectedZone: ZoneSummary? {
        guard let selectedZoneID else {
            return nil
        }
        return zones.first(where: { $0.zoneID == selectedZoneID })
    }

    var selectedVolumeOutput: OutputSummary? {
        selectedZone?.outputs.first(where: { $0.volume != nil })
    }

    func displayedSeekPosition(at date: Date = .now) -> Double? {
        guard let zone = selectedZone else {
            return nil
        }

        if let optimisticPosition = optimisticSeekPosition(for: zone, at: date) {
            return optimisticPosition
        }

        guard
            let nowPlaying = zone.nowPlaying,
            let basePosition = nowPlaying.seekPosition
        else {
            return nil
        }

        return advancedSeekPosition(
            basePosition: basePosition,
            length: nowPlaying.length,
            state: zone.state,
            updatedAt: nowPlayingUpdatedAt[zone.zoneID] ?? date,
            at: date
        )
    }

    func setArtworkCacheLimit(megabytes: Double) async {
        let clampedMegabytes = max(
            Double(ArtworkCacheSettings.minimumBytes) / (1024 * 1024),
            min(megabytes, Double(ArtworkCacheSettings.maximumBytes) / (1024 * 1024))
        )
        let settings = ArtworkCacheSettings(maxBytes: Int(clampedMegabytes * 1024 * 1024))
        artworkCacheLimitBytes = settings.maxBytes
        artworkSettingsStore.save(settings)
        configureArtworkMemoryCacheLimit()

        do {
            let stats = try await artworkCacheStore.setSettings(settings)
            artworkCacheStatsRefreshTask?.cancel()
            artworkCacheStatsRefreshTask = nil
            artworkCacheUsageBytes = stats.totalBytes
        } catch {
            errorState = ErrorState(title: "Artwork Cache Error", message: error.localizedDescription)
        }
    }

    func clearArtworkCache() async {
        await artworkPipeline.clearMemoryCache()

        do {
            try await artworkCacheStore.clear()
            artworkCacheStatsRefreshTask?.cancel()
            artworkCacheStatsRefreshTask = nil
            artworkCacheUsageBytes = 0
        } catch {
            errorState = ErrorState(title: "Clear Cache Failed", message: error.localizedDescription)
        }
    }

    func loadArtwork(imageKey: String?, width: Int = 320, height: Int = 320) async -> NSImage? {
        await loadArtwork(imageKey: imageKey, width: width, height: height, priority: .visible)
    }

    private func loadArtwork(
        imageKey: String?,
        width: Int,
        height: Int,
        priority: ArtworkPipelinePriority
    ) async -> NSImage? {
        guard let imageKey, !imageKey.isEmpty else {
            return nil
        }

        let request = ArtworkPipelineRequest(
            imageKey: imageKey,
            width: width,
            height: height,
            format: "image/jpeg"
        )

        let result = await artworkPipeline.load(
            request: request,
            priority: priority,
            fetchArtwork: artworkFetchLoader()
        )
        if result != nil {
            scheduleArtworkCacheStatsRefresh()
        }
        return result?.image
    }

    func refreshArtworkCacheStatsForSettings() async {
        artworkCacheStatsRefreshTask?.cancel()
        artworkCacheStatsRefreshTask = nil
        await refreshArtworkCacheStats()
    }

    func loadWikipedia(for target: WikipediaLookupTarget) {
        let key = target.cacheKey

        if wikipediaLoadTasks[key] != nil {
            return
        }

        if case .loaded? = wikipediaStates[key] {
            return
        }

        if case .unavailable? = wikipediaStates[key] {
            return
        }

        wikipediaStates[key] = .loading

        let client = wikipediaClient
        wikipediaLoadTasks[key] = Task(priority: .background) { @MainActor [weak self] in
            do {
                let article = try await client.lookupArticle(for: target)
                guard let self else {
                    return
                }
                self.wikipediaLoadTasks.removeValue(forKey: key)
                self.wikipediaStates[key] = article.map(WikipediaSectionState.loaded) ?? .unavailable
            } catch is CancellationError {
                guard let self else {
                    return
                }
                self.wikipediaLoadTasks.removeValue(forKey: key)
                if case .loading? = self.wikipediaStates[key] {
                    self.wikipediaStates[key] = .idle
                }
            } catch {
                guard let self else {
                    return
                }
                self.wikipediaLoadTasks.removeValue(forKey: key)
                self.wikipediaStates[key] = .failed
            }
        }
    }

    func cancelWikipediaLoad(for target: WikipediaLookupTarget) {
        let key = target.cacheKey
        wikipediaLoadTasks.removeValue(forKey: key)?.cancel()
        if case .loading? = wikipediaStates[key] {
            wikipediaStates[key] = .idle
        }
    }

    func wikipediaState(for target: WikipediaLookupTarget) -> WikipediaSectionState {
        wikipediaStates[target.cacheKey] ?? .idle
    }

    func toggleWikipediaExpansion(for target: WikipediaLookupTarget) {
        let key = target.cacheKey
        if expandedWikipediaTargets.contains(key) {
            expandedWikipediaTargets.remove(key)
        } else {
            expandedWikipediaTargets.insert(key)
        }
    }

    func isWikipediaExpanded(for target: WikipediaLookupTarget) -> Bool {
        expandedWikipediaTargets.contains(target.cacheKey)
    }

    private func refreshArtworkCacheStats() async {
        do {
            let stats = try await artworkCacheStore.stats()
            artworkCacheUsageBytes = stats.totalBytes
        } catch {
            MacaroonDebugLogger.logError("artwork_cache.stats_failed", error: error)
        }
    }

    private func scheduleArtworkCacheStatsRefresh() {
        artworkCacheStatsRefreshTask?.cancel()
        artworkCacheStatsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, Task.isCancelled == false else {
                return
            }
            await self.refreshArtworkCacheStats()
        }
    }

    private func configureArtworkMemoryCacheLimit() {
        let memoryLimit = max(32 * 1024 * 1024, min(128 * 1024 * 1024, artworkCacheLimitBytes / 4))
        Task { [artworkPipeline] in
            await artworkPipeline.setMemoryCacheLimit(bytes: memoryLimit)
        }
    }

    private func artworkFetchLoader() -> ArtworkPipeline.FetchArtwork {
        { [weak self] imageKey, width, height, format in
            guard let self, let sessionController = self.sessionController else {
                throw NativeImageError.missingCoreEndpoint
            }
            return try await sessionController.fetchArtwork(
                imageKey: imageKey,
                width: width,
                height: height,
                format: format
            )
        }
    }

    private func handleSessionEvent(_ event: RoonSessionEvent) {
        MacaroonDebugLogger.logApp(
            "app.session_event",
            details: sessionEventSummary(event)
        )
        apply(event)
    }

    private func apply(_ event: RoonSessionEvent) {
        switch event {
        case let .connectionChanged(payload):
            switch payload.status {
            case .disconnected:
                invalidateBrowseRequests()
                currentCore = nil
                connectionStatus = .disconnected
                queueState = nil
                queueSubscriptionZoneID = nil
                searchResultsPage = nil
                searchRootBrowsePage = nil
                searchSectionsTask?.cancel()
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
            case let .connecting(mode):
                connectionStatus = .connecting(mode: mode)
            case let .connected(core):
                currentCore = core
                connectionStatus = .connected(core)
                autoConnectionIssue = nil
                persistEndpointIfNeeded(for: core)
                loadBrowseServicesIfNeeded()
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
                userInitiatedDisconnect = false
                subscribeToZones()
                goHome()
            case let .authorizing(core):
                currentCore = core
                connectionStatus = .authorizing(core)
            case let .error(message):
                invalidateBrowseRequests()
                connectionStatus = .error(message)
            }
        case let .authorizationRequired(payload):
            if connectionStatus.isConnected {
                return
            }
            currentCore = payload.core
            connectionStatus = .authorizing(payload.core)
        case let .zonesSnapshot(payload):
            replaceZones(with: payload.zones)
        case let .zonesChanged(payload):
            mergeZones(payload.zones, removing: payload.removedZoneIDs)
        case let .queueSnapshot(payload):
            queueState = payload.queue
        case let .queueChanged(payload):
            queueState = payload.queue
        case let .browseListChanged(payload):
            handleBrowsePage(payload.page)
        case let .browseItemReplaced(payload):
            guard browsePage?.hierarchy == payload.hierarchy else {
                return
            }
            for (index, item) in browseItemsByIndex where item.itemKey == payload.item.itemKey {
                browseItemsByIndex[index] = payload.item
            }
        case let .browseItemRemoved(payload):
            guard browsePage?.hierarchy == payload.hierarchy else {
                return
            }
            let matchingIndices = browseItemsByIndex
                .filter { $0.value.itemKey == payload.itemKey }
                .map(\.key)
            for index in matchingIndices {
                browseItemsByIndex.removeValue(forKey: index)
            }
        case let .nowPlayingChanged(payload):
            guard let index = zones.firstIndex(where: { $0.zoneID == payload.zoneID }) else {
                return
            }
            zones[index].nowPlaying = reconciledNowPlaying(payload.nowPlaying, for: zones[index], at: .now)
            if zones[index].nowPlaying != nil {
                nowPlayingUpdatedAt[payload.zoneID] = .now
            } else {
                nowPlayingUpdatedAt.removeValue(forKey: payload.zoneID)
            }
        case let .persistRequested(payload):
            do {
                try sessionStore.save(payload.persistedState)
            } catch {
                errorState = ErrorState(title: "Session Save Failed", message: error.localizedDescription)
            }
        case let .errorRaised(payload):
            errorState = ErrorState(title: payload.code, message: payload.message)
        }
    }

    private static func defaultSessionControllerFactory() -> RoonSessionController {
        NativeRoonSessionController()
    }

    private func loadBrowseServicesIfNeeded() {
        guard hasLoadedBrowseServices == false else {
            return
        }
        hasLoadedBrowseServices = true

        Task {
            do {
                guard let sessionController else {
                    return
                }
                let result = try await sessionController.browseServices()
                browseServices = result.services.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            } catch {
                browseServices = []
            }
        }
    }

    private func replaceZones(with incoming: [ZoneSummary]) {
        let reconciledZones = incoming.map { zone in
            reconciledZoneSummary(zone, at: .now)
        }
        zones = reconciledZones.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        nowPlayingUpdatedAt = Dictionary(uniqueKeysWithValues: reconciledZones.compactMap { zone in
            guard zone.nowPlaying != nil else {
                return nil
            }
            return (zone.zoneID, Date())
        })
        normalizeSelectedZone()
        subscribeToQueue()
    }

    private func mergeZones(_ incoming: [ZoneSummary], removing removedZoneIDs: [String]) {
        guard incoming.isEmpty == false || removedZoneIDs.isEmpty == false else {
            return
        }

        var merged = Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
        for zoneID in removedZoneIDs {
            merged.removeValue(forKey: zoneID)
            nowPlayingUpdatedAt.removeValue(forKey: zoneID)
        }
        for zone in incoming {
            let reconciledZone = reconciledZoneSummary(zone, at: .now)
            merged[zone.zoneID] = reconciledZone
            if reconciledZone.nowPlaying != nil {
                nowPlayingUpdatedAt[zone.zoneID] = .now
            } else {
                nowPlayingUpdatedAt.removeValue(forKey: zone.zoneID)
            }
        }

        zones = merged.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        normalizeSelectedZone()
        subscribeToQueue()
    }

    private func normalizeSelectedZone() {
        let persistedZoneID = UserDefaults.standard.string(forKey: preferredZoneIDDefaultsKey)

        if selectedZoneID == nil {
            if let persistedZoneID,
               zones.contains(where: { $0.zoneID == persistedZoneID }) {
                selectedZoneID = persistedZoneID
            } else {
                selectedZoneID = zones.first?.zoneID
            }
        } else if zones.contains(where: { $0.zoneID == selectedZoneID }) == false {
            if let persistedZoneID,
               zones.contains(where: { $0.zoneID == persistedZoneID }) {
                selectedZoneID = persistedZoneID
            } else {
                selectedZoneID = zones.first?.zoneID
            }
        }

        if let selectedZoneID {
            UserDefaults.standard.set(selectedZoneID, forKey: preferredZoneIDDefaultsKey)
        }
    }

    private func beginBrowseNavigationRequest() -> BrowseRequestID {
        browseNavigationGeneration += 1
        return beginBrowseRequest()
    }

    private func invalidateBrowseRequests() {
        browseNavigationGeneration += 1
        browsePresentationState.activeBrowseLoadOffsets.removeAll(keepingCapacity: true)
        pendingBrowseVisibleRange = nil
        browseVisibleRangeTask?.cancel()
        browseVisibleRangeTask = nil
        Task { [artworkPipeline] in
            await artworkPipeline.cancelPrefetches()
        }
    }

    private func beginBrowsePageRequest() -> BrowseRequestID {
        beginBrowseRequest()
    }

    private func beginBrowseRequest() -> BrowseRequestID {
        browseRequestSequence += 1
        return BrowseRequestID(
            rawValue: browseRequestSequence,
            navigationGeneration: browseNavigationGeneration
        )
    }

    private func isCurrentBrowseRequest(_ requestID: BrowseRequestID) -> Bool {
        requestID.navigationGeneration == browseNavigationGeneration
    }

    @discardableResult
    private func applyBrowseSnapshot(_ snapshot: BrowsePageSnapshot?, requestID: BrowseRequestID) -> Bool {
        guard let snapshot else {
            return false
        }
        guard isCurrentBrowseRequest(requestID) else {
            return false
        }
        handleBrowsePage(snapshot.page)
        return true
    }

    private func handleBrowsePage(_ page: BrowsePage) {
        if
            selectedHierarchy == .search,
            let pendingSearchQuery
        {
            if let libraryItem = searchLibraryPivotItem(in: page) {
                openItem(libraryItem)
                return
            }

            if let promptItem = page.items.first(where: { $0.inputPrompt != nil }) {
                self.pendingSearchQuery = nil
                submitPrompt(for: promptItem, value: pendingSearchQuery)
                return
            }
        }

        if page.hierarchy == .browse, page.list.level == 0 {
            selectedBrowseServiceTitle = nil
        }

        if supportsStructuredSearchResults, shouldShowSearchResultsPage(for: page) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            searchRootBrowsePage = page
            searchResultsPage = SearchResultsPage(
                query: query,
                topHit: page.items.first,
                sections: searchResultsPage?.query == query ? searchResultsPage?.sections ?? [] : []
            )
            loadSearchSections(for: query)
        } else {
            searchSectionsTask?.cancel()
            searchResultsPage = nil
        }

        applyBrowsePage(page)
    }

    private func applyBrowsePage(_ incoming: BrowsePage) {
        let shouldReset =
            browsePage == nil ||
            browsePage?.hierarchy != incoming.hierarchy ||
            browsePage?.list.level != incoming.list.level ||
            browsePage?.list.title != incoming.list.title ||
            incoming.offset == 0

        if shouldReset {
            browseItemsByIndex.removeAll(keepingCapacity: true)
            browsePresentationState.loadedBrowseLoadOffsets.removeAll(keepingCapacity: true)
            browsePresentationState.activeBrowseLoadOffsets.removeAll(keepingCapacity: true)
            pendingBrowseVisibleRange = nil
            browseVisibleRangeTask?.cancel()
            browseVisibleRangeTask = nil
            browsePageGeneration += 1
            Task { [artworkPipeline] in
                await artworkPipeline.cancelPrefetches()
            }
        }

        browsePresentationState.activeBrowseLoadOffsets.remove(incoming.offset)
        browsePresentationState.loadedBrowseLoadOffsets.insert(incoming.offset)

        for (index, item) in incoming.items.enumerated() {
            browseItemsByIndex[incoming.offset + index] = item
        }

        browsePage = incoming

        if shouldReset {
            restoreBrowseViewportIfNeeded(for: incoming)
        }
    }

    private func requestBrowsePageIfNeeded(offset: Int) {
        guard let browsePage else {
            return
        }

        let normalizedOffset = max(0, min(offset, max(browsePage.list.count - 1, 0)))
        let pageOffset = (normalizedOffset / browsePageSize) * browsePageSize

        guard browsePresentationState.loadedBrowseLoadOffsets.contains(pageOffset) == false else {
            return
        }
        guard browsePresentationState.activeBrowseLoadOffsets.contains(pageOffset) == false else {
            return
        }

        loadPage(offset: pageOffset, count: browsePageSize)
    }

    private func searchLibraryPivotItem(in page: BrowsePage) -> BrowseItem? {
        guard page.hierarchy == .search else {
            return nil
        }

        let lowercasedTitle = page.list.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowercasedTitle == "explore" || page.list.level == 0 else {
            return nil
        }

        return page.items.first(where: { item in
            item.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Library") == .orderedSame &&
            item.itemKey != nil
        })
    }

    private func shouldShowSearchResultsPage(for page: BrowsePage) -> Bool {
        guard selectedHierarchy == .search, page.hierarchy == .search else {
            return false
        }

        return page.list.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Search") == .orderedSame
    }

    private var supportsStructuredSearchResults: Bool { true }

    private func loadSearchSections(for query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            searchResultsPage = nil
            searchRootBrowsePage = nil
            return
        }

        searchSectionsTask?.cancel()
        searchSectionsTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                guard let results = try await sessionController?.browseSearchSections(
                    query: query,
                    zoneOrOutputID: selectedZoneID
                ),
                      Task.isCancelled == false,
                      selectedHierarchy == .search,
                      searchText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(query) == .orderedSame
                else {
                    return
                }

                searchResultsPage = SearchResultsPage(
                    query: results.query,
                    topHit: searchResultsPage?.topHit ?? results.topHit,
                    sections: results.sections
                )
            } catch {
                guard Task.isCancelled == false else {
                    return
                }
                errorState = ErrorState(title: "Search Failed", message: error.localizedDescription)
            }
        }
    }

    private var shouldRestoreSearchResultsOnBack: Bool {
        guard selectedHierarchy == .search,
              searchResultsPage != nil,
              let browsePage,
              browsePage.list.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Search") != .orderedSame
        else {
            return false
        }
        return true
    }

    private func restoreSearchResultsPage() {
        guard let searchRootBrowsePage else {
            return
        }

        browsePage = searchRootBrowsePage
        browseItemsByIndex.removeAll(keepingCapacity: true)
        for (index, item) in searchRootBrowsePage.items.enumerated() {
            browseItemsByIndex[searchRootBrowsePage.offset + index] = item
        }
        browsePresentationState.loadedBrowseLoadOffsets = [searchRootBrowsePage.offset]
        browsePresentationState.activeBrowseLoadOffsets.removeAll(keepingCapacity: true)
    }

    private func sendVolumeChange(outputID: String, how: VolumeChangeMode, value: Double) async {
        do {
            try await sessionController?.transportChangeVolume(outputID: outputID, how: how, value: value)
        } catch {
            errorState = ErrorState(title: "Volume Change Failed", message: error.localizedDescription)
        }
    }

    private func clampedSeekPosition(for zoneID: String, seconds: Double) -> Double {
        guard
            let zone = zones.first(where: { $0.zoneID == zoneID }),
            let length = zone.nowPlaying?.length
        else {
            return max(0, seconds)
        }
        return min(max(0, seconds), length)
    }

    private func applyOptimisticSeek(zoneID: String, seconds: Double) {
        let now = Date()
        let trackLength = zones.first(where: { $0.zoneID == zoneID })?.nowPlaying?.length
        pendingSeekStates[zoneID] = PendingSeekState(target: seconds, appliedAt: now, length: trackLength)
        nowPlayingUpdatedAt[zoneID] = now

        guard let index = zones.firstIndex(where: { $0.zoneID == zoneID }) else {
            return
        }

        zones[index].nowPlaying?.seekPosition = seconds
    }

    private func sessionEventSummary(_ event: RoonSessionEvent) -> [String: String] {
        switch event {
        case let .connectionChanged(payload):
            let statusSummary: String
            switch payload.status {
            case .disconnected:
                statusSummary = "disconnected"
            case let .connecting(mode):
                statusSummary = "connecting:\(mode)"
            case let .connected(core):
                statusSummary = "connected:\(core.displayName)"
            case let .authorizing(core):
                statusSummary = "authorizing:\(core?.displayName ?? "<nil>")"
            case let .error(message):
                statusSummary = "error:\(message)"
            }
            return ["event": "connectionChanged", "status": statusSummary]
        case let .authorizationRequired(payload):
            return ["event": "authorizationRequired", "core": payload.core?.displayName ?? "<nil>"]
        case let .zonesSnapshot(payload):
            return ["event": "zonesSnapshot", "zone_count": String(payload.zones.count)]
        case let .zonesChanged(payload):
            return [
                "event": "zonesChanged",
                "zone_count": String(payload.zones.count),
                "removed_zone_count": String(payload.removedZoneIDs.count)
            ]
        case let .queueSnapshot(payload):
            return ["event": "queueSnapshot", "item_count": String(payload.queue?.items.count ?? 0)]
        case let .queueChanged(payload):
            return ["event": "queueChanged", "item_count": String(payload.queue?.items.count ?? 0)]
        case let .browseListChanged(payload):
            return [
                "event": "browseListChanged",
                "hierarchy": payload.page.hierarchy.rawValue,
                "title": payload.page.list.title,
                "count": String(payload.page.list.count),
                "offset": String(payload.page.offset)
            ]
        case let .browseItemReplaced(payload):
            return ["event": "browseItemReplaced", "hierarchy": payload.hierarchy.rawValue, "title": payload.item.title]
        case let .browseItemRemoved(payload):
            return ["event": "browseItemRemoved", "hierarchy": payload.hierarchy.rawValue, "item_key": payload.itemKey]
        case let .nowPlayingChanged(payload):
            return ["event": "nowPlayingChanged", "zone_id": payload.zoneID, "title": payload.nowPlaying?.title ?? "<nil>"]
        case .persistRequested:
            return ["event": "persistRequested"]
        case let .errorRaised(payload):
            return ["event": "errorRaised", "code": payload.code]
        }
    }

    private func reconciledZoneSummary(_ zone: ZoneSummary, at date: Date) -> ZoneSummary {
        var reconciled = zone
        reconciled.nowPlaying = reconciledNowPlaying(zone.nowPlaying, for: zone, at: date)
        return reconciled
    }

    private func reconciledNowPlaying(_ nowPlaying: NowPlaying?, for zone: ZoneSummary, at date: Date) -> NowPlaying? {
        guard var nowPlaying else {
            pendingSeekStates.removeValue(forKey: zone.zoneID)
            return nil
        }

        guard let pending = pendingSeekStates[zone.zoneID] else {
            return nowPlaying
        }

        let optimisticPosition = advancedSeekPosition(
            basePosition: pending.target,
            length: pending.length ?? nowPlaying.length,
            state: zone.state,
            updatedAt: pending.appliedAt,
            at: date
        )

        let pendingAge = date.timeIntervalSince(pending.appliedAt)
        if pendingAge > pendingSeekGraceInterval {
            pendingSeekStates.removeValue(forKey: zone.zoneID)
            return nowPlaying
        }

        if let reportedPosition = nowPlaying.seekPosition,
           abs(reportedPosition - optimisticPosition) <= 3 {
            pendingSeekStates.removeValue(forKey: zone.zoneID)
            return nowPlaying
        }

        nowPlaying.seekPosition = optimisticPosition
        if nowPlaying.length == nil {
            nowPlaying.length = pending.length
        }
        return nowPlaying
    }

    private func optimisticSeekPosition(for zone: ZoneSummary, at date: Date) -> Double? {
        guard let pending = pendingSeekStates[zone.zoneID] else {
            return nil
        }

        if date.timeIntervalSince(pending.appliedAt) > pendingSeekGraceInterval {
            pendingSeekStates.removeValue(forKey: zone.zoneID)
            return nil
        }

        return advancedSeekPosition(
            basePosition: pending.target,
            length: pending.length ?? zone.nowPlaying?.length,
            state: zone.state,
            updatedAt: pending.appliedAt,
            at: date
        )
    }

    private func advancedSeekPosition(
        basePosition: Double,
        length: Double?,
        state: String,
        updatedAt: Date,
        at date: Date
    ) -> Double {
        let advanced = state == "playing"
            ? basePosition + max(0, date.timeIntervalSince(updatedAt))
            : basePosition
        if let length {
            return min(max(0, advanced), length)
        }
        return max(0, advanced)
    }

    private func autoConnectOnLaunchIfNeeded() {
        guard hasAttemptedAutoConnect == false else {
            return
        }
        hasAttemptedAutoConnect = true
        connectAutomatically()
    }

    var canGoForward: Bool {
        forwardNavigationTrail.isEmpty == false
    }

    func scrollOffset(for pageIdentity: String) -> CGFloat {
        pageScrollOffsets[pageIdentity] ?? 0
    }

    func rememberScrollOffset(_ offset: CGFloat, for pageIdentity: String) {
        pageScrollOffsets[pageIdentity] = max(0, offset)
    }

    func noteBrowseItemVisible(_ index: Int, for page: BrowsePage, prefetchArtwork: Bool = false) {
        let identity = browsePageIdentity(for: page)
        browseVisibleIndices[identity] = index
        scheduleBrowseVisibleRangeUpdate(
            index: index,
            page: page,
            identity: identity,
            prefetchArtwork: prefetchArtwork
        )
    }

    func prefetchArtworkAroundVisibleIndex(_ index: Int, for page: BrowsePage) {
        guard shouldPrefetchBrowseArtwork(for: page) else {
            Task { [artworkPipeline] in
                await artworkPipeline.cancelPrefetches()
            }
            return
        }

        let lowerBound = max(0, index - browseArtworkPrefetchRadius)
        let upperBound = min(page.list.count - 1, index + browseArtworkPrefetchRadius)
        guard lowerBound <= upperBound else {
            return
        }

        var requests: [ArtworkPipelineRequest] = []
        for candidateIndex in lowerBound...upperBound {
            guard let item = browseItem(at: candidateIndex),
                  let imageKey = item.imageKey,
                  imageKey.isEmpty == false
            else {
                continue
            }

            let request = ArtworkPipelineRequest(
                imageKey: imageKey,
                width: browseGridArtworkPixelSize,
                height: browseGridArtworkPixelSize,
                format: "image/jpeg"
            )
            requests.append(request)
        }

        let loader = artworkFetchLoader()
        Task { [artworkPipeline] in
            await artworkPipeline.prefetch(
                requests: requests,
                fetchArtwork: loader
            )
        }
    }

    private func scheduleBrowseVisibleRangeUpdate(
        index: Int,
        page: BrowsePage,
        identity: String,
        prefetchArtwork: Bool
    ) {
        if var pending = pendingBrowseVisibleRange, pending.pageIdentity == identity {
            pending.lowerBound = min(pending.lowerBound, index)
            pending.upperBound = max(pending.upperBound, index)
            pending.latestIndex = index
            pending.shouldPrefetchArtwork = pending.shouldPrefetchArtwork || prefetchArtwork
            pending.page = page
            pendingBrowseVisibleRange = pending
        } else {
            pendingBrowseVisibleRange = PendingBrowseVisibleRange(
                pageIdentity: identity,
                page: page,
                lowerBound: index,
                upperBound: index,
                latestIndex: index,
                shouldPrefetchArtwork: prefetchArtwork
            )
        }

        browseVisibleRangeTask?.cancel()
        browseVisibleRangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, Task.isCancelled == false else {
                return
            }
            self.flushPendingBrowseVisibleRange(identity: identity)
        }
    }

    private func flushPendingBrowseVisibleRange(identity: String) {
        guard let pending = pendingBrowseVisibleRange,
              pending.pageIdentity == identity
        else {
            return
        }
        pendingBrowseVisibleRange = nil

        guard let currentPage = browsePage,
              browsePageIdentity(for: pending.page) == browsePageIdentity(for: currentPage)
        else {
            return
        }

        let midpoint = (pending.lowerBound + pending.upperBound) / 2
        ensureBrowseItemsLoaded(for: midpoint)

        if pending.shouldPrefetchArtwork {
            prefetchArtworkAroundVisibleIndex(pending.latestIndex, for: pending.page)
        }
    }

    private var canHandleTypeSelect: Bool {
        guard let browsePage else {
            return false
        }
        let isTopLevelArtists = selectedHierarchy == .artists
        let isTopLevelAlbums = selectedHierarchy == .albums
        return browsePage.list.level == 0 && (isTopLevelArtists || isTopLevelAlbums)
    }

    private func jumpToBrowsePrefix(_ query: String, generation: Int) async {
        guard generation == typeSelectGeneration else {
            return
        }
        guard query.isEmpty == false else {
            return
        }

        if let loadedMatch = loadedBrowsePrefixMatch(query) {
            requestBrowseScroll(to: loadedMatch)
            return
        }

        guard let browsePage else {
            return
        }

        let pageCount = max((browsePage.list.count + browsePageSize - 1) / browsePageSize, 1)
        var low = 0
        var high = pageCount - 1
        var candidatePage: Int?

        while low <= high {
            let mid = (low + high) / 2
            guard let bounds = await pageTitleBounds(pageIndex: mid) else {
                return
            }

            if query.localizedCompare(bounds.first) == .orderedAscending {
                high = mid - 1
            } else if query.localizedCompare(bounds.last) == .orderedDescending {
                low = mid + 1
            } else {
                candidatePage = mid
                break
            }
        }

        if let candidatePage {
            for pageIndex in [candidatePage, max(candidatePage - 1, 0), min(candidatePage + 1, pageCount - 1)] {
                if let match = await pagePrefixMatch(pageIndex: pageIndex, query: query) {
                    requestBrowseScroll(to: match)
                    return
                }
            }
        }

        for pageIndex in 0..<pageCount {
            if let candidatePage, abs(pageIndex - candidatePage) <= 1 {
                continue
            }
            if let match = await pagePrefixMatch(pageIndex: pageIndex, query: query) {
                requestBrowseScroll(to: match)
                return
            }
        }
    }

    private func requestBrowseScroll(to index: Int) {
        browseScrollTargetIndex = index
        browseScrollTargetRequestID += 1
    }

    private func loadedBrowsePrefixMatch(_ query: String) -> Int? {
        browseItemsByIndex
            .sorted(by: { $0.key < $1.key })
            .first(where: { normalizedBrowseTitle($0.value.title).hasPrefix(query) })?
            .key
    }

    private func pageTitleBounds(pageIndex: Int) async -> (first: String, last: String)? {
        guard let items = await ensureBrowsePageLoaded(pageIndex: pageIndex), items.isEmpty == false else {
            return nil
        }

        let titles = items.map { normalizedBrowseTitle($0.title) }
        guard let first = titles.first, let last = titles.last else {
            return nil
        }
        return (first, last)
    }

    private func pagePrefixMatch(pageIndex: Int, query: String) async -> Int? {
        guard let items = await ensureBrowsePageLoaded(pageIndex: pageIndex), items.isEmpty == false else {
            return nil
        }

        let offset = pageIndex * browsePageSize
        for (itemOffset, item) in items.enumerated() where normalizedBrowseTitle(item.title).hasPrefix(query) {
            return offset + itemOffset
        }
        return nil
    }

    private func ensureBrowsePageLoaded(pageIndex: Int) async -> [BrowseItem]? {
        let offset = pageIndex * browsePageSize

        if browsePresentationState.loadedBrowseLoadOffsets.contains(offset) == false {
            let requestID = beginBrowsePageRequest()
            browsePresentationState.activeBrowseLoadOffsets.insert(offset)
            do {
                let snapshot = try await sessionController?.browseLoadPage(
                    hierarchy: selectedHierarchy,
                    offset: offset,
                    count: browsePageSize
                )
                guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                    browsePresentationState.activeBrowseLoadOffsets.remove(offset)
                    return nil
                }
            } catch {
                browsePresentationState.activeBrowseLoadOffsets.remove(offset)
                return nil
            }
        }

        return loadedItemsForPage(offset: offset)
    }

    private func loadedItemsForPage(offset: Int) -> [BrowseItem] {
        (offset..<(offset + browsePageSize))
            .compactMap { browseItemsByIndex[$0] }
    }

    private func restoreBrowseViewportIfNeeded(for page: BrowsePage) {
        guard let lastVisibleIndex = browseVisibleIndices[browsePageIdentity(for: page)] else {
            return
        }

        ensureBrowseItemsLoaded(for: lastVisibleIndex)
    }

    private func normalizedBrowseTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func browsePageIdentity(for page: BrowsePage) -> String {
        [
            page.hierarchy.rawValue,
            page.list.title,
            String(page.list.level),
            selectedBrowseServiceTitle ?? ""
        ].joined(separator: "|")
    }

    private func shouldPrefetchBrowseArtwork(for page: BrowsePage) -> Bool {
        guard page.list.level == 0 else {
            return false
        }
        return page.hierarchy == .albums || page.hierarchy == .artists
    }

    private func performNavigation(_ action: BrowseNavigationAction, historyMode: HistoryMode) {
        switch action {
        case let .openItem(hierarchy, itemKey):
            MacaroonDebugLogger.logApp(
                "app.open_item",
                details: [
                    "hierarchy": hierarchy.rawValue,
                    "item_key": itemKey
                ]
            )

            let requestID = beginBrowseNavigationRequest()
            Task {
                do {
                    let snapshot = try await sessionController?.browseOpen(
                        hierarchy: hierarchy,
                        zoneOrOutputID: selectedZoneID,
                        itemKey: itemKey
                    )
                    guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                        return
                    }
                    commitNavigation(action, historyMode: historyMode)
                } catch {
                    guard isCurrentBrowseRequest(requestID) else {
                        return
                    }
                    if await recoverFromStaleBrowseItemError(error) == false {
                        errorState = ErrorState(title: "Browse Item Failed", message: error.localizedDescription)
                    }
                }
            }
        case let .openBrowseService(title):
            selectedHierarchy = .browse
            selectedBrowseServiceTitle = title
            pendingSearchQuery = nil
            MacaroonDebugLogger.logApp(
                "app.open_browse_service",
                details: ["title": title, "zone_id": selectedZoneID ?? "<nil>"]
            )

            let requestID = beginBrowseNavigationRequest()
            Task {
                do {
                    let snapshot = try await sessionController?.browseOpenService(title: title, zoneOrOutputID: selectedZoneID)
                    guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                        return
                    }
                    commitNavigation(action, historyMode: historyMode)
                } catch {
                    guard isCurrentBrowseRequest(requestID) else {
                        return
                    }
                    errorState = ErrorState(title: "Browse Failed", message: error.localizedDescription)
                }
            }
        case let .search(query):
            selectedHierarchy = .search
            selectedBrowseServiceTitle = nil
            pendingSearchQuery = query
            searchText = query
            searchResultsPage = nil
            MacaroonDebugLogger.logApp(
                "app.run_search",
                details: ["query": query, "zone_id": selectedZoneID ?? "<nil>"]
            )

            let requestID = beginBrowseNavigationRequest()
            Task {
                do {
                    let snapshot = try await sessionController?.browseHome(hierarchy: .search, zoneOrOutputID: selectedZoneID)
                    guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                        return
                    }
                    commitNavigation(action, historyMode: historyMode)
                } catch {
                    guard isCurrentBrowseRequest(requestID) else {
                        return
                    }
                    errorState = ErrorState(title: "Search Failed", message: error.localizedDescription)
                }
            }
        case let .openSearchMatch(query, categoryTitle, matchTitle):
            selectedHierarchy = .search
            selectedBrowseServiceTitle = nil
            pendingSearchQuery = nil
            searchText = query
            searchResultsPage = nil

            let requestID = beginBrowseNavigationRequest()
            Task {
                do {
                    let snapshot = try await sessionController?.browseOpenSearchMatch(
                        query: query,
                        categoryTitle: categoryTitle,
                        matchTitle: matchTitle,
                        zoneOrOutputID: selectedZoneID
                    )
                    guard applyBrowseSnapshot(snapshot, requestID: requestID) else {
                        return
                    }
                    commitNavigation(action, historyMode: historyMode)
                } catch {
                    guard isCurrentBrowseRequest(requestID) else {
                        return
                    }
                    if await recoverFromStaleBrowseItemError(error) == false {
                        let title = categoryTitle == "Artists" ? "Artist Navigation Failed" : "Album Navigation Failed"
                        errorState = ErrorState(title: title, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func recoverFromStaleBrowseItemError(_ error: Error) async -> Bool {
        guard isStaleBrowseItemError(error) else {
            return false
        }

        MacaroonDebugLogger.logApp(
            "app.recover_stale_browse_item",
            details: [
                "hierarchy": selectedHierarchy.rawValue,
                "message": error.localizedDescription
            ]
        )

        do {
            let requestID = beginBrowseNavigationRequest()
            let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot: BrowsePageSnapshot?
            if selectedHierarchy == .search,
               trimmedSearch.isEmpty == false {
                let query = trimmedSearch
                pendingSearchQuery = query
                searchResultsPage = nil
                searchRootBrowsePage = nil
                snapshot = try await sessionController?.browseHome(hierarchy: .search, zoneOrOutputID: selectedZoneID)
            } else if let selectedBrowseServiceTitle, selectedHierarchy == .browse {
                snapshot = try await sessionController?.browseOpenService(title: selectedBrowseServiceTitle, zoneOrOutputID: selectedZoneID)
            } else {
                snapshot = try await sessionController?.browseRefresh(hierarchy: selectedHierarchy, zoneOrOutputID: selectedZoneID)
            }
            applyBrowseSnapshot(snapshot, requestID: requestID)
            return true
        } catch {
            MacaroonDebugLogger.logError("stale_browse_recovery.failed", error: error)
            return false
        }
    }

    private func isStaleBrowseItemError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("invaliditemkey") ||
            message.contains("invalid item key") ||
            message.contains("no action list available for the selected item")
    }

    private func commitNavigation(_ action: BrowseNavigationAction, historyMode: HistoryMode) {
        switch historyMode {
        case .none:
            return
        case .newAction:
            navigationTrail.append(action)
            forwardNavigationTrail.removeAll()
        case .replayForward:
            navigationTrail.append(action)
        }
    }

    private func persistEndpointIfNeeded(for core: CoreSummary) {
        guard let host = core.host, let port = core.port else {
            return
        }

        do {
            var state = try sessionStore.load()
            state.pairedCoreID = core.coreID
            state.endpoints[core.coreID] = CoreEndpoint(host: host, port: port)
            try sessionStore.save(state)
        } catch {
            errorState = ErrorState(title: "Session Save Failed", message: error.localizedDescription)
        }
    }

    private func startConnectionResolutionMonitor() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else {
                return
            }

            switch self.connectionStatus {
            case .connected:
                return
            case .connecting, .authorizing:
                self.autoConnectionIssue = "The app could not resolve a Core automatically. If you have multiple Cores or discovery is blocked, open Settings to choose a server manually."
                self.errorState = ErrorState(
                    title: "Connection Needs Attention",
                    message: self.autoConnectionIssue ?? "Open Settings to choose a server manually."
                )
            case .disconnected, .error:
                self.autoConnectionIssue = "No reachable Roon Core was resolved automatically. Open Settings to enter a server manually."
                self.errorState = ErrorState(
                    title: "No Core Connected",
                    message: self.autoConnectionIssue ?? "Open Settings to enter a server manually."
                )
            }
        }
    }
}

struct SessionStateStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let fileManager = FileManager.default
    private let storageURLOverride: URL?

    init(storageURL: URL? = nil) {
        self.storageURLOverride = storageURL
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> PersistedSessionState {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PersistedSessionState.self, from: data)
    }

    func save(_ state: PersistedSessionState) throws {
        let url = try storageURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    func storageURL() throws -> URL {
        if let storageURLOverride {
            return storageURLOverride
        }
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Macaroon", isDirectory: true)
            .appendingPathComponent("roon-session.json", isDirectory: false)
    }
}
