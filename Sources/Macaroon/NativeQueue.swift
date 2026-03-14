import Foundation

private enum NativeQueueService {
    static let name = "com.roonlabs.transport:2"
}

enum NativeQueueError: LocalizedError, Equatable, Sendable {
    case requestFailed(String)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case let .requestFailed(name):
            return "Queue request failed: \(name)"
        case .invalidPayload:
            return "The Roon Core returned an invalid queue payload."
        }
    }
}

enum NativeQueueUpdateKind: Equatable, Sendable {
    case snapshot
    case changed
}

struct NativeQueueUpdate: Sendable {
    var kind: NativeQueueUpdateKind
    var queue: QueueState?
}

actor NativeQueueClient {
    func subscribe(
        session: NativeMooSession,
        zoneOrOutputID: String,
        maxItemCount: Int,
        subscriptionKey: Int,
        handler: @escaping @Sendable (MooMessageEnvelope) -> Void
    ) async throws {
        try await session.subscribe(
            "\(NativeQueueService.name)/subscribe_queue",
            body: NativeQueueSubscribeRequest(
                zone_or_output_id: zoneOrOutputID,
                max_item_count: maxItemCount,
                subscription_key: subscriptionKey
            ),
            handler: handler
        )
    }

    func playFromHere(
        session: NativeMooSession,
        zoneOrOutputID: String,
        queueItemID: String
    ) async throws {
        let message = try await session.request(
            "\(NativeQueueService.name)/play_from_here",
            body: NativeQueuePlayFromHereRequest(
                zone_or_output_id: zoneOrOutputID,
                queue_item_id: queueItemID
            )
        )
        guard message.name == "Success" else {
            throw NativeQueueError.requestFailed(message.name)
        }
    }

    func process(
        message: MooMessageEnvelope,
        zoneOrOutputID: String,
        previousState: QueueState?
    ) throws -> NativeQueueUpdate? {
        switch message.name {
        case "Subscribed":
            let payload = try decodePayload(from: message)
            return NativeQueueUpdate(
                kind: .snapshot,
                queue: toQueueState(payload, zoneOrOutputID: zoneOrOutputID, previousState: nil)
            )
        case "Changed":
            let payload = try decodePayload(from: message)
            return NativeQueueUpdate(
                kind: .changed,
                queue: toQueueState(payload, zoneOrOutputID: zoneOrOutputID, previousState: previousState)
            )
        case "Unsubscribed":
            return NativeQueueUpdate(kind: .snapshot, queue: nil)
        default:
            return nil
        }
    }

    private func decodePayload(from message: MooMessageEnvelope) throws -> NativeQueuePayload {
        guard let body = message.body else {
            throw NativeQueueError.invalidPayload
        }
        do {
            return try JSONDecoder().decode(NativeQueuePayload.self, from: body)
        } catch {
            let rawBody = String(data: body, encoding: .utf8) ?? "<non-utf8 \(body.count) bytes>"
            throw NativeQueueDecodingError(
                underlyingMessage: error.localizedDescription,
                rawBody: rawBody
            )
        }
    }

    private func toQueueState(
        _ message: NativeQueuePayload,
        zoneOrOutputID: String,
        previousState: QueueState?
    ) -> QueueState {
        let inferredCurrentQueueItemID =
            message.now_playing_queue_item_id ??
            message.current_queue_item_id ??
            message.queue_item_id ??
            message.items?.first(where: { $0.is_current == true || $0.now_playing == true })?.resolvedQueueItemID ??
            message.queue_items?.first(where: { $0.is_current == true || $0.now_playing == true })?.resolvedQueueItemID ??
            previousState?.currentQueueItemID

        let fullItemPayload = message.items ?? message.queue_items ?? message.queue?.items
        var items: [QueueItemSummary]

        if let fullItemPayload {
            items = fullItemPayload.enumerated().map { index, item in
                toQueueItemSummary(
                    item,
                    inferredCurrentQueueItemID: inferredCurrentQueueItemID,
                    fallbackIndex: index
                )
            }
        } else {
            items = (previousState?.items ?? []).map { item in
                var item = item
                item.isCurrent = inferredCurrentQueueItemID != nil && item.queueItemID == inferredCurrentQueueItemID
                return item
            }

            var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.queueItemID, $0) })

            for changed in message.items_changed ?? [] {
                let summary = toQueueItemSummary(
                    changed,
                    inferredCurrentQueueItemID: inferredCurrentQueueItemID,
                    fallbackIndex: byID.count
                )
                byID[summary.queueItemID] = summary
            }

            for added in message.items_added ?? [] {
                let summary = toQueueItemSummary(
                    added,
                    inferredCurrentQueueItemID: inferredCurrentQueueItemID,
                    fallbackIndex: byID.count
                )
                byID[summary.queueItemID] = summary
            }

            for removed in message.items_removed ?? [] {
                guard let removedID = removed.resolvedQueueItemID else {
                    continue
                }
                byID.removeValue(forKey: removedID)
            }

            items = Array(byID.values).map { item in
                var item = item
                item.isCurrent = inferredCurrentQueueItemID != nil && item.queueItemID == inferredCurrentQueueItemID
                return item
            }
        }

        if let changes = message.changes, changes.isEmpty == false {
            var orderedItems = previousState?.items ?? items

            for change in changes {
                switch change.operation {
                case "remove":
                    let index = max(0, change.index ?? 0)
                    let count = max(0, change.count ?? 0)
                    guard index < orderedItems.count else {
                        continue
                    }
                    let boundedCount = min(count, orderedItems.count - index)
                    orderedItems.removeSubrange(index..<(index + boundedCount))
                case "insert":
                    let index = max(0, min(change.index ?? orderedItems.count, orderedItems.count))
                    let insertedItems = (change.items ?? []).enumerated().map { offset, item in
                        toQueueItemSummary(
                            item,
                            inferredCurrentQueueItemID: inferredCurrentQueueItemID,
                            fallbackIndex: index + offset
                        )
                    }
                    orderedItems.insert(contentsOf: insertedItems, at: index)
                default:
                    continue
                }
            }

            items = orderedItems.enumerated().map { index, item in
                QueueItemSummary(
                    queueItemID: item.queueItemID.isEmpty ? "queue-item-\(index)" : item.queueItemID,
                    title: item.title,
                    subtitle: item.subtitle,
                    detail: item.detail,
                    imageKey: item.imageKey,
                    length: item.length,
                    isCurrent: inferredCurrentQueueItemID != nil
                        ? item.queueItemID == inferredCurrentQueueItemID
                        : item.isCurrent
                )
            }
        }

        let currentQueueItemID =
            items.first(where: { $0.isCurrent })?.queueItemID ??
            inferredCurrentQueueItemID

        return QueueState(
            zoneID: message.zone_id ?? zoneOrOutputID,
            title: message.title ?? message.display_name ?? previousState?.title ?? "Queue",
            totalCount: message.count ?? message.total_count ?? message.queue_count ?? items.count,
            currentQueueItemID: currentQueueItemID,
            items: items
        )
    }

    private func toQueueItemSummary(
        _ item: NativeQueueItemPayload,
        inferredCurrentQueueItemID: String?,
        fallbackIndex: Int
    ) -> QueueItemSummary {
        let queueItemID = item.resolvedQueueItemID ?? "queue-item-\(fallbackIndex)"
        let lines = queueLines(for: item)
        return QueueItemSummary(
            queueItemID: queueItemID,
            title: lines.title,
            subtitle: lines.subtitle,
            detail: lines.detail,
            imageKey: item.image_key,
            length: item.length ?? item.duration,
            isCurrent:
                item.is_current == true ||
                item.now_playing == true ||
                (inferredCurrentQueueItemID != nil && queueItemID == inferredCurrentQueueItemID)
        )
    }

    private func queueLines(for item: NativeQueueItemPayload) -> (title: String, subtitle: String?, detail: String?) {
        if let threeLine = item.three_line {
            return (
                title: threeLine.line1 ?? "Unknown",
                subtitle: threeLine.line2,
                detail: threeLine.line3
            )
        }
        if let twoLine = item.two_line {
            return (
                title: twoLine.line1 ?? "Unknown",
                subtitle: twoLine.line2,
                detail: nil
            )
        }
        if let oneLine = item.one_line {
            return (
                title: oneLine.line1 ?? "Unknown",
                subtitle: nil,
                detail: nil
            )
        }
        return (
            title: item.title ?? "Unknown",
            subtitle: item.subtitle,
            detail: item.detail
        )
    }
}

