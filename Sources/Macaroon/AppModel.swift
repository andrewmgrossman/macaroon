import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var connectionStatus: ConnectionStatus = .disconnected
    var currentCore: CoreSummary?
    var manualConnect = ManualConnectConfiguration(host: "127.0.0.1", port: 9100)
    var selectedHierarchy: BrowseHierarchy = .browse
    var browsePage: BrowsePage?
    var browseItemsByIndex: [Int: BrowseItem] = [:]
    var zones: [ZoneSummary] = []
    var selectedZoneID: String?
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

    private let browsePageSize = 100

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

    func openHierarchy(_ hierarchy: BrowseHierarchy) {
        selectedHierarchy = hierarchy
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

    func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return
        }

        selectedHierarchy = .search
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

    var selectedZone: ZoneSummary? {
        guard let selectedZoneID else {
            return nil
        }
        return zones.first(where: { $0.zoneID == selectedZoneID })
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
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
            case let .connecting(mode):
                connectionStatus = .connecting(mode: mode)
            case let .connected(core):
                currentCore = core
                connectionStatus = .connected(core)
                autoConnectionIssue = nil
                persistEndpointIfNeeded(for: core)
                connectionMonitorTask?.cancel()
                connectionMonitorTask = nil
                userInitiatedDisconnect = false
                subscribeToZones()
                openHierarchy(selectedHierarchy)
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
        case let .browseListChanged(payload):
            applyBrowsePage(payload.page)
            if
                selectedHierarchy == .search,
                let pendingSearchQuery,
                let promptItem = payload.page.items.first(where: { $0.inputPrompt != nil })
            {
                self.pendingSearchQuery = nil
                submitPrompt(for: promptItem, value: pendingSearchQuery)
            }
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
            zones[index].nowPlaying = payload.nowPlaying
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
        let helperURL = Bundle.module.url(forResource: "launch-helper", withExtension: "sh", subdirectory: "Resources")
        if let helperURL {
            return HelperProcessController(launchPath: helperURL)
        }
        return MockBridgeService()
    }

    private func replaceZones(with incoming: [ZoneSummary]) {
        zones = incoming.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        normalizeSelectedZone()
    }

    private func mergeZones(_ incoming: [ZoneSummary]) {
        guard incoming.isEmpty == false else {
            return
        }

        var merged = Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
        for zone in incoming {
            merged[zone.zoneID] = zone
        }

        zones = merged.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        normalizeSelectedZone()
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
