import Foundation

enum NativeBridgeError: LocalizedError, Equatable, Sendable {
    case notImplemented(method: String)

    var errorDescription: String? {
        switch self {
        case let .notImplemented(method):
            return "The native bridge does not implement '\(method)' yet."
        }
    }
}

enum NativeBridgeRuntimeConfiguration {
    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }

        return value == "1" || value == "true" || value == "yes"
    }

    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment

        if isTruthy(environment["MACAROON_USE_NODE_BRIDGE"]) {
            return false
        }

        if let legacyValue = environment["MACAROON_EXPERIMENTAL_NATIVE_BRIDGE"] {
            return isTruthy(legacyValue)
        }

        return true
    }

    static var replayFixtureURL: URL? {
        guard let rawValue = ProcessInfo.processInfo.environment["MACAROON_NATIVE_REPLAY_FIXTURE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            rawValue.isEmpty == false
        else {
            return nil
        }

        return URL(fileURLWithPath: rawValue)
    }
}

@MainActor
final class NativeRoonBridgeService: BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)? {
        didSet {
            replayService?.eventHandler = eventHandler
        }
    }

    private var isStarted = false
    private let discoveryClient: RoonDiscoveryClient
    private let transport: RoonWebSocketTransport
    private let registryClient: NativeRegistryClient
    private let browseClient: NativeBrowseClient
    private let imageClient: NativeImageClient
    private let transportClient: NativeTransportClient
    private let queueClient: NativeQueueClient
    private let replayService: ReplayBridgeService?
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
        queueClient: NativeQueueClient = NativeQueueClient(),
        replayService: ReplayBridgeService? = nil
    ) {
        self.discoveryClient = discoveryClient
        self.transport = transport
        self.registryClient = registryClient
        self.browseClient = browseClient
        self.imageClient = imageClient
        self.transportClient = transportClient
        self.queueClient = queueClient
        if let replayService {
            self.replayService = replayService
        } else if let replayFixtureURL = NativeBridgeRuntimeConfiguration.replayFixtureURL,
           let replayService = try? ReplayBridgeService(transcriptURL: replayFixtureURL) {
            self.replayService = replayService
        } else {
            self.replayService = nil
        }
    }

    func start() async throws {
        if let replayService {
            replayService.eventHandler = eventHandler
            try await replayService.start()
            isStarted = true
            MacaroonDebugLogger.logApp("native_bridge.start", details: ["mode": "replay"])
            return
        }

        isStarted = true
        await discoveryClient.start()
        MacaroonDebugLogger.logApp("native_bridge.start", details: ["mode": "live"])
    }

    func stop() async {
        if let replayService {
            await replayService.stop()
            isStarted = false
            MacaroonDebugLogger.logApp("native_bridge.stop", details: ["mode": "replay"])
            return
        }

        await registryClient.disconnect()
        await discoveryClient.stop()
        await transport.disconnect()
        currentCore = nil
        liveZonesByID = [:]
        liveQueueState = nil
        queueSubscriptionGeneration += 1
        isStarted = false
        MacaroonDebugLogger.logApp("native_bridge.stop", details: ["mode": "live"])
    }

    func send<Params: Encodable>(_ method: String, params: Params) async throws {
        if let replayService {
            try await replayService.send(method, params: params)
            return
        }

        MacaroonDebugLogger.logApp(
            "bridge.send",
            details: ["method": method],
            message: MacaroonDebugLogger.bodySummary(try JSONEncoder().encode(params))
        )

        switch method {
        case "connect.auto":
            guard let params = params as? ConnectAutoParams else {
                throw NativeBridgeError.notImplemented(method: method)
            }
            try await connectAutomatically(params)
        case "connect.manual":
            guard let params = params as? ConnectManualParams else {
                throw NativeBridgeError.notImplemented(method: method)
            }
            try await connectManually(params)
        case "core.disconnect":
            await registryClient.disconnect()
            currentCore = nil
            liveZonesByID = [:]
            liveQueueState = nil
            queueSubscriptionGeneration += 1
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .disconnected))))
        case "zones.subscribe":
            try await subscribeToZones()
        case "queue.subscribe":
            guard let params = params as? QueueSubscribeParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            queueSubscriptionGeneration += 1
            liveQueueState = nil
            let generation = queueSubscriptionGeneration
            let zoneOrOutputID = params.zoneOrOutputID
            try await queueClient.subscribe(
                session: session,
                zoneOrOutputID: zoneOrOutputID,
                maxItemCount: params.maxItemCount,
                subscriptionKey: generation,
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
                            self.eventHandler?(.event(.queueSnapshot(QueueSnapshotEvent(queue: update.queue))))
                        case .changed:
                            self.liveQueueState = update.queue
                            self.eventHandler?(.event(.queueChanged(QueueChangedEvent(queue: update.queue))))
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
                        self.eventHandler?(.event(.errorRaised(ErrorRaisedEvent(
                            code: "queue.error",
                            message: error.localizedDescription
                        ))))
                    }
                }
            }
        case "browse.home", "browse.open", "browse.back", "browse.refresh",
             "browse.loadPage", "browse.submitInput", "browse.openService",
             "browse.openSearchMatch":
            try await handleBrowseSend(method: method, params: params)
            return
        case "browse.performAction":
            guard let params = params as? BrowsePerformActionParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await browseClient.performContextAction(
                session: session,
                hierarchy: params.hierarchy,
                itemKey: params.itemKey,
                zoneOrOutputID: params.zoneOrOutputID,
                contextItemKey: params.contextItemKey,
                actionTitle: params.actionTitle
            )
        case "queue.playFromHere":
            guard let params = params as? QueuePlayFromHereParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await queueClient.playFromHere(
                session: session,
                zoneOrOutputID: params.zoneOrOutputID,
                queueItemID: params.queueItemID
            )
        case "transport.command":
            guard let params = params as? TransportCommandParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await transportClient.control(
                session: session,
                zoneOrOutputID: params.zoneOrOutputID,
                command: params.command
            )
        case "transport.seek":
            guard let params = params as? TransportSeekParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await transportClient.seek(
                session: session,
                zoneOrOutputID: params.zoneOrOutputID,
                how: params.how,
                seconds: params.seconds
            )
        case "transport.changeVolume":
            guard let params = params as? TransportVolumeParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await transportClient.changeVolume(
                session: session,
                outputID: params.outputID,
                how: params.how,
                value: params.value
            )
        case "transport.mute":
            guard let params = params as? TransportMuteParams,
                  let session = await registryClient.activeSession() else {
                return
            }
            try await transportClient.mute(
                session: session,
                outputID: params.outputID,
                how: params.how
            )
        default:
            throw NativeBridgeError.notImplemented(method: method)
        }
    }

    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        if let replayService {
            return try await replayService.request(method, params: params, as: resultType)
        }

        MacaroonDebugLogger.logApp(
            "bridge.request",
            details: ["method": method],
            message: MacaroonDebugLogger.bodySummary(try JSONEncoder().encode(params))
        )

        switch method {
        case "browse.services":
            guard let session = await registryClient.activeSession() else {
                return BrowseServicesResult(services: []) as! Result
            }
            let result = try await browseClient.browseServices(session: session)
            let bridged = BrowseServicesResult(services: result.services)
            return bridged as! Result
        case "browse.contextActions":
            guard let params = params as? BrowseContextActionsParams,
                  let session = await registryClient.activeSession() else {
                throw BridgeRuntimeError.processUnavailable
            }
            let result = try await browseClient.contextActions(
                session: session,
                hierarchy: params.hierarchy,
                itemKey: params.itemKey,
                zoneOrOutputID: params.zoneOrOutputID
            )
            return BrowseActionMenuResult(
                sessionKey: result.sessionKey,
                title: result.title,
                actions: result.actions
            ) as! Result
        case "image.fetch":
            guard let params = params as? ImageFetchParams,
                  let currentCore else {
                throw NativeImageError.missingCoreEndpoint
            }
            let result = try await imageClient.fetchImage(
                imageKey: params.imageKey,
                width: params.width,
                height: params.height,
                format: params.format,
                core: currentCore
            )
            return result as! Result
        default:
            throw NativeBridgeError.notImplemented(method: method)
        }
    }

    private func handleBrowseSend<Params: Encodable>(method: String, params: Params) async throws {
        guard method.hasPrefix("browse.") else {
            return
        }
        guard let session = await registryClient.activeSession() else {
            return
        }

        switch method {
        case "browse.home":
            guard let params = params as? BrowseHomeParams else { return }
            let result = try await browseClient.home(
                session: session,
                hierarchy: params.hierarchy,
                zoneOrOutputID: params.zoneOrOutputID
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.open":
            guard let params = params as? BrowseOpenParams else { return }
            let result = try await browseClient.open(
                session: session,
                hierarchy: params.hierarchy,
                zoneOrOutputID: params.zoneOrOutputID,
                itemKey: params.itemKey
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.openService":
            guard let params = params as? BrowseOpenServiceParams else { return }
            let result = try await browseClient.openService(
                session: session,
                title: params.title,
                zoneOrOutputID: params.zoneOrOutputID
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.back":
            guard let params = params as? BrowseBackParams else { return }
            let result = try await browseClient.back(
                session: session,
                hierarchy: params.hierarchy,
                zoneOrOutputID: params.zoneOrOutputID,
                levels: params.levels
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.refresh":
            guard let params = params as? BrowseRefreshParams else { return }
            let result = try await browseClient.refresh(
                session: session,
                hierarchy: params.hierarchy,
                zoneOrOutputID: params.zoneOrOutputID
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.loadPage":
            guard let params = params as? BrowseLoadPageParams else { return }
            let result = try await browseClient.loadPage(
                session: session,
                hierarchy: params.hierarchy,
                offset: params.offset,
                count: params.count
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        case "browse.submitInput":
            guard let params = params as? BrowseSubmitInputParams else { return }
            let mutation = try await browseClient.submitInput(
                session: session,
                hierarchy: params.hierarchy,
                itemKey: params.itemKey,
                input: params.input,
                zoneOrOutputID: params.zoneOrOutputID
            )
            if let item = mutation.replacedItem {
                eventHandler?(.event(.browseItemReplaced(BrowseItemReplacedEvent(
                    hierarchy: mutation.hierarchy,
                    item: item
                ))))
            }
            if let itemKey = mutation.removedItemKey {
                eventHandler?(.event(.browseItemRemoved(BrowseItemRemovedEvent(
                    hierarchy: mutation.hierarchy,
                    itemKey: itemKey
                ))))
            }
            if let page = mutation.refreshedPage {
                eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: page))))
            }
        case "browse.openSearchMatch":
            guard let params = params as? BrowseOpenSearchMatchParams else { return }
            let result = try await browseClient.openSearchMatch(
                session: session,
                query: params.query,
                categoryTitle: params.categoryTitle,
                matchTitle: params.matchTitle,
                zoneOrOutputID: params.zoneOrOutputID
            )
            eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: result.page))))
        default:
            return
        }
    }

    private func connectAutomatically(_ params: ConnectAutoParams) async throws {
        persistedState = params.persistedState

        guard let pairedCoreID = params.persistedState.pairedCoreID,
              let endpoint = params.persistedState.endpoints[pairedCoreID]
        else {
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(
                status: .error(message: "Native bridge discovery is not implemented yet.")
            ))))
            return
        }

        eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(
            status: .connecting(mode: "saved server")
        ))))

        do {
            let result = try await registryClient.connectSavedEndpoint(endpoint: endpoint, persistedState: params.persistedState)
            persistedState = result.persistedState
            currentCore = result.core
            MacaroonDebugLogger.logApp(
                "bridge.connected",
                details: [
                    "mode": "saved server",
                    "core_id": result.core.coreID,
                    "display_name": result.core.displayName
                ]
            )
            eventHandler?(.event(.persistRequested(PersistRequestedEvent(persistedState: result.persistedState))))
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .connected(result.core)))))
        } catch let error as NativeRegistryError {
            MacaroonDebugLogger.logError("bridge.auto_connect_failed", error: error)
            try await handleRegistryError(error)
        }
    }

    private func connectManually(_ params: ConnectManualParams) async throws {
        persistedState = params.persistedState
        let core = CoreSummary(
            coreID: "",
            displayName: "\(params.host):\(params.port)",
            displayVersion: "",
            host: params.host,
            port: params.port
        )

        eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(
            status: .connecting(mode: "manual")
        ))))

        do {
            let result = try await registryClient.connectManual(
                host: params.host,
                port: params.port,
                persistedState: params.persistedState
            )
            persistedState = result.persistedState
            currentCore = result.core
            MacaroonDebugLogger.logApp(
                "bridge.connected",
                details: [
                    "mode": "manual",
                    "core_id": result.core.coreID,
                    "display_name": result.core.displayName
                ]
            )
            eventHandler?(.event(.persistRequested(PersistRequestedEvent(persistedState: result.persistedState))))
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .connected(result.core)))))
        } catch let error as NativeRegistryError {
            MacaroonDebugLogger.logError("bridge.manual_connect_failed", error: error)
            if case .authorizationRequired = error {
                eventHandler?(.event(.authorizationRequired(AuthorizationRequiredEvent(core: core))))
                eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .authorizing(core)))))
                return
            }
            try await handleRegistryError(error)
        }
    }

    private func handleRegistryError(_ error: NativeRegistryError) async throws {
        switch error {
        case let .authorizationRequired(core):
            eventHandler?(.event(.authorizationRequired(AuthorizationRequiredEvent(core: core))))
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .authorizing(core)))))
        case .unsupportedAutoConnect, .unsupportedResponse:
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(
                status: .error(message: error.localizedDescription)
            ))))
            throw error
        }
    }

    private func subscribeToZones() async throws {
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

    private func handleZonesSubscriptionMessage(_ message: MooMessageEnvelope) {
        do {
            switch message.name {
            case "Subscribed":
                let payload = try decodeBody(NativeZonesSubscribedPayload.self, from: message)
                let zones = Self.deduplicateZones(payload.zones.map(Self.toZoneSummary))
                liveZonesByID = Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
                eventHandler?(.event(.zonesSnapshot(ZonesSnapshotEvent(zones: zones))))
                for zone in zones {
                    eventHandler?(.event(.nowPlayingChanged(NowPlayingChangedEvent(zoneID: zone.zoneID, nowPlaying: zone.nowPlaying))))
                }
            case "Changed":
                let payload = try decodeBody(NativeZonesChangedPayload.self, from: message)
                for removedID in payload.zones_removed ?? [] {
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

                if emitted.isEmpty == false {
                    let deduped = Self.deduplicateZones(emitted)
                    eventHandler?(.event(.zonesChanged(ZonesChangedEvent(zones: deduped))))
                    for zone in deduped {
                        eventHandler?(.event(.nowPlayingChanged(NowPlayingChangedEvent(zoneID: zone.zoneID, nowPlaying: zone.nowPlaying))))
                    }
                }
            default:
                return
            }
        } catch {
            MacaroonDebugLogger.logError("zones.decode_failed", error: error)
            eventHandler?(.event(.errorRaised(ErrorRaisedEvent(
                code: "native.zones.decode_failed",
                message: error.localizedDescription
            ))))
        }
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, from message: MooMessageEnvelope) throws -> T {
        guard let body = message.body else {
            throw BridgeRuntimeError.emptyResponse
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