private struct NativeQueueDecodingError: LocalizedError, Sendable {
    var underlyingMessage: String
    var rawBody: String

    var errorDescription: String? {
        "Queue decode failed: \(underlyingMessage)\nPayload: \(rawBody)"
    }
}

private struct NativeQueueSubscribeRequest: Codable {
    var zone_or_output_id: String
    var max_item_count: Int
    var subscription_key: Int
}

private struct NativeQueuePlayFromHereRequest: Codable {
    var zone_or_output_id: String
    var queue_item_id: String
}

private struct NativeQueuePayload: Decodable {
    var zone_id: String?
    var title: String?
    var display_name: String?
    var count: Int?
    var total_count: Int?
    var queue_count: Int?
    var now_playing_queue_item_id: String?
    var current_queue_item_id: String?
    var queue_item_id: String?
    var items: [NativeQueueItemPayload]?
    var queue_items: [NativeQueueItemPayload]?
    var queue: NativeQueueNestedPayload?
    var items_changed: [NativeQueueItemPayload]?
    var items_added: [NativeQueueItemPayload]?
    var items_removed: [NativeQueueRemovedPayload]?
    var changes: [NativeQueueIndexedChange]?
}

private struct NativeQueueNestedPayload: Decodable {
    var items: [NativeQueueItemPayload]?
}

