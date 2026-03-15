import Foundation

@MainActor
protocol BridgeService: AnyObject {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)? { get set }
    func start() async throws
    func stop() async
    func send<Params: Encodable>(_ method: String, params: Params) async throws
    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result
}

enum BridgeInboundMessage: Equatable, Sendable {
    case response(id: UUID, result: Data?, error: BridgeErrorPayload?)
    case event(BridgeEventEnvelope)
}

enum BridgeEventEnvelope: Equatable, Sendable {
    case connectionChanged(ConnectionChangedEvent)
    case authorizationRequired(AuthorizationRequiredEvent)
    case zonesSnapshot(ZonesSnapshotEvent)
    case zonesChanged(ZonesChangedEvent)
    case queueSnapshot(QueueSnapshotEvent)
    case queueChanged(QueueChangedEvent)
    case browseListChanged(BrowseListChangedEvent)
    case browseItemReplaced(BrowseItemReplacedEvent)
    case browseItemRemoved(BrowseItemRemovedEvent)
    case nowPlayingChanged(NowPlayingChangedEvent)
    case persistRequested(PersistRequestedEvent)
    case errorRaised(ErrorRaisedEvent)
}

@MainActor
final class HelperProcessController: NSObject, BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let scriptPath: URL
    private let environment: [String: String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingRequests: [UUID: CheckedContinuation<Data?, Error>] = [:]
    private let fixtureRecorder: FixtureCaptureRecorder?

    init(launchPath: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.scriptPath = launchPath
        self.fixtureRecorder = FixtureCaptureRecorder(baseDirectoryURL: FixtureCaptureConfiguration.captureDirectoryURL)
        self.environment = environment.merging(FixtureCaptureConfiguration.helperEnvironment) { current, _ in current }
        super.init()
        encoder.outputFormatting = [.sortedKeys]
    }

    func start() async throws {
        if process != nil {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath.path]
        process.environment = environment

        try fixtureRecorder?.prepareIfNeeded()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.handleProcessTermination()
            }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                self?.handleOutputChunk(chunk)
            }
        }
    }

    func stop() async {
        terminateSynchronously()
    }

    func terminateSynchronously() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        handleProcessTermination()
    }

    func send<Params: Encodable>(_ method: String, params: Params) async throws {
        _ = try await request(method, params: params, as: EmptyResult.self)
    }

    func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        guard let stdinPipe else {
            throw BridgeRuntimeError.processUnavailable
        }

        let request = BridgeRequest(id: UUID(), method: method, params: params)
        let payload = try encoder.encode(request)
        guard let newline = "\n".data(using: .utf8) else {
            throw BridgeRuntimeError.invalidUTF8
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            pendingRequests[request.id] = continuation
            fixtureRecorder?.recordOutbound(payload)
            stdinPipe.fileHandleForWriting.write(payload)
            stdinPipe.fileHandleForWriting.write(newline)
        }

        if Result.self == EmptyResult.self, response == nil {
            return EmptyResult() as! Result
        }

        guard let response else {
            throw BridgeRuntimeError.emptyResponse
        }
        return try decoder.decode(Result.self, from: response)
    }

    private func handleOutputChunk(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        outputBuffer.append(chunk)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newlineIndex)
            outputBuffer.removeSubrange(...newlineIndex)
            if line.isEmpty {
                continue
            }
            fixtureRecorder?.recordInboundLine(Data(line))

            do {
                if let inbound = try BridgeMessageDecoder.decodeInboundMessage(Data(line), decoder: decoder) {
                    switch inbound {
                    case let .response(id, result, error):
                        if let continuation = pendingRequests.removeValue(forKey: id) {
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: result)
                            }
                        }
                    case .event:
                        eventHandler?(inbound)
                    }
                }
            } catch {
                eventHandler?(.event(.errorRaised(ErrorRaisedEvent(
                    code: "bridge.decode_failed",
                    message: error.localizedDescription
                ))))
            }
        }
    }

    private func handleProcessTermination() {
        guard process != nil || stdinPipe != nil || stdoutPipe != nil || pendingRequests.isEmpty == false else {
            return
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)

        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        continuations.forEach { $0.resume(throwing: BridgeRuntimeError.processUnavailable) }

        eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .disconnected))))
    }

}

