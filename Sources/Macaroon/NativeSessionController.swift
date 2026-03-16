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
    private let discoveryClient: RoonDiscoveryClient
    private let transport: RoonWebSocketTransport
    private let registryClient: NativeRegistryClient
    private let browseClient: NativeBrowseClient
    private let imageClient: NativeImageClient
    private let transportClient: NativeTransportClient
    private let queueClient: NativeQueueClient
    private var currentCore: CoreSummary?
    private var persistedState = PersistedSessionState.empty
    private var liveZonesByID: [String: ZoneSummary] = [:]
    private var liveQueueState: QueueState?
    private var queueSubscriptionGeneration = 0

    init(
        discoveryClient: RoonDiscoveryClient = RoonDiscoveryClient(),
        transport: RoonWebSocketTransport = RoonWebSocketTransport(),
        registryClient: NativeRegistryClient = NativeRegistryClient(),
        browseClient: NativeBrowseClient = NativeBrowseClient(),
        imageClient: NativeImageClient = NativeImageClient(),
        transportClient: NativeTransportClient = NativeTransportClient(),
        queueClient: NativeQueueClient = NativeQueueClient()
    ) {
        self.discoveryClient = discoveryClient
        self.transport = transport
        self.registryClient = registryClient
        self.browseClient = browseClient
        self.imageClient = imageClient
        self.transportClient = transportClient
        self.queueClient = queueClient
    }

    func start() async throws {
        guard isStarted == false else {
            return
        }
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
        isStarted = false
        MacaroonDebugLogger.logApp("native_session.stop")
    }

    func connectAutomatically(persistedState: PersistedSessionState) async throws {
        self.persistedState = persistedState

        guard let pairedCoreID = persistedState.pairedCoreID,
              let endpoint = persistedState.endpoints[pairedCoreID]
        else {
            eventHandler?(.connectionChanged(ConnectionChangedEvent(
                status: .error(message: "Automatic discovery fallback is not implemented yet.")
            )))
            return
        }

        eventHandler?(.connectionChanged(ConnectionChangedEvent(
            status: .connecting(mode: "saved server")
        )))

        do {
            let result = try await registryClient.connectSavedEndpoint(endpoint: endpoint, persistedState: persistedState)
            self.persistedState = result.persistedState
            currentCore = result.core
            MacaroonDebugLogger.logApp(
                "session.connected",
                details: [
                    "mode": "saved server",
                    "core_id": result.core.coreID,
                    "display_name": result.core.displayName
                ]
            )
            eventHandler?(.persistRequested(PersistRequestedEvent(persistedState: result.persistedState)))
            eventHandler?(.connectionChanged(ConnectionChangedEvent(status: .connected(result.core))))
        } catch let error as NativeRegistryError {
            MacaroonDebugLogger.logError("session.auto_connect_failed", error: error)
            try await handleRegistryError(error)
        }
    }

    func connectManually(host: String, port: Int, persistedState: PersistedSessionState) async throws {
        self.persistedState = persistedState
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

        try await session.subscribe(
            "com.roonlabs.transport:2/subscribe_zones",
            body: NativeSubscriptionKeyRequest(subscription_key: 0)
        ) { [weak self] message in
            Task { @MainActor in
                self?.handleZonesSubscriptionMessage(message)
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

    func browseHome(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.home(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
    }

    func browseOpen(hierarchy: BrowseHierarchy, zoneOrOutputID: String?, itemKey: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.open(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
    }

    func browseOpenService(title: String, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.openService(
            session: session,
            title: title,
            zoneOrOutputID: zoneOrOutputID
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
    }

    func browseBack(hierarchy: BrowseHierarchy, levels: Int, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.back(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            levels: levels
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
    }

    func browseRefresh(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.refresh(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
    }

    func browseLoadPage(hierarchy: BrowseHierarchy, offset: Int, count: Int) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.loadPage(
            session: session,
            hierarchy: hierarchy,
            offset: offset,
            count: count
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
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

    func browseOpenSearchMatch(query: String, categoryTitle: String, matchTitle: String, zoneOrOutputID: String?) async throws {
        guard let session = await registryClient.activeSession() else {
            return
        }
        let result = try await browseClient.openSearchMatch(
            session: session,
            query: query,
            categoryTitle: categoryTitle,
            matchTitle: matchTitle,
            zoneOrOutputID: zoneOrOutputID
        )
        eventHandler?(.browseListChanged(BrowseListChangedEvent(page: result.page)))
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

    private func handleZonesSubscriptionMessage(_ message: MooMessageEnvelope) {
        do {
            switch message.name {
            case "Subscribed":
                let payload = try decodeBody(NativeZonesSubscribedPayload.self, from: message)
                let zones = Self.deduplicateZones(payload.zones.map(Self.toZoneSummary))
                liveZonesByID = Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
                eventHandler?(.zonesSnapshot(ZonesSnapshotEvent(zones: zones)))
                for zone in zones {
                    eventHandler?(.nowPlayingChanged(NowPlayingChangedEvent(zoneID: zone.zoneID, nowPlaying: zone.nowPlaying)))
                }
            case "Changed":
                let payload = try decodeBody(NativeZonesChangedPayload.self, from: message)
                let removedZoneIDs = payload.zones_removed ?? []
                for removedID in removedZoneIDs {
                    liveZonesByID.removeValue(forKey: removedID)
                }

                let changedZones = (payload.zones_added ?? []) + (payload.zones_changed ?? [])
                var emitted: [ZoneSummary] = changedZones.map(Self.toZoneSummary)

                for zone in emitted {
                    liveZonesByID[zone.zoneID] = zone
                }

                if let seekChanges = payload.zones_seek_changed {
                    for seekChange in seekChanges {
                        guard var zone = liveZonesByID[seekChange.zone_id] else {
                            continue
                        }
                        if var nowPlaying = zone.nowPlaying {
                            nowPlaying.seekPosition = seekChange.seek_position
                            zone.nowPlaying = nowPlaying
                            liveZonesByID[zone.zoneID] = zone
                            emitted.append(zone)
                        }
                    }
                }

                if emitted.isEmpty == false || removedZoneIDs.isEmpty == false {
                    let deduped = Self.deduplicateZones(emitted)
                    eventHandler?(.zonesChanged(ZonesChangedEvent(
                        zones: deduped,
                        removedZoneIDs: removedZoneIDs
                    )))
                    for zone in deduped {
                        eventHandler?(.nowPlayingChanged(NowPlayingChangedEvent(zoneID: zone.zoneID, nowPlaying: zone.nowPlaying)))
                    }
                }
            default:
                return
            }
        } catch {
            MacaroonDebugLogger.logError("zones.decode_failed", error: error)
            eventHandler?(.errorRaised(ErrorRaisedEvent(
                code: "native.zones.decode_failed",
                message: error.localizedDescription
            )))
        }
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, from message: MooMessageEnvelope) throws -> T {
        guard let body = message.body else {
            throw NativeSessionError.emptyResponse
        }
        return try JSONDecoder().decode(T.self, from: body)
    }

    private static func toZoneSummary(_ zone: NativeTransportZone) -> ZoneSummary {
        ZoneSummary(
            zoneID: zone.zone_id,
            displayName: zone.display_name,
            state: zone.state,
            outputs: (zone.outputs ?? []).map { output in
                OutputSummary(
                    outputID: output.output_id,
                    zoneID: output.zone_id,
                    displayName: output.display_name,
                    volume: output.volume.map {
                        OutputVolume(
                            type: $0.type ?? "number",
                            min: $0.min,
                            max: $0.max,
                            value: $0.value,
                            step: $0.step,
                            isMuted: $0.is_muted
                        )
                    }
                )
            },
            capabilities: TransportCapabilitySet(
                canPlayPause: zone.is_play_allowed || zone.is_pause_allowed,
                canPause: zone.is_pause_allowed,
                canPlay: zone.is_play_allowed,
                canStop: zone.is_pause_allowed || zone.state != "stopped",
                canNext: zone.is_next_allowed,
                canPrevious: zone.is_previous_allowed,
                canSeek: zone.is_seek_allowed
            ),
            nowPlaying: zone.now_playing.map { nowPlaying in
                let lines = nowPlaying.three_line ?? nowPlaying.two_line ?? nowPlaying.one_line
                return NowPlaying(
                    title: lines?.line1 ?? "Unknown",
                    subtitle: nowPlaying.three_line?.line2 ?? nowPlaying.two_line?.line2,
                    detail: nowPlaying.three_line?.line3,
                    imageKey: nowPlaying.image_key,
                    seekPosition: nowPlaying.seek_position,
                    length: nowPlaying.length,
                    lines: nowPlaying.three_line.map {
                        NowPlaying.Lines(line1: $0.line1, line2: $0.line2, line3: $0.line3)
                    }
                )
            }
        )
    }

    private static func deduplicateZones(_ zones: [ZoneSummary]) -> [ZoneSummary] {
        var byID: [String: ZoneSummary] = [:]
        for zone in zones {
            byID[zone.zoneID] = zone
        }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

private struct NativeSubscriptionKeyRequest: Codable {
    var subscription_key: Int
}

private struct NativeZonesSubscribedPayload: Codable {
    var zones: [NativeTransportZone]
}

private struct NativeZonesChangedPayload: Codable {
    var zones_added: [NativeTransportZone]?
    var zones_changed: [NativeTransportZone]?
    var zones_removed: [String]?
    var zones_seek_changed: [NativeZoneSeekChange]?
}

private struct NativeZoneSeekChange: Codable {
    var zone_id: String
    var seek_position: Double?
}

private struct NativeTransportZone: Codable {
    var zone_id: String
    var display_name: String
    var state: String
    var outputs: [NativeTransportOutput]?
    var is_previous_allowed: Bool
    var is_next_allowed: Bool
    var is_pause_allowed: Bool
    var is_play_allowed: Bool
    var is_seek_allowed: Bool
    var now_playing: NativeTransportNowPlaying?
}

private struct NativeTransportOutput: Codable {
    var output_id: String
    var zone_id: String
    var display_name: String
    var volume: NativeTransportVolume?
}

private struct NativeTransportVolume: Codable {
    var type: String?
    var min: Double?
    var max: Double?
    var value: Double?
    var step: Double?
    var is_muted: Bool?
}

private struct NativeTransportNowPlaying: Codable {
    var seek_position: Double?
    var length: Double?
    var image_key: String?
    var one_line: NativeTransportLineBlock?
    var two_line: NativeTransportLineBlock?
    var three_line: NativeTransportLineBlock?
}

private struct NativeTransportLineBlock: Codable {
    var line1: String
    var line2: String?
    var line3: String?
}
