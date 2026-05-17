import Foundation

enum NativeSessionError: LocalizedError, Equatable, Sendable {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The native session returned an empty response."
        }
    }
}

@MainActor
final class NativeRoonSessionController: RoonSessionController {
    var eventHandler: (@MainActor (RoonSessionEvent) -> Void)?

    private var isStarted = false
    private let discoveryClient: any RoonDiscoveryClientProtocol
    private let transport: RoonWebSocketTransport
    private let registryClient: NativeRegistryClient
    private let browseClient: NativeBrowseClient
    private let imageClient: NativeImageClient
    private let transportClient: NativeTransportClient
    private let queueClient: NativeQueueClient
    private let zoneClient: NativeZoneClient
    private var currentCore: CoreSummary?
    private var persistedState = PersistedSessionState.empty
    private var liveZonesByID: [String: ZoneSummary] = [:]
    private var liveQueueState: QueueState?
    private var queueSubscriptionGeneration = 0
    private var lastConnectIntent: ConnectIntent?
    private var reconnectTask: Task<Void, Never>?
    private var hasConfiguredRegistryFailureHandler = false

    private enum ConnectIntent {
        case automatic
        case manual(host: String, port: Int)
    }

    init(
        discoveryClient: any RoonDiscoveryClientProtocol = RoonDiscoveryClient(),
        transport: RoonWebSocketTransport = RoonWebSocketTransport(),
        registryClient: NativeRegistryClient = NativeRegistryClient(),
        browseClient: NativeBrowseClient = NativeBrowseClient(),
        imageClient: NativeImageClient = NativeImageClient(),
        transportClient: NativeTransportClient = NativeTransportClient(),
        queueClient: NativeQueueClient = NativeQueueClient(),
        zoneClient: NativeZoneClient = NativeZoneClient()
    ) {
        self.discoveryClient = discoveryClient
        self.transport = transport
        self.registryClient = registryClient
        self.browseClient = browseClient
        self.imageClient = imageClient
        self.transportClient = transportClient
        self.queueClient = queueClient
        self.zoneClient = zoneClient
    }

    func start() async throws {
        guard isStarted == false else {
            return
        }
        await configureRegistryFailureHandlerIfNeeded()
        isStarted = true
        await discoveryClient.start()
        MacaroonDebugLogger.logApp("native_session.start")
    }

    func stop() async {
        await registryClient.disconnect()
        await discoveryClient.stop()
        await transport.disconnect()
        currentCore = nil
        liveZonesByID = [:]
        liveQueueState = nil
        queueSubscriptionGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        isStarted = false
        MacaroonDebugLogger.logApp("native_session.stop")
    }

