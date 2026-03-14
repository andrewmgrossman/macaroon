import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private struct PendingSeekState {
        var target: Double
        var appliedAt: Date
        var length: Double?
    }

    var connectionStatus: ConnectionStatus = .disconnected
    var currentCore: CoreSummary?
    var manualConnect = ManualConnectConfiguration(host: "127.0.0.1", port: 9100)
    var selectedHierarchy: BrowseHierarchy = .albums
    var browsePage: BrowsePage?
    var browseItemsByIndex: [Int: BrowseItem] = [:]
    var browseServices: [BrowseServiceSummary] = []
    var selectedBrowseServiceTitle: String?
    var zones: [ZoneSummary] = []
    var selectedZoneID: String?
    var queueState: QueueState?
    var isQueueSidebarVisible = false
    var errorState: ErrorState?
    var helperStatus = "Idle"
    var lastBridgeError: BridgeErrorPayload?
    var isUsingMockBridge = false
    var autoConnectionIssue: String?
    var searchText = ""

    @ObservationIgnored
    private var bridge: BridgeService?
    @ObservationIgnored
    private var sessionStore = SessionStateStore()
    @ObservationIgnored
    private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored
    private var hasAttemptedAutoConnect = false
    @ObservationIgnored
    private var connectionMonitorTask: Task<Void, Never>?
    @ObservationIgnored
    private var userInitiatedDisconnect = false
    @ObservationIgnored
    private var pendingSearchQuery: String?
    @ObservationIgnored
    private var activeBrowseLoadOffsets: Set<Int> = []
    @ObservationIgnored
    private var loadedBrowseLoadOffsets: Set<Int> = []
    @ObservationIgnored
    private var nowPlayingUpdatedAt: [String: Date] = [:]
    @ObservationIgnored
    private var volumeUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingSeekStates: [String: PendingSeekState] = [:]
    @ObservationIgnored
    private var queueSubscriptionZoneID: String?
    @ObservationIgnored
    private var hasLoadedBrowseServices = false

    private let browsePageSize = 100
    private let pendingSeekGraceInterval: TimeInterval = 2.0

    func start() {
        guard bridge == nil else {
            return
        }

        let service = makeBridgeService()
        service.eventHandler = { [weak self] message in
            self?.handleBridgeMessage(message)
        }

        bridge = service
        isUsingMockBridge = service is MockBridgeService

        Task {
            do {
                helperStatus = "Starting helper"
                try await service.start()
                helperStatus = isUsingMockBridge ? "Running in mock mode" : "Helper connected"
                autoConnectOnLaunchIfNeeded()
            } catch {
                helperStatus = "Failed to start helper"
                errorState = ErrorState(title: "Helper Launch Failed", message: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let bridge else {
            return
        }

        Task {
            await bridge.stop()
        }
        self.bridge = nil
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
    }

    func prepareForTermination() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil

        guard let bridge else {
            return
        }

        if let helper = bridge as? HelperProcessController {
            helper.terminateSynchronously()
        } else {
            Task {
                await bridge.stop()
            }
        }

        self.bridge = nil
    }

    func connectAutomatically() {
        start()
        userInitiatedDisconnect = false
        connectionStatus = .connecting(mode: "discovery")
        autoConnectionIssue = nil

        Task {
            do {
                let state = try sessionStore.load()
                try await bridge?.send("connect.auto", params: ConnectAutoParams(persistedState: state))
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

        Task {
            do {
                let state = try sessionStore.load()
                try await bridge?.send("connect.manual", params: ConnectManualParams(
                    host: manualConnect.host,
                    port: manualConnect.port,
                    persistedState: state
                ))
            } catch {
                errorState = ErrorState(title: "Manual Connect Failed", message: error.localizedDescription)
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        Task {
            do {
                try await bridge?.send("core.disconnect", params: DisconnectParams())
            } catch {
                errorState = ErrorState(title: "Disconnect Failed", message: error.localizedDescription)
            }
        }
    }

    func subscribeToZones() {
        Task {
            do {
                try await bridge?.send("zones.subscribe", params: ZonesSubscribeParams())
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

        Task {
            do {
                try await bridge?.send("queue.subscribe", params: QueueSubscribeParams(
                    zoneOrOutputID: selectedZoneID,
                    maxItemCount: 300
                ))
            } catch {
                errorState = ErrorState(title: "Queue Subscription Failed", message: error.localizedDescription)
            }
        }
    }

    func openHierarchy(_ hierarchy: BrowseHierarchy) {
        selectedHierarchy = hierarchy
        selectedBrowseServiceTitle = nil
        if hierarchy != .search {
            pendingSearchQuery = nil
        }
        Task {
            do {
                try await bridge?.send("browse.home", params: BrowseHomeParams(
                    hierarchy: hierarchy,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Browse Failed", message: error.localizedDescription)
            }
        }
    }

    func openBrowseService(_ service: BrowseServiceSummary) {
        selectedHierarchy = .browse
        selectedBrowseServiceTitle = service.title
        pendingSearchQuery = nil

        Task {
            do {
                try await bridge?.send("browse.openService", params: BrowseOpenServiceParams(
                    title: service.title,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Browse Failed", message: error.localizedDescription)
            }
        }
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

        selectedHierarchy = .search
        selectedBrowseServiceTitle = nil
        pendingSearchQuery = query

        Task {
            do {
                try await bridge?.send("browse.home", params: BrowseHomeParams(
                    hierarchy: .search,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Search Failed", message: error.localizedDescription)
            }
        }
    }

    func openNowPlayingArtist() {
        guard
            let artistName = selectedZone?.nowPlaying?.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            artistName.isEmpty == false
        else {
            return
        }

        selectedHierarchy = .search
        selectedBrowseServiceTitle = nil
        pendingSearchQuery = nil

        Task {
            do {
                try await bridge?.send("browse.openSearchMatch", params: BrowseOpenSearchMatchParams(
                    query: artistName,
                    categoryTitle: "Artists",
                    matchTitle: artistName,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Artist Navigation Failed", message: error.localizedDescription)
            }
        }
    }

    func openNowPlayingAlbum() {
        guard
            let albumTitle = selectedZone?.nowPlaying?.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            albumTitle.isEmpty == false
        else {
            return
        }

        selectedHierarchy = .search
        selectedBrowseServiceTitle = nil
        pendingSearchQuery = nil

        Task {
            do {
                try await bridge?.send("browse.openSearchMatch", params: BrowseOpenSearchMatchParams(
                    query: albumTitle,
                    categoryTitle: "Albums",
                    matchTitle: albumTitle,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Album Navigation Failed", message: error.localizedDescription)
            }
        }
    }

    func openItem(_ item: BrowseItem) {
        guard let itemKey = item.itemKey else {
            return
        }

        Task {
            do {
                try await bridge?.send("browse.open", params: BrowseOpenParams(
                    hierarchy: selectedHierarchy,
                    zoneOrOutputID: selectedZoneID,
                    itemKey: itemKey
                ))
            } catch {
                errorState = ErrorState(title: "Browse Item Failed", message: error.localizedDescription)
            }
        }
    }

    func goBack() {
        Task {
            do {
                try await bridge?.send("browse.back", params: BrowseBackParams(
                    hierarchy: selectedHierarchy,
                    levels: 1,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Browse Back Failed", message: error.localizedDescription)
            }
        }
    }

    func refreshBrowse() {
        Task {
            do {
                try await bridge?.send("browse.refresh", params: BrowseRefreshParams(
                    hierarchy: selectedHierarchy,
                    zoneOrOutputID: selectedZoneID
                ))
            } catch {
                errorState = ErrorState(title: "Refresh Failed", message: error.localizedDescription)
            }
        }
    }

    func loadPage(offset: Int, count: Int = 100) {
        activeBrowseLoadOffsets.insert(offset)
        Task {
            do {
                try await bridge?.send("browse.loadPage", params: BrowseLoadPageParams(
                    hierarchy: selectedHierarchy,
                    offset: offset,
                    count: count
                ))
            } catch {
                activeBrowseLoadOffsets.remove(offset)
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

        Task {
            do {
                guard let bridge else {
                    return
                }

                let menu = try await bridge.request(
                    "browse.contextActions",
                    params: BrowseContextActionsParams(
                        hierarchy: selectedHierarchy,
                        itemKey: itemKey,
                        zoneOrOutputID: selectedZoneID
                    ),
                    as: BrowseActionMenuResult.self
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

                try await bridge.send(
                    "browse.performAction",
                    params: BrowsePerformActionParams(
                        hierarchy: selectedHierarchy,
                        sessionKey: menu.sessionKey,
                        itemKey: itemKey,
                        zoneOrOutputID: selectedZoneID,
                        contextItemKey: itemKey,
                        actionTitle: action.title
                    )
                )
            } catch {
                errorState = ErrorState(title: "Playback Action Failed", message: error.localizedDescription)
            }
        }
    }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func submitPrompt(for item: BrowseItem, value: String) {
        guard let itemKey = item.itemKey else {
            return
        }

        Task {
            do {
                try await bridge?.send("browse.submitInput", params: BrowseSubmitInputParams(
                    hierarchy: selectedHierarchy,
                    itemKey: itemKey,
                    input: value,
                    zoneOrOutputID: selectedZoneID
                ))
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

        Task {
            do {
                try await bridge?.send("transport.command", params: TransportCommandParams(
                    zoneOrOutputID: selectedZoneID,
                    command: command
                ))
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

        Task {
            do {
                try await bridge?.send("transport.seek", params: TransportSeekParams(
                    zoneOrOutputID: selectedZoneID,
                    how: "absolute",
                    seconds: targetSeconds
                ))
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

        Task {
            do {
                try await bridge?.send("transport.mute", params: TransportMuteParams(
                    outputID: output.outputID,
                    how: targetMode
                ))
            } catch {
                errorState = ErrorState(title: "Mute Failed", message: error.localizedDescription)
            }
        }
    }

    func toggleQueueSidebar() {
        isQueueSidebarVisible.toggle()
    }

    func selectZone(_ zoneID: String?) {
        selectedZoneID = zoneID
        queueSubscriptionZoneID = nil
        subscribeToQueue()
    }

    func playQueueItem(_ item: QueueItemSummary) {
        guard let selectedZoneID else {
            return
        }

        Task {
            do {
                try await bridge?.send("queue.playFromHere", params: QueuePlayFromHereParams(
                    zoneOrOutputID: selectedZoneID,
                    queueItemID: item.queueItemID
                ))
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

    func loadArtwork(imageKey: String?, width: Int = 320, height: Int = 320) async -> NSImage? {
        guard let imageKey, !imageKey.isEmpty else {
            return nil
        }

        if let cached = artworkCache[imageKey] {
            return cached
        }

        do {
            guard let bridge else {
                return nil
            }
            let result = try await bridge.request(
                "image.fetch",
                params: ImageFetchParams(imageKey: imageKey, width: width, height: height, format: "image/jpeg"),
                as: ImageFetchedResult.self
            )
            guard let image = NSImage(contentsOfFile: result.localURL) else {
                return nil
            }
            artworkCache[imageKey] = image
            return image
        } catch {
            return nil
        }
    }

    private func handleBridgeMessage(_ message: BridgeInboundMessage) {
        switch message {
        case let .response(_, _, error):
            if let error {
                lastBridgeError = error
                errorState = ErrorState(title: "Bridge Error", message: error.message)
            }
        case let .event(event):
            apply(event)
        }
    }

    private func apply(_ event: BridgeEventEnvelope) {
        switch event {
        case let .connectionChanged(payload):
            switch payload.status {
            case .disconnected:
                currentCore = nil
                connectionStatus = .disconnected
                queueState = nil
                queueSubscriptionZoneID = nil
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
            mergeZones(payload.zones)
        case let .queueSnapshot(payload):
            queueState = payload.queue
        case let .queueChanged(payload):
            queueState = payload.queue
        case let .browseListChanged(payload):
            if
                selectedHierarchy == .search,
                let pendingSearchQuery
            {
                if let libraryItem = searchLibraryPivotItem(in: payload.page) {
                    openItem(libraryItem)
                    return
                }

                if let promptItem = payload.page.items.first(where: { $0.inputPrompt != nil }) {
                    self.pendingSearchQuery = nil
                    submitPrompt(for: promptItem, value: pendingSearchQuery)
                    return
                }
            }
            if payload.page.hierarchy == .browse, payload.page.list.level == 0 {
                selectedBrowseServiceTitle = nil
            }
            applyBrowsePage(payload.page)
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

    private func makeBridgeService() -> BridgeService {
        if NativeBridgeRuntimeConfiguration.isEnabled {
            return NativeRoonBridgeService()
        }

        let helperURL = Bundle.module.url(forResource: "launch-helper", withExtension: "sh", subdirectory: "Resources")
        if let helperURL {
            return HelperProcessController(launchPath: helperURL)
        }
        return MockBridgeService()
    }

    private func loadBrowseServicesIfNeeded() {
        guard hasLoadedBrowseServices == false else {
            return
        }
        hasLoadedBrowseServices = true

        Task {
            do {
                guard let bridge else {
                    return
                }
                let result = try await bridge.request("browse.services", params: EmptyParams(), as: BrowseServicesResult.self)
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

    private func mergeZones(_ incoming: [ZoneSummary]) {
        guard incoming.isEmpty == false else {
            return
        }

        var merged = Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
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
        if selectedZoneID == nil {
            selectedZoneID = zones.first?.zoneID
        } else if zones.contains(where: { $0.zoneID == selectedZoneID }) == false {
            selectedZoneID = zones.first?.zoneID
        }
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
            loadedBrowseLoadOffsets.removeAll(keepingCapacity: true)
            activeBrowseLoadOffsets.removeAll(keepingCapacity: true)
        }

        activeBrowseLoadOffsets.remove(incoming.offset)
        loadedBrowseLoadOffsets.insert(incoming.offset)

        for (index, item) in incoming.items.enumerated() {
            browseItemsByIndex[incoming.offset + index] = item
        }

        browsePage = incoming
    }

    private func requestBrowsePageIfNeeded(offset: Int) {
        guard let browsePage else {
            return
        }

        let normalizedOffset = max(0, min(offset, max(browsePage.list.count - 1, 0)))
        let pageOffset = (normalizedOffset / browsePageSize) * browsePageSize

        guard loadedBrowseLoadOffsets.contains(pageOffset) == false else {
            return
        }
        guard activeBrowseLoadOffsets.contains(pageOffset) == false else {
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

    private func sendVolumeChange(outputID: String, how: VolumeChangeMode, value: Double) async {
        do {
            try await bridge?.send("transport.changeVolume", params: TransportVolumeParams(
                outputID: outputID,
                how: how,
                value: value
            ))
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
