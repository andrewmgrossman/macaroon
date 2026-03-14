import Foundation
import Testing
@testable import Macaroon

@Suite("FixtureCaptureTests")
struct FixtureCaptureTests {
    @Test
    func recorderIsNilWhenCaptureDisabled() {
        let recorder = FixtureCaptureRecorder(baseDirectoryURL: nil)
        #expect(recorder == nil)
    }

    @Test
    func mooCodecRoundTripPreservesRequestIDAndBody() throws {
        let request = MooRequestEnvelope(
            requestID: "req-1",
            endpoint: "/api",
            body: Data("{\"hello\":\"world\"}".utf8)
        )

        let encoded = try MooCodec.encode(request)
        let decoded = try MooCodec.decodeMessage(encoded)

        #expect(decoded.requestID == "req-1")
        #expect(decoded.body == Data("{\"hello\":\"world\"}".utf8))
        #expect(decoded.verb == .request)
        #expect(decoded.name == "/api")
    }

    @Test
    func soodProbeContainsExpectedMarker() {
        let probe = String(decoding: SoodCodec.discoveryProbe(), as: UTF8.self)
        #expect(probe.contains("SOOD"))
        #expect(probe.contains("query_service_id"))
    }

    @Test
    func soodResponseDecodesCoreEndpoint() throws {
        let payload = soodResponsePayload(
            serviceID: SoodCodec.serviceID,
            uniqueID: "core-1",
            displayName: "m1mini",
            httpPort: "9330"
        )

        let message = try SoodCodec.decode(payload, fromHost: "10.0.7.148", port: 9003)
        #expect(message == SoodDiscoveryMessage(
            uniqueID: "core-1",
            displayName: "m1mini",
            host: "10.0.7.148",
            port: 9330
        ))
    }

    private func soodResponsePayload(
        serviceID: String,
        uniqueID: String,
        displayName: String,
        httpPort: String
    ) -> Data {
        var data = Data("SOOD".utf8)
        data.append(2)
        data.append(Array("R".utf8)[0])

        let props = [
            "display_name": displayName,
            "http_port": httpPort,
            "service_id": serviceID,
            "unique_id": uniqueID
        ]

        for key in props.keys.sorted() {
            let keyData = Data(key.utf8)
            let valueData = Data(props[key]!.utf8)
            data.append(UInt8(keyData.count))
            data.append(keyData)
            data.append(UInt8((valueData.count >> 8) & 0xff))
            data.append(UInt8(valueData.count & 0xff))
            data.append(valueData)
        }

        return data
    }
}