    func connectAutomatically(persistedState: PersistedSessionState) async throws {
        await configureRegistryFailureHandlerIfNeeded()
        self.persistedState = persistedState
        lastConnectIntent = .automatic
        reconnectTask?.cancel()
        reconnectTask = nil

        var lastError: Error?
        if let savedCandidate = savedAutomaticConnectionCandidate(persistedState: persistedState) {
            do {
                try await connect(to: savedCandidate, persistedState: persistedState)
                return
            } catch let error as NativeRegistryError {
                MacaroonDebugLogger.logError(
                    "session.auto_connect_candidate_failed",
                    details: ["mode": savedCandidate.mode],
                    error: error
                )
                if case .authorizationRequired = error {
                    try await handleRegistryError(error)
                    return
                }
                lastError = error
            } catch {
                MacaroonDebugLogger.logError(
                    "session.auto_connect_candidate_failed",
                    details: ["mode": savedCandidate.mode],
                    error: error
                )
                lastError = error
            }
        }

        let candidates = await discoveredAutomaticConnectionCandidates(persistedState: persistedState)
        MacaroonLog.connection.info("Automatic discovery candidates=\(candidates.count, privacy: .public)")
        guard candidates.isEmpty == false else {
            if let lastError {
                MacaroonDebugLogger.logError("session.auto_connect_failed", error: lastError)
                eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .error(message: lastError.localizedDescription))))
                throw lastError
            }
            eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .error(
                message: "No reachable Roon Core was discovered. Check that your Core is running, or enter its host and port manually."
            ))))
            return
        }

        for candidate in candidates {
            do {
                try await connect(to: candidate, persistedState: persistedState)
                return
            } catch let error as NativeRegistryError {
                MacaroonDebugLogger.logError(
                    "session.auto_connect_candidate_failed",
                    details: ["mode": candidate.mode],
                    error: error
                )
                if case .authorizationRequired = error {
                    try await handleRegistryError(error)
                    return
                }
                lastError = error
            } catch {
                MacaroonDebugLogger.logError(
                    "session.auto_connect_candidate_failed",
                    details: ["mode": candidate.mode],
                    error: error
                )
                lastError = error
            }
        }

        if let lastError {
            MacaroonDebugLogger.logError("session.auto_connect_failed", error: lastError)
            eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .error(message: lastError.localizedDescription))))
            throw lastError
        }
    }

    private func connect(
        to candidate: AutomaticConnectionCandidate,
        persistedState: PersistedSessionState
    ) async throws {
        eventHandler?(.connectionChanged(ConnectionChangedEvent(
            status: .connecting(mode: candidate.mode)
        )))

        let result: NativeRegistryConnectionResult
        switch candidate.source {
        case let .saved(endpoint):
            result = try await registryClient.connectSavedEndpoint(
                endpoint: endpoint,
                persistedState: persistedState
            )
        case let .discovered(discovery):
            result = try await registryClient.connectDiscovered(
                discovery: discovery,
                persistedState: persistedState
            )
        }

        self.persistedState = result.persistedState
        currentCore = result.core
        MacaroonDebugLogger.logApp(
            "session.connected",
            details: [
                "mode": candidate.mode,
                "core_id": result.core.coreID,
                "display_name": result.core.displayName
            ]
        )
        MacaroonLog.connection.info("Connected mode=\(candidate.mode, privacy: .public) core=\(result.core.displayName, privacy: .public)")
        eventHandler?(.persistRequested(PersistRequestedEvent(persistedState: result.persistedState)))
        eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .connected(result.core))))
    }

    func connectManually(host: String, port: Int, persistedState: PersistedSessionState) async throws {
        await configureRegistryFailureHandlerIfNeeded()
        self.persistedState = persistedState
        lastConnectIntent = .manual(host: host, port: port)
        reconnectTask?.cancel()
        reconnectTask = nil
        let core = CoreSummary(
            coreID: "",
            displayName: "\(host):\(port)",
            displayVersion: "",
            host: host,
            port: port
        )

        eventHandler?(.connectionChanged(ConnectionChangedEvent(
            status: .connecting(mode: "manual")
        )))

        do {
            let result = try await registryClient.connectManual(
                host: host,
                port: port,
                persistedState: persistedState
            )
            self.persistedState = result.persistedState
            currentCore = result.core
            MacaroonDebugLogger.logApp(
                "session.connected",
                details: [
                    "mode": "manual",
                    "core_id": result.core.coreID,
                    "display_name": result.core.displayName
                ]
            )
            MacaroonLog.connection.info("Connected mode=manual core=\(result.core.displayName, privacy: .public)")
            eventHandler?(.persistRequested(PersistRequestedEvent(persistedState: result.persistedState)))
            eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .connected(result.core))))
        } catch let error as NativeRegistryError {
            MacaroonDebugLogger.logError("session.manual_connect_failed", error: error)
            if case .authorizationRequired = error {
                eventHandler?(.authorizationRequired(AuthorizationRequiredEvent(core: core)))
                eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .authorizing(core))))
                return
            }
            try await handleRegistryError(error)
        }
    }

    func disconnect() async {
        lastConnectIntent = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await registryClient.disconnect()
        currentCore = nil
        liveZonesByID = [:]
        liveQueueState = nil
        queueSubscriptionGeneration += 1
        eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .disconnected)))
    }

    func subscribeZones() async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }

        try await zoneClient.subscribe(
            session: session,
            subscriptionKey: 0
        ) { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleZonesSubscriptionMessage(message)
            }
        }
    }

    func subscribeQueue(zoneOrOutputID: String, maxItemCount: Int) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        queueSubscriptionGeneration += 1
        liveQueueState = nil
        let generation = queueSubscriptionGeneration

        try await queueClient.subscribe(
            session: session,
            zoneOrOutputID: zoneOrOutputID,
            maxItemCount: maxItemCount,
            subscriptionKey: generation
        ) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, generation == self.queueSubscriptionGeneration else {
                    return
                }
                do {
                    guard let update = try await self.queueClient.process(
                        message: message,
                        zoneOrOutputID: zoneOrOutputID,
                        previousState: self.liveQueueState
                    ) else {
                        return
                    }

                    switch update.kind {
                    case .snapshot:
                        self.liveQueueState = update.queue
                        if update.queue == nil {
                            self.queueSubscriptionGeneration += 1
                        }
                        self.eventHandler?(.queueSnapshot(QueueSnapshotEvent(queue: update.queue)))
                    case .changed:
                        self.liveQueueState = update.queue
                        self.eventHandler?(.queueChanged(QueueChangedEvent(queue: update.queue)))
                    }
                } catch {
                    MacaroonDebugLogger.logError(
                        "queue.decode_failed",
                        details: [
                            "zone_or_output_id": zoneOrOutputID,
                            "generation": String(generation)
                        ],
                        error: error
                    )
                    self.eventHandler?(.errorRaised(ErrorRaisedEvent(
                        code: "queue.error",
                        message: error.localizedDescription
                    )))
                }
            }
        }
    }

    func queuePlayFromHere(zoneOrOutputID: String, queueItemID: String) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await queueClient.playFromHere(
            session: session,
            zoneOrOutputID: zoneOrOutputID,
            queueItemID: queueItemID
        )
    }

    func browseHome(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.home(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseOpen(hierarchy: BrowseHierarchy, zoneOrOutputID: String?, itemKey: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.open(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseOpenService(title: String, zoneOrOutputID: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.openService(
            session: session,
            title: title,
            zoneOrOutputID: zoneOrOutputID
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseBack(hierarchy: BrowseHierarchy, levels: Int, zoneOrOutputID: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.back(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            levels: levels
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseRefresh(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.refresh(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseLoadPage(hierarchy: BrowseHierarchy, offset: Int, count: Int) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.loadPage(
            session: session,
            hierarchy: hierarchy,
            offset: offset,
            count: count
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseSubmitInput(hierarchy: BrowseHierarchy, itemKey: String, input: String, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let mutation = try await browseClient.submitInput(
            session: session,
            hierarchy: hierarchy,
            itemKey: itemKey,
            input: input,
            zoneOrOutputID: zoneOrOutputID
        )
        if let item = mutation.replacedItem {
            eventHandler?(.browseItemReplaced(BrowseItemReplacedEvent(
                hierarchy: mutation.hierarchy,
                item: item
            )))
        }
        if let itemKey = mutation.removedItemKey {
            eventHandler?(.browseItemRemoved(BrowseItemRemovedEvent(
                hierarchy: mutation.hierarchy,
                itemKey: itemKey
            )))
        }
        if let page = mutation.refreshedPage {
            eventHandler?(.browseListChanged(BrowseListChangedEvent(page: page)))
        }
    }

    func browseOpenSearchMatch(query: String, categoryTitle: String, matchTitle: String, zoneOrOutputID: String?) async throws -> BrowsePageSnapshot? {
        guard let session = await registryClient.activeSession() else {
            return nil
        }
        let result = try await browseClient.openSearchMatch(
            session: session,
            query: query,
            categoryTitle: categoryTitle,
            matchTitle: matchTitle,
            zoneOrOutputID: zoneOrOutputID
        )
        return BrowsePageSnapshot(page: result.page)
    }

    func browseServices() async throws -> BrowseServicesResult {
        guard let session = await registryClient.activeSession() else {
            return BrowseServicesResult(services: [])
        }
        let result = try await browseClient.browseServices(session: session)
        return BrowseServicesResult(services: result.services)
    }

    func browseSearchSections(query: String, zoneOrOutputID: String?) async throws -> SearchResultsPage {
        guard let session = await registryClient.activeSession() else {
            return SearchResultsPage(query: "", topHit: nil, sections: [])
        }
        return try await browseClient.searchSections(
            session: session,
            query: query,
            zoneOrOutputID: zoneOrOutputID
        )
    }

    func browseContextActions(hierarchy: BrowseHierarchy, itemKey: String, zoneOrOutputID: String?) async throws -> BrowseActionMenuResult {
        guard let session = await registryClient.activeSession() else {
            throw NativeSessionError.emptyResponse
        }
        let result = try await browseClient.contextActions(
            session: session,
            hierarchy: hierarchy,
            itemKey: itemKey,
            zoneOrOutputID: zoneOrOutputID
        )
        return BrowseActionMenuResult(
            sessionKey: result.sessionKey,
            title: result.title,
            actions: result.actions
        )
    }

    func browsePerformAction(
        hierarchy: BrowseHierarchy,
        sessionKey: String,
        itemKey: String,
        zoneOrOutputID: String?,
        contextItemKey: String?,
        actionTitle: String?
    ) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await browseClient.performContextAction(
            session: session,
            hierarchy: hierarchy,
            itemKey: itemKey,
            zoneOrOutputID: zoneOrOutputID,
            contextItemKey: contextItemKey,
            actionTitle: actionTitle
        )
    }

    func browsePerformSearchMatchAction(
        query: String,
        categoryTitle: String,
        matchTitle: String,
        preferredActionTitles: [String],
        zoneOrOutputID: String?
    ) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await browseClient.performSearchMatchAction(
            session: session,
            query: query,
            categoryTitle: categoryTitle,
            matchTitle: matchTitle,
            preferredActionTitles: preferredActionTitles,
            zoneOrOutputID: zoneOrOutputID
        )
    }

    func transportCommand(zoneOrOutputID: String, command: TransportCommand) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await transportClient.control(
            session: session,
            zoneOrOutputID: zoneOrOutputID,
            command: command
        )
    }

    func transportSeek(zoneOrOutputID: String, how: String, seconds: Double) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await transportClient.seek(
            session: session,
            zoneOrOutputID: zoneOrOutputID,
            how: how,
            seconds: seconds
        )
    }

    func transportChangeVolume(outputID: String, how: VolumeChangeMode, value: Double) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await transportClient.changeVolume(
            session: session,
            outputID: outputID,
            how: how,
            value: value
        )
    }

    func transportMute(outputID: String, how: OutputMuteMode) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        try await transportClient.mute(
            session: session,
            outputID: outputID,
            how: how
        )
    }

    func fetchArtwork(imageKey: String, width: Int, height: Int, format: String) async throws -> ImageFetchedResult {
        guard let currentCore else {
            throw NativeImageError.missingCoreEndpoint
        }
        return try await imageClient.fetchImage(
            imageKey: imageKey,
            width: width,
            height: height,
            format: format,
            core: currentCore
        )
    }

    private func handleRegistryError(_ error: NativeRegistryError) async throws {
        switch error {
        case let .authorizationRequired(core):
            eventHandler?(.authorizationRequired(AuthorizationRequiredEvent(core: core)))
            eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .authorizing(core))))
        case .unsupportedAutoConnect, .unsupportedResponse:
            eventHandler?(.connectionChanged(ConnectionChangedEvent(
                status: .error(message: error.localizedDescription)
            )))
            throw error
        }
    }

    private func configureRegistryFailureHandlerIfNeeded() async {
        guard hasConfiguredRegistryFailureHandler == false else {
            return
        }
        hasConfiguredRegistryFailureHandler = true
        await registryClient.setReceiveFailureHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleTransportFailure(error)
            }
        }
    }

    private struct AutomaticConnectionCandidate {
        enum Source {
            case saved(CoreEndpoint)
            case discovered(SoodDiscoveryMessage)
        }

        var mode: String
        var source: Source
    }

    private func savedAutomaticConnectionCandidate(
        persistedState: PersistedSessionState
    ) -> AutomaticConnectionCandidate? {
        guard let pairedCoreID = persistedState.pairedCoreID,
              let endpoint = persistedState.endpoints[pairedCoreID]
        else {
            return nil
        }

        return AutomaticConnectionCandidate(
            mode: "saved server",
            source: .saved(endpoint)
        )
    }

    private func discoveredAutomaticConnectionCandidates(
        persistedState: PersistedSessionState
    ) async -> [AutomaticConnectionCandidate] {
        var candidates: [AutomaticConnectionCandidate] = []
        var seen = Set<String>()

        if let pairedCoreID = persistedState.pairedCoreID,
           let endpoint = persistedState.endpoints[pairedCoreID] {
            seen.insert("\(endpoint.host):\(endpoint.port)")
        }

        let discovered = await discoveryClient.discover(timeout: 0.9)
        let ranked = discovered.sorted { lhs, rhs in
            let lhsPaired = lhs.uniqueID == persistedState.pairedCoreID
            let rhsPaired = rhs.uniqueID == persistedState.pairedCoreID
            if lhsPaired != rhsPaired {
                return lhsPaired && !rhsPaired
            }
            let lhsToken = persistedState.tokens[lhs.uniqueID] != nil
            let rhsToken = persistedState.tokens[rhs.uniqueID] != nil
            if lhsToken != rhsToken {
                return lhsToken && !rhsToken
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        for discovery in ranked {
            let identity = "\(discovery.host):\(discovery.port)"
            guard seen.contains(identity) == false else {
                continue
            }
            seen.insert(identity)
            candidates.append(AutomaticConnectionCandidate(
                mode: discovery.uniqueID == persistedState.pairedCoreID ? "paired discovery" : "discovery",
                source: .discovered(discovery)
            ))
        }

        return candidates
    }

    private func handleTransportFailure(_ error: Error) {
        guard currentCore != nil else {
            return
        }

        MacaroonDebugLogger.logError("session.transport_failed", error: error)
        MacaroonLog.transport.error("Transport failed: \(error.localizedDescription, privacy: .public)")
        currentCore = nil
        liveZonesByID = [:]
        liveQueueState = nil
        queueSubscriptionGeneration += 1
        eventHandler?(.connectionChanged(ConnectionChangedEvent(
            status: .error(message: "The connection to Roon was lost. Reconnecting…")
        )))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let lastConnectIntent else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            var delaySeconds = 1.0
            for attempt in 1...4 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard let self, Task.isCancelled == false else {
                    return
                }

                self.eventHandler?(.connectionChanged(ConnectionChangedEvent(
                    status: .connecting(mode: "reconnect \(attempt)")
                )))

                do {
                    self.reconnectTask = nil
                    switch lastConnectIntent {
                    case .automatic:
                        try await self.connectAutomatically(persistedState: self.persistedState)
                    case let .manual(host, port):
                        try await self.connectManually(host: host, port: port, persistedState: self.persistedState)
                    }
                    return
                } catch {
                    MacaroonDebugLogger.logError(
                        "session.reconnect_failed",
                        details: ["attempt": String(attempt)],
                        error: error
                    )
                }

                delaySeconds = min(delaySeconds * 2, 8)
            }
        }
    }

    private func handleZonesSubscriptionMessage(_ message: MooMessageEnvelope) async {
        do {
            guard let update = try await zoneClient.process(
                message: message,
                previousZonesByID: liveZonesByID
            ) else {
                return
            }

            liveZonesByID = update.liveZonesByID
            switch update.kind {
            case .snapshot:
                eventHandler?(.zonesSnapshot(ZonesSnapshotEvent(zones: update.zones)))
            case .changed:
                eventHandler?(.zonesChanged(ZonesChangedEvent(
                    zones: update.zones,
                    removedZoneIDs: update.removedZoneIDs
                )))
            }

            for zone in update.zones {
                eventHandler?(.nowPlayingChanged(NowPlayingChangedEvent(zoneID: zone.zoneID, nowPlaying: zone.nowPlaying)))
            }
        } catch {
            MacaroonDebugLogger.logError("zones.decode_failed", error: error)
            eventHandler?(.errorRaised(ErrorRaisedEvent(
                code: "native.zones.decode_failed",
                message: error.localizedDescription
            )))
        }
    }

}
