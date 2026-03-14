import Foundation
import Testing
@testable import Macaroon

@Suite("NativeImageClientTests")
struct NativeImageClientTests {
    @Test
    func fetchImageBuildsExpectedURLAndCachesJPEG() async throws {
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-native-image-tests-\(UUID().uuidString)", isDirectory: true)

        let observedURL = LockedURL()
        let client = NativeImageClient(
            fetch: { url in
                await observedURL.set(url)
                return NativeImageFetchResponse(
                    contentType: "image/jpeg",
                    data: Data("jpeg-bytes".utf8)
                )
            },
            cacheDirectory: cacheDirectory
        )

        let result = try await client.fetchImage(
            imageKey: "1b6e88d2e47f7f56ed9a2d5696e6b227",
            width: 104,
            height: 104,
            format: "image/jpeg",
            core: CoreSummary(
                coreID: "core-1",
                displayName: "m1mini",
                displayVersion: "2.62",
                host: "10.0.7.148",
                port: 9330
            )
        )

        let url = try #require(await observedURL.get())
        #expect(url.absoluteString == "http://10.0.7.148:9330/api/image/1b6e88d2e47f7f56ed9a2d5696e6b227?scale=fit&width=104&height=104&format=image/jpeg")
        #expect(result.imageKey == "1b6e88d2e47f7f56ed9a2d5696e6b227")
        #expect(result.localURL.hasSuffix(".jpg"))
        #expect(FileManager.default.fileExists(atPath: result.localURL))
        let data = try Data(contentsOf: URL(fileURLWithPath: result.localURL))
        #expect(data == Data("jpeg-bytes".utf8))
    }

    @Test
    func fetchImageCachesPNGWithPNGExtension() async throws {
        let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-native-image-tests-\(UUID().uuidString)", isDirectory: true)

        let client = NativeImageClient(
            fetch: { _ in
                NativeImageFetchResponse(
                    contentType: "image/png",
                    data: Data("png-bytes".utf8)
                )
            },
            cacheDirectory: cacheDirectory
        )

        let result = try await client.fetchImage(
            imageKey: "image-key",
            width: 320,
            height: 320,
            format: "image/png",
            core: CoreSummary(
                coreID: "core-1",
                displayName: "m1mini",
                displayVersion: "2.62",
                host: "10.0.7.148",
                port: 9330
            )
        )

        #expect(result.localURL.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: result.localURL))
    }
}

actor LockedURL {
    private var url: URL?

    func set(_ url: URL) {
        self.url = url
    }

    func get() -> URL? {
        url
    }
}