private struct NativeQueueIndexedChange: Decodable {
    var operation: String
    var index: Int?
    var count: Int?
    var items: [NativeQueueItemPayload]?
}

private struct NativeQueueItemPayload: Decodable {
    var queue_item_id: String?
    var item_id: String?
    var id: String?
    var three_line: NativeQueueThreeLine?
    var two_line: NativeQueueTwoLine?
    var one_line: NativeQueueOneLine?
    var title: String?
    var subtitle: String?
    var detail: String?
    var image_key: String?
    var length: Double?
    var duration: Double?
    var is_current: Bool?
    var now_playing: Bool?

    private enum CodingKeys: String, CodingKey {
        case queue_item_id
        case item_id
        case id
        case three_line
        case two_line
        case one_line
        case title
        case subtitle
        case detail
        case image_key
        case length
        case duration
        case is_current
        case now_playing
    }

    var resolvedQueueItemID: String? {
        queue_item_id ?? item_id ?? id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue_item_id = try container.decodeLossyStringIfPresent(forKey: .queue_item_id)
        item_id = try container.decodeLossyStringIfPresent(forKey: .item_id)
        id = try container.decodeLossyStringIfPresent(forKey: .id)
        three_line = try container.decodeIfPresent(NativeQueueThreeLine.self, forKey: .three_line)
        two_line = try container.decodeIfPresent(NativeQueueTwoLine.self, forKey: .two_line)
        one_line = try container.decodeIfPresent(NativeQueueOneLine.self, forKey: .one_line)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        image_key = try container.decodeIfPresent(String.self, forKey: .image_key)
        length = try container.decodeLossyDoubleIfPresent(forKey: .length)
        duration = try container.decodeLossyDoubleIfPresent(forKey: .duration)
        is_current = try container.decodeIfPresent(Bool.self, forKey: .is_current)
        now_playing = try container.decodeIfPresent(Bool.self, forKey: .now_playing)
    }
}

private struct NativeQueueRemovedPayload: Decodable {
    var queue_item_id: String?
    var item_id: String?
    var id: String?
    var rawValue: String?

    private enum CodingKeys: String, CodingKey {
        case queue_item_id
        case item_id
        case id
    }

    var resolvedQueueItemID: String? {
        queue_item_id ?? item_id ?? id ?? rawValue
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer() {
            if let stringValue = try? singleValue.decode(String.self) {
                queue_item_id = nil
                item_id = nil
                id = nil
                rawValue = stringValue
                return
            }
            if let intValue = try? singleValue.decode(Int.self) {
                queue_item_id = nil
                item_id = nil
                id = nil
                rawValue = String(intValue)
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue_item_id = try container.decodeLossyStringIfPresent(forKey: .queue_item_id)
        item_id = try container.decodeLossyStringIfPresent(forKey: .item_id)
        id = try container.decodeLossyStringIfPresent(forKey: .id)
        rawValue = nil
    }
}

private struct NativeQueueThreeLine: Decodable {
    var line1: String?
    var line2: String?
    var line3: String?

    private enum CodingKeys: String, CodingKey {
        case line1
        case line2
        case line3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line1 = try container.decodeLossyStringIfPresent(forKey: .line1)
        line2 = try container.decodeLossyStringIfPresent(forKey: .line2)
        line3 = try container.decodeLossyStringIfPresent(forKey: .line3)
    }
}

private struct NativeQueueTwoLine: Decodable {
    var line1: String?
    var line2: String?

    private enum CodingKeys: String, CodingKey {
        case line1
        case line2
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line1 = try container.decodeLossyStringIfPresent(forKey: .line1)
        line2 = try container.decodeLossyStringIfPresent(forKey: .line2)
    }
}

private struct NativeQueueOneLine: Decodable {
    var line1: String?

    private enum CodingKeys: String, CodingKey {
        case line1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line1 = try container.decodeLossyStringIfPresent(forKey: .line1)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key) else {
            return nil
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return String(intValue)
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return String(doubleValue)
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key) else {
            return nil
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? decode(String.self, forKey: key),
           let parsed = Double(stringValue) {
            return parsed
        }
        return nil
    }
}