enum BridgeRuntimeError: LocalizedError {
    case processUnavailable
    case invalidUTF8
    case emptyResponse
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .processUnavailable:
            "The helper process is not running."
        case .invalidUTF8:
            "Unable to encode a bridge message."
        case .emptyResponse:
            "The helper returned an empty response."
        case .unsupportedAction:
            "No supported action was available for this item."
        }
    }
}

@MainActor
final class MockBridgeService: BridgeService {
    var eventHandler: (@MainActor (BridgeInboundMessage) -> Void)?

    func start() async throws {
        let eventHandler = self.eventHandler
        await MainActor.run {
            eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .disconnected))))
        }
    }

    func stop() async {}

    func send<Params>(_ method: String, params: Params) async throws where Params: Encodable {
        _ = try await request(method, params: params, as: EmptyResult.self)
    }

    func request<Params, Result>(
        _ method: String,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result where Params: Encodable, Result: Decodable {
        let eventHandler = self.eventHandler
        switch method {
        case "connect.auto":
            let core = CoreSummary(coreID: "mock-core", displayName: "Mock Core", displayVersion: "1.0", host: "127.0.0.1", port: 9100)
            let zones = [
                ZoneSummary(
                    zoneID: "zone-1",
                    displayName: "Living Room",
                    state: "stopped",
                    outputs: [OutputSummary(
                        outputID: "output-1",
                        zoneID: "zone-1",
                        displayName: "Living Room Output",
                        volume: OutputVolume(type: "number", min: 0, max: 100, value: 42, step: 1, isMuted: false)
                    )],
                    capabilities: .init(canPlayPause: true, canPause: true, canPlay: true, canStop: true, canNext: true, canPrevious: true, canSeek: false),
                    nowPlaying: nil
                )
            ]
            let page = BrowsePage(
                hierarchy: .browse,
                list: BrowseList(title: "Library", subtitle: "Mock content", count: 3, level: 0, displayOffset: 0, hint: nil),
                items: [
                    BrowseItem(title: "Albums", subtitle: "245 albums", imageKey: nil, itemKey: "albums", hint: "list", inputPrompt: nil),
                    BrowseItem(title: "Artists", subtitle: "89 artists", imageKey: nil, itemKey: "artists", hint: "list", inputPrompt: nil),
                    BrowseItem(title: "Search", subtitle: nil, imageKey: nil, itemKey: "search", hint: "action", inputPrompt: .init(prompt: "Search Library", action: "Go", value: nil, isPassword: false))
                ],
                offset: 0,
                selectedZoneID: "zone-1"
            )
            await MainActor.run {
                eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .connecting(mode: "mock")))))
                eventHandler?(.event(.connectionChanged(ConnectionChangedEvent(status: .connected(core)))))
                eventHandler?(.event(.zonesSnapshot(ZonesSnapshotEvent(zones: zones))))
                eventHandler?(.event(.queueSnapshot(QueueSnapshotEvent(queue: QueueState(
                    zoneID: "zone-1",
                    title: "Up Next",
                    totalCount: 3,
                    currentQueueItemID: "queue-1",
                    items: [
                        QueueItemSummary(queueItemID: "queue-1", title: "So What", subtitle: "Miles Davis", detail: "Kind of Blue", imageKey: nil, length: 544, isCurrent: true),
                        QueueItemSummary(queueItemID: "queue-2", title: "Freddie Freeloader", subtitle: "Miles Davis", detail: "Kind of Blue", imageKey: nil, length: 589, isCurrent: false),
                        QueueItemSummary(queueItemID: "queue-3", title: "Blue in Green", subtitle: "Miles Davis", detail: "Kind of Blue", imageKey: nil, length: 327, isCurrent: false)
                    ]
                )))))
                eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: page))))
            }
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "browse.open":
            let page = BrowsePage(
                hierarchy: .browse,
                list: BrowseList(title: "Albums", subtitle: "Mock results", count: 2, level: 1, displayOffset: 0, hint: nil),
                items: [
                    BrowseItem(title: "Kind of Blue", subtitle: "Miles Davis", imageKey: nil, itemKey: "album-kind-of-blue", hint: "action", inputPrompt: nil),
                    BrowseItem(title: "Blue Train", subtitle: "John Coltrane", imageKey: nil, itemKey: "album-blue-train", hint: "action", inputPrompt: nil)
                ],
                offset: 0,
                selectedZoneID: "zone-1"
            )
            await MainActor.run {
                eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: page))))
            }
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "browse.services":
            let result = BrowseServicesResult(services: [
                BrowseServiceSummary(title: "Qobuz"),
                BrowseServiceSummary(title: "TIDAL")
            ])
            if let typed = result as? Result {
                return typed
            }
        case "browse.openService":
            let page = BrowsePage(
                hierarchy: .browse,
                list: BrowseList(title: "TIDAL", subtitle: "Mock service", count: 2, level: 1, displayOffset: 0, hint: nil),
                items: [
                    BrowseItem(title: "New Arrivals", subtitle: nil, imageKey: nil, itemKey: "tidal-new", hint: "list", inputPrompt: nil),
                    BrowseItem(title: "Favorites", subtitle: nil, imageKey: nil, itemKey: "tidal-favorites", hint: "list", inputPrompt: nil)
                ],
                offset: 0,
                selectedZoneID: "zone-1"
            )
            await MainActor.run {
                eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: page))))
            }
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "browse.openSearchMatch":
            let page = BrowsePage(
                hierarchy: .search,
                list: BrowseList(title: "Artist", subtitle: "Mock artist page", count: 1, level: 2, displayOffset: 0, hint: nil),
                items: [
                    BrowseItem(title: "Albums", subtitle: "4 albums", imageKey: nil, itemKey: "artist-albums", hint: "list", inputPrompt: nil)
                ],
                offset: 0,
                selectedZoneID: "zone-1"
            )
            await MainActor.run {
                eventHandler?(.event(.browseListChanged(BrowseListChangedEvent(page: page))))
            }
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "browse.searchSections":
            let result = SearchResultsPage(
                query: "mock",
                topHit: BrowseItem(title: "Mock Artist", subtitle: "Top Result", imageKey: nil, itemKey: "mock-top-hit", hint: "list", inputPrompt: nil),
                sections: [
                    SearchResultsSection(
                        kind: .artists,
                        items: [
                            BrowseItem(title: "Mock Artist", subtitle: "2 albums", imageKey: nil, itemKey: "mock-artist", hint: "list", inputPrompt: nil)
                        ]
                    ),
                    SearchResultsSection(
                        kind: .tracks,
                        items: [
                            BrowseItem(title: "Mock Song", subtitle: "Mock Artist", imageKey: nil, itemKey: "mock-track", hint: "action", inputPrompt: nil, detail: nil, length: 244)
                        ]
                    )
                ]
            )
            if let typed = result as? Result {
                return typed
            }
        case "image.fetch":
            let result = ImageFetchedResult(imageKey: "mock-image", localURL: "/tmp/mock-image.jpg")
            if let typed = result as? Result {
                return typed
            }
        case "browse.contextActions":
            let result = BrowseActionMenuResult(
                sessionKey: "mock-session",
                title: "Play",
                actions: [
                    BrowseItem(title: "Play Now", subtitle: nil, imageKey: nil, itemKey: "play-now", hint: "action", inputPrompt: nil),
                    BrowseItem(title: "Add Next", subtitle: nil, imageKey: nil, itemKey: "add-next", hint: "action", inputPrompt: nil)
                ]
            )
            if let typed = result as? Result {
                return typed
            }
        case "browse.performAction":
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "browse.performSearchMatchAction":
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "queue.playFromHere":
            if let typed = EmptyResult() as? Result {
                return typed
            }
        case "transport.seek", "transport.changeVolume", "transport.mute":
            if let typed = EmptyResult() as? Result {
                return typed
            }
        default:
            break
        }

        if let typed = EmptyResult() as? Result {
            return typed
        }
        throw BridgeRuntimeError.emptyResponse
    }
}
