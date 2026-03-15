import Foundation

@MainActor
protocol RoonSessionController: AnyObject {
    var eventHandler: (@MainActor (RoonSessionEvent) -> Void)? { get set }

    func start() async throws
    func stop() async

    func connectAutomatically(persistedState: PersistedSessionState) async throws
    func connectManually(host: String, port: Int, persistedState: PersistedSessionState) async throws
    func disconnect() async

    func subscribeZones() async throws
    func subscribeQueue(zoneOrOutputID: String, maxItemCount: Int) async throws
    func queuePlayFromHere(zoneOrOutputID: String, queueItemID: String) async throws

    func browseHome(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws
    func browseOpen(hierarchy: BrowseHierarchy, zoneOrOutputID: String?, itemKey: String?) async throws
    func browseOpenService(title: String, zoneOrOutputID: String?) async throws
    func browseBack(hierarchy: BrowseHierarchy, levels: Int, zoneOrOutputID: String?) async throws
    func browseRefresh(hierarchy: BrowseHierarchy, zoneOrOutputID: String?) async throws
    func browseLoadPage(hierarchy: BrowseHierarchy, offset: Int, count: Int) async throws
    func browseSubmitInput(hierarchy: BrowseHierarchy, itemKey: String, input: String, zoneOrOutputID: String?) async throws
    func browseOpenSearchMatch(query: String, categoryTitle: String, matchTitle: String, zoneOrOutputID: String?) async throws

    func browseServices() async throws -> BrowseServicesResult
    func browseSearchSections(query: String, zoneOrOutputID: String?) async throws -> SearchResultsPage
    func browseContextActions(hierarchy: BrowseHierarchy, itemKey: String, zoneOrOutputID: String?) async throws -> BrowseActionMenuResult
    func browsePerformAction(
        hierarchy: BrowseHierarchy,
        sessionKey: String,
        itemKey: String,
        zoneOrOutputID: String?,
        contextItemKey: String?,
        actionTitle: String?
    ) async throws
    func browsePerformSearchMatchAction(
        query: String,
        categoryTitle: String,
        matchTitle: String,
        preferredActionTitles: [String],
        zoneOrOutputID: String?
    ) async throws

    func transportCommand(zoneOrOutputID: String, command: TransportCommand) async throws
    func transportSeek(zoneOrOutputID: String, how: String, seconds: Double) async throws
    func transportChangeVolume(outputID: String, how: VolumeChangeMode, value: Double) async throws
    func transportMute(outputID: String, how: OutputMuteMode) async throws

    func fetchArtwork(imageKey: String, width: Int, height: Int, format: String) async throws -> ImageFetchedResult
}

enum RoonSessionEvent: Equatable, Sendable {
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
