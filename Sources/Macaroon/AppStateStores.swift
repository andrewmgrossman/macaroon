import Foundation
import SwiftUI

@MainActor
@Observable
final class ConnectionPlaybackStateStore {
    var connectionStatus: ConnectionStatus = .disconnected
    var currentCore: CoreSummary?
    var manualConnect = ManualConnectConfiguration(host: "127.0.0.1", port: 9100)
    var zones: [ZoneSummary] = []
    var selectedZoneID: String?
    var sessionStatusText = "Idle"
    var autoConnectionIssue: String?
}

@MainActor
@Observable
final class BrowsePresentationStateStore {
    var selectedHierarchy: BrowseHierarchy = .artists
    var browsePage: BrowsePage?
    var browseItemsByIndex: [Int: BrowseItem] = [:]
    var browseServices: [BrowseServiceSummary] = []
    var selectedBrowseServiceTitle: String?
    var searchText = ""
    var searchResultsPage: SearchResultsPage?
    var searchFocusRequestID = 0
    var typeSelectQueryDisplay: String?
    var browseScrollTargetIndex: Int?
    var browseScrollTargetRequestID = 0
    var browsePageGeneration = 0

    @ObservationIgnored
    var activeBrowseLoadOffsets: Set<Int> = []
    @ObservationIgnored
    var loadedBrowseLoadOffsets: Set<Int> = []
}

@MainActor
@Observable
final class QueuePresentationStateStore {
    var queueState: QueueState?
    var isQueueSidebarVisible = false
}

@MainActor
@Observable
final class ArtworkPresentationStateStore {
    var artworkCacheUsageBytes = 0
    var artworkCacheLimitBytes = ArtworkCacheSettings.defaultBytes
}
