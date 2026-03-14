import Foundation

struct BridgeRequest<Params: Encodable>: Encodable {
    let id: UUID
    let method: String
    let params: Params
}

struct EmptyParams: Codable, Equatable, Sendable {}

struct ConnectAutoParams: Codable, Equatable, Sendable {
    var persistedState: PersistedSessionState
}

struct ConnectManualParams: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var persistedState: PersistedSessionState
}

struct DisconnectParams: Codable, Equatable, Sendable {}

struct ZonesSubscribeParams: Codable, Equatable, Sendable {}

struct BrowseOpenParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var zoneOrOutputID: String?
    var itemKey: String?
}

struct BrowseBackParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var levels: Int
    var zoneOrOutputID: String?
}

struct BrowseHomeParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var zoneOrOutputID: String?
}

struct BrowseRefreshParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var zoneOrOutputID: String?
}

struct BrowseLoadPageParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var offset: Int
    var count: Int
}

struct BrowseSubmitInputParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var itemKey: String
    var input: String
    var zoneOrOutputID: String?
}

struct BrowseContextActionsParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var itemKey: String
    var zoneOrOutputID: String?
}

struct BrowsePerformActionParams: Codable, Equatable, Sendable {
    var hierarchy: BrowseHierarchy
    var sessionKey: String
    var itemKey: String
    var zoneOrOutputID: String?
    var contextItemKey: String?
    var actionTitle: String?
}

enum TransportCommand: String, Codable, Equatable, Sendable {
    case playPause = "playpause"
    case play
    case pause
    case stop
    case next
    case previous
}

struct TransportCommandParams: Codable, Equatable, Sendable {
    var zoneOrOutputID: String
    var command: TransportCommand
}

enum VolumeChangeMode: String, Codable, Equatable, Sendable {
    case absolute
    case relative
    case relativeStep = "relative_step"
}

struct TransportSeekParams: Codable, Equatable, Sendable {
    var zoneOrOutputID: String
    var how: String
    var seconds: Double
}

struct TransportVolumeParams: Codable, Equatable, Sendable {
    var outputID: String
    var how: VolumeChangeMode
    var value: Double
}

struct ImageFetchParams: Codable, Equatable, Sendable {
    var imageKey: String
    var width: Int
    var height: Int
    var format: String
}

struct PersistedStateParams: Codable, Equatable, Sendable {
    var persistedState: PersistedSessionState
}

struct BridgeResponse<Result: Decodable>: Decodable {
    var id: UUID
    var result: Result?
    var error: BridgeErrorPayload?
}

struct BridgeEvent<Payload: Decodable>: Decodable {
    var event: String
    var payload: Payload
}

struct BridgeErrorPayload: Codable, Equatable, Error, Sendable {
    var code: String
    var message: String
}

struct EmptyResult: Codable, Equatable, Sendable {}

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
