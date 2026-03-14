import Foundation
import Testing
@testable import Macaroon

@Suite("NativeTransportClientTests")
struct NativeTransportClientTests {
    @Test
    func controlSendsExpectedPayload() async throws {
        let transport = MockNativeMooTransport(messages: [
            try successMessage(requestID: "0")
        ])
        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeTransportClient()
        try await client.control(session: session, zoneOrOutputID: "zone-1", command: .playPause)

        let sent = await transport.sentMessages()
        let request = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(request.name == "com.roonlabs.transport:2/control")
        let body = try JSONDecoder().decode(TransportControlBody.self, from: try #require(request.body))
        #expect(body.zone_or_output_id == "zone-1")
        #expect(body.control == "playpause")
    }

    @Test
    func seekSendsExpectedPayload() async throws {
        let transport = MockNativeMooTransport(messages: [
            try successMessage(requestID: "0")
        ])
        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeTransportClient()
        try await client.seek(session: session, zoneOrOutputID: "zone-1", how: "absolute", seconds: 123.5)

        let sent = await transport.sentMessages()
        let request = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(request.name == "com.roonlabs.transport:2/seek")
        let body = try JSONDecoder().decode(TransportSeekBody.self, from: try #require(request.body))
        #expect(body.zone_or_output_id == "zone-1")
        #expect(body.how == "absolute")
        #expect(body.seconds == 123.5)
    }

    @Test
    func changeVolumeSendsExpectedPayload() async throws {
        let transport = MockNativeMooTransport(messages: [
            try successMessage(requestID: "0")
        ])
        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeTransportClient()
        try await client.changeVolume(session: session, outputID: "output-1", how: .relativeStep, value: 1)

        let sent = await transport.sentMessages()
        let request = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(request.name == "com.roonlabs.transport:2/change_volume")
        let body = try JSONDecoder().decode(TransportVolumeBody.self, from: try #require(request.body))
        #expect(body.output_id == "output-1")
        #expect(body.how == "relative_step")
        #expect(body.value == 1)
    }

    @Test
    func muteSendsExpectedPayload() async throws {
        let transport = MockNativeMooTransport(messages: [
            try successMessage(requestID: "0")
        ])
        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeTransportClient()
        try await client.mute(session: session, outputID: "output-1", how: .mute)

        let sent = await transport.sentMessages()
        let request = try MooCodec.decodeMessage(try #require(sent.first))
        #expect(request.name == "com.roonlabs.transport:2/mute")
        let body = try JSONDecoder().decode(TransportMuteBody.self, from: try #require(request.body))
        #expect(body.output_id == "output-1")
        #expect(body.how == "mute")
    }
}

private func successMessage(requestID: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .complete,
        name: "Success",
        requestID: requestID,
        body: nil,
        contentType: nil
    )
}

private struct TransportControlBody: Decodable {
    var zone_or_output_id: String
    var control: String
}

private struct TransportSeekBody: Decodable {
    var zone_or_output_id: String
    var how: String
    var seconds: Double
}

private struct TransportVolumeBody: Decodable {
    var output_id: String
    var how: String
    var value: Double
}

private struct TransportMuteBody: Decodable {
    var output_id: String
    var how: String
}
