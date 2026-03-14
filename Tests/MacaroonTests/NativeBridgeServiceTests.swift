import Testing
@testable import Macaroon

@Suite("NativeBridgeServiceTests")
struct NativeBridgeServiceTests {
    @Test
    @MainActor
    func requestThrowsNotImplemented() async {
        let service = NativeRoonBridgeService()

        await #expect(throws: NativeBridgeError.notImplemented(method: "connect.auto")) {
            _ = try await service.request(
                "connect.auto",
                params: ConnectAutoParams(persistedState: .empty),
                as: EmptyResult.self
            )
        }
    }

    @Test
    func experimentalBridgeFlagDefaultsOff() {
        #expect(NativeBridgeRuntimeConfiguration.isEnabled == false)
    }
}
