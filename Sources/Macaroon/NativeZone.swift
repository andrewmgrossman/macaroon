import Foundation

private enum NativeZoneService {
    static let name = "com.roonlabs.transport:2"
}

enum NativeZoneUpdateKind: Equatable, Sendable {
    case snapshot
    case changed
}

struct NativeZoneUpdate: Sendable {
    var kind: NativeZoneUpdateKind
    var zones: [ZoneSummary]
    var removedZoneIDs: [String]
    var liveZonesByID: [String: ZoneSummary]
}

actor NativeZoneClient {
    func subscribe(
        session: NativeMooSession,
        subscriptionKey: Int,
        handler: @escaping @Sendable (MooMessageEnvelope) -> Void
    ) async throws {
        try await session.subscribe(
            "\(NativeZoneService.name)/subscribe_zones",
            body: NativeZoneSubscriptionKeyRequest(subscription_key: subscriptionKey),
            handler: handler
        )
    }

    func process(
        message: MooMessageEnvelope,
        previousZonesByID: [String: ZoneSummary]
    ) throws -> NativeZoneUpdate? {
        switch message.name {
        case "Subscribed":
            let payload = try decodeBody(NativeZonesSubscribedPayload.self, from: message)
            let zones = Self.deduplicateZones(payload.zones.map(Self.toZoneSummary))
            return NativeZoneUpdate(
                kind: .snapshot,
                zones: zones,
                removedZoneIDs: [],
                liveZonesByID: Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, $0) })
            )
        case "Changed":
            let payload = try decodeBody(NativeZonesChangedPayload.self, from: message)
            var liveZonesByID = previousZonesByID
            let removedZoneIDs = payload.zones_removed ?? []
            for removedID in removedZoneIDs {
                liveZonesByID.removeValue(forKey: removedID)
            }

            let changedZones = (payload.zones_added ?? []) + (payload.zones_changed ?? [])
            var emitted = changedZones.map(Self.toZoneSummary)

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

            guard emitted.isEmpty == false || removedZoneIDs.isEmpty == false else {
                return nil
            }

            return NativeZoneUpdate(
                kind: .changed,
                zones: Self.deduplicateZones(emitted),
                removedZoneIDs: removedZoneIDs,
                liveZonesByID: liveZonesByID
            )
        default:
            return nil
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

private struct NativeZoneSubscriptionKeyRequest: Codable {
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
