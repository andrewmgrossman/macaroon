import Foundation

enum BridgeMessageDecoder {
    static func decodeInboundMessage(_ data: Data, decoder: JSONDecoder) throws -> BridgeInboundMessage? {
        if let response = try? decoder.decode(ResponseBase.self, from: data) {
            return .response(id: response.id, result: response.result, error: response.error)
        }

        let base = try decoder.decode(EventBase.self, from: data)
        switch base.event {
        case "core.connectionChanged":
            return .event(.connectionChanged(try decoder.decode(BridgeEvent<ConnectionChangedEvent>.self, from: data).payload))
        case "core.authorizationRequired":
            return .event(.authorizationRequired(try decoder.decode(BridgeEvent<AuthorizationRequiredEvent>.self, from: data).payload))
        case "zones.snapshot":
            return .event(.zonesSnapshot(try decoder.decode(BridgeEvent<ZonesSnapshotEvent>.self, from: data).payload))
        case "zones.changed":
            return .event(.zonesChanged(try decoder.decode(BridgeEvent<ZonesChangedEvent>.self, from: data).payload))
        case "queue.snapshot":
            return .event(.queueSnapshot(try decoder.decode(BridgeEvent<QueueSnapshotEvent>.self, from: data).payload))
        case "queue.changed":
            return .event(.queueChanged(try decoder.decode(BridgeEvent<QueueChangedEvent>.self, from: data).payload))
        case "browse.listChanged":
            return .event(.browseListChanged(try decoder.decode(BridgeEvent<BrowseListChangedEvent>.self, from: data).payload))
        case "browse.itemReplaced":
            return .event(.browseItemReplaced(try decoder.decode(BridgeEvent<BrowseItemReplacedEvent>.self, from: data).payload))
        case "browse.itemRemoved":
            return .event(.browseItemRemoved(try decoder.decode(BridgeEvent<BrowseItemRemovedEvent>.self, from: data).payload))
        case "nowPlaying.changed":
            return .event(.nowPlayingChanged(try decoder.decode(BridgeEvent<NowPlayingChangedEvent>.self, from: data).payload))
        case "session.persistRequested":
            return .event(.persistRequested(try decoder.decode(BridgeEvent<PersistRequestedEvent>.self, from: data).payload))
        case "error.raised":
            return .event(.errorRaised(try decoder.decode(BridgeEvent<ErrorRaisedEvent>.self, from: data).payload))
        default:
            return nil
        }
    }
}

private struct EventBase: Codable {
    var event: String
}

private struct ResponseBase: Decodable {
    var id: UUID
    var result: Data?
    var error: BridgeErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        error = try container.decodeIfPresent(BridgeErrorPayload.self, forKey: .error)

        if container.contains(.result) {
            let value = try container.decode(JSONValue.self, forKey: .result)
            result = try JSONEncoder().encode(value)
        } else {
            result = nil
        }
    }
}

private enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
