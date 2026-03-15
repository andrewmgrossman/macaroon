import Foundation

struct EmptyParams: Codable, Equatable, Sendable {}

enum TransportCommand: String, Codable, Equatable, Sendable {
    case playPause = "playpause"
    case play
    case pause
    case stop
    case next
    case previous
}

enum VolumeChangeMode: String, Codable, Equatable, Sendable {
    case absolute
    case relative
    case relativeStep = "relative_step"
}

enum OutputMuteMode: String, Codable, Equatable, Sendable {
    case mute
    case unmute
}

struct ConnectionChangedEvent: Codable, Equatable, Sendable {
    var status: ConnectionStatusPayload
}

enum ConnectionStatusPayload: Codable, Equatable, Sendable {
    case disconnected
    case connecting(mode: String)
    case connected(CoreSummary)
    case authorizing(CoreSummary?)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case mode
        case core
        case message
    }

    private enum State: String, Codable {
        case disconnected
        case connecting
        case connected
        case authorizing
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting(mode: try container.decode(String.self, forKey: .mode))
        case .connected:
            self = .connected(try container.decode(CoreSummary.self, forKey: .core))
        case .authorizing:
            self = .authorizing(try container.decodeIfPresent(CoreSummary.self, forKey: .core))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disconnected:
            try container.encode(State.disconnected, forKey: .state)
        case let .connecting(mode):
            try container.encode(State.connecting, forKey: .state)
            try container.encode(mode, forKey: .mode)
        case let .connected(core):
            try container.encode(State.connected, forKey: .state)
            try container.encode(core, forKey: .core)
        case let .authorizing(core):
            try container.encode(State.authorizing, forKey: .state)
            try container.encodeIfPresent(core, forKey: .core)
        case let .error(message):
            try container.encode(State.error, forKey: .state)
            try container.encode(message, forKey: .message)
        }
    }
}

struct AuthorizationRequiredEvent: Codable, Equatable, Sendable {
    var core: CoreSummary?
}

struct ZonesSnapshotEvent: Codable, Equatable, Sendable {
    var zones: [ZoneSummary]
}

struct ZonesChangedEvent: Codable, Equatable, Sendable {
    var zones: [ZoneSummary]
}

struct QueueSnapshotEvent: Codable, Equatable, Sendable {
    var queue: QueueState?
}

struct QueueChangedEvent: Codable, Equatable, Sendable {
    var queue: QueueState?
}

struct BrowseListChangedEvent: Codable, Equatable, Sendable {
    var page: BrowsePage
}

struct BrowseItemReplacedEvent: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var item: BrowseItem
}

struct BrowseItemRemovedEvent: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var itemKey: String
}

struct BrowseServicesResult: Codable, Equatable, Sendable {
    var services: [BrowseServiceSummary]
}

struct NowPlayingChangedEvent: Codable, Equatable, Sendable {
    var zoneID: String
    var nowPlaying: NowPlaying?
}

struct ErrorRaisedEvent: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

struct PersistRequestedEvent: Codable, Equatable, Sendable {
    var persistedState: PersistedSessionState
}

struct ImageFetchedResult: Codable, Equatable, Sendable {
    var imageKey: String
    var localURL: String
}

struct BrowseActionMenuResult: Codable, Equatable, Sendable {
    var sessionKey: String
    var title: String
    var actions: [BrowseItem]
}
