import Foundation

struct CoreSummary: Codable, Equatable, Sendable {
    var coreID: String
    var displayName: String
    var displayVersion: String
    var host: String?
    var port: Int?
}

struct OutputSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String { outputID }
    var outputID: String
    var zoneID: String
    var displayName: String
    var volume: OutputVolume?
}

struct OutputVolume: Codable, Equatable, Sendable {
    var type: String
    var min: Double?
    var max: Double?
    var value: Double?
    var step: Double?
    var isMuted: Bool?

    var supportsSlider: Bool {
        type != "incremental" && min != nil && max != nil && value != nil
    }

    var supportsStepAdjustments: Bool {
        type == "incremental"
    }
}

struct TransportCapabilitySet: Codable, Equatable, Sendable {
    var canPlayPause: Bool
    var canPause: Bool
    var canPlay: Bool
    var canStop: Bool
    var canNext: Bool
    var canPrevious: Bool
    var canSeek: Bool

    static let unavailable = TransportCapabilitySet(
        canPlayPause: false,
        canPause: false,
        canPlay: false,
        canStop: false,
        canNext: false,
        canPrevious: false,
        canSeek: false
    )
}

struct ImageRef: Codable, Equatable, Sendable {
    var imageKey: String
    var cacheKey: String
}

struct NowPlaying: Codable, Equatable, Sendable {
    struct Lines: Codable, Equatable, Sendable {
        var line1: String
        var line2: String?
        var line3: String?
    }

    var title: String
    var subtitle: String?
    var detail: String?
    var imageKey: String?
    var seekPosition: Double?
    var length: Double?
    var lines: Lines?
}

struct ZoneSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String { zoneID }
    var zoneID: String
    var displayName: String
    var state: String
    var outputs: [OutputSummary]
    var capabilities: TransportCapabilitySet
    var nowPlaying: NowPlaying?
}

enum BrowseHierarchy: String, CaseIterable, Codable, Identifiable, Sendable {
    case browse
    case search
    case playlists
    case albums
    case artists
    case genres
    case composers
    case internetRadio = "internet_radio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: "Browse"
        case .search: "Search"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .composers: "Composers"
        case .internetRadio: "Internet Radio"
        }
    }
}

extension BrowseHierarchy {
    static let sidebarCases: [BrowseHierarchy] = [
        .browse,
        .playlists,
        .albums,
        .artists,
        .genres,
        .composers,
        .internetRadio
    ]
}

struct BrowseList: Codable, Equatable, Sendable {
    var title: String
    var subtitle: String?
    var count: Int
    var level: Int
    var displayOffset: Int
    var hint: String?
}

struct BrowsePrompt: Codable, Equatable, Sendable {
    var prompt: String
    var action: String
    var value: String?
    var isPassword: Bool
}

struct BrowseItem: Codable, Equatable, Identifiable, Sendable {
    var id: String { itemKey ?? title }
    var title: String
    var subtitle: String?
    var imageKey: String?
    var itemKey: String?
    var hint: String?
    var inputPrompt: BrowsePrompt?
}

struct BrowsePage: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var list: BrowseList
    var items: [BrowseItem]
    var offset: Int
    var selectedZoneID: String?
}

struct ManualConnectConfiguration: Codable, Equatable, Sendable {
    var host: String
    var port: Int
}

struct CoreEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: Int
}

struct PersistedSessionState: Codable, Equatable, Sendable {
    var pairedCoreID: String?
    var tokens: [String: String]
    var endpoints: [String: CoreEndpoint]

    static let empty = PersistedSessionState(pairedCoreID: nil, tokens: [:], endpoints: [:])

    private enum CodingKeys: String, CodingKey {
        case pairedCoreID
        case tokens
        case endpoints
    }

    init(pairedCoreID: String?, tokens: [String: String], endpoints: [String: CoreEndpoint]) {
        self.pairedCoreID = pairedCoreID
        self.tokens = tokens
        self.endpoints = endpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pairedCoreID = try container.decodeIfPresent(String.self, forKey: .pairedCoreID)
        tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
        endpoints = try container.decodeIfPresent([String: CoreEndpoint].self, forKey: .endpoints) ?? [:]
    }
}

struct ErrorState: Equatable, Sendable {
    var title: String
    var message: String
}

enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting(mode: String)
    case connected(CoreSummary)
    case authorizing(CoreSummary?)
    case error(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var summary: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case let .connecting(mode):
            return "Connecting via \(mode)"
        case let .connected(core):
            return "Connected to \(core.displayName)"
        case let .authorizing(core):
            if let core {
                return "Waiting for authorization on \(core.displayName)"
            }
            return "Waiting for authorization"
        case let .error(message):
            return "Error: \(message)"
        }
    }
}
