import Foundation

private enum NativeTransportService {
    static let name = "com.roonlabs.transport:2"
}

enum NativeTransportError: LocalizedError, Equatable, Sendable {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case let .requestFailed(name):
            return "Transport request failed: \(name)"
        }
    }
}

actor NativeTransportClient {
    func control(
        session: NativeMooSession,
        zoneOrOutputID: String,
        command: TransportCommand
    ) async throws {
        let message = try await session.request(
            "\(NativeTransportService.name)/control",
            body: NativeTransportControlRequest(
                zone_or_output_id: zoneOrOutputID,
                control: command.rawValue
            )
        )
        try requireSuccess(message)
    }

    func seek(
        session: NativeMooSession,
        zoneOrOutputID: String,
        how: String,
        seconds: Double
    ) async throws {
        let message = try await session.request(
            "\(NativeTransportService.name)/seek",
            body: NativeTransportSeekRequest(
                zone_or_output_id: zoneOrOutputID,
                how: how,
                seconds: seconds
            )
        )
        try requireSuccess(message)
    }

    func changeVolume(
        session: NativeMooSession,
        outputID: String,
        how: VolumeChangeMode,
        value: Double
    ) async throws {
        let message = try await session.request(
            "\(NativeTransportService.name)/change_volume",
            body: NativeTransportVolumeRequest(
                output_id: outputID,
                how: how.rawValue,
                value: value
            )
        )
        try requireSuccess(message)
    }

    func mute(
        session: NativeMooSession,
        outputID: String,
        how: OutputMuteMode
    ) async throws {
        let message = try await session.request(
            "\(NativeTransportService.name)/mute",
            body: NativeTransportMuteRequest(
                output_id: outputID,
                how: how.rawValue
            )
        )
        try requireSuccess(message)
    }

    private func requireSuccess(_ message: MooMessageEnvelope) throws {
        guard message.name == "Success" else {
            throw NativeTransportError.requestFailed(message.name)
        }
    }
}

private struct NativeTransportControlRequest: Codable {
    var zone_or_output_id: String
    var control: String
}

private struct NativeTransportSeekRequest: Codable {
    var zone_or_output_id: String
    var how: String
    var seconds: Double
}

private struct NativeTransportVolumeRequest: Codable {
    var output_id: String
    var how: String
    var value: Double
}

private struct NativeTransportMuteRequest: Codable {
    var output_id: String
    var how: String
}
