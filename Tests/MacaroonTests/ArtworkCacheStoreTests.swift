import Foundation
import Testing
@testable import Macaroon

@Suite("ArtworkCacheStoreTests")
struct ArtworkCacheStoreTests {
    @Test
    func variantKeyIncludesRequestedSize() {
        let small = ArtworkCacheVariant(imageKey: "art", width: 44, height: 44, format: "image/jpeg")
        let large = ArtworkCacheVariant(imageKey: "art", width: 220, height: 220, format: "image/jpeg")
        let same = ArtworkCacheVariant(imageKey: "art", width: 44, height: 44, format: "image/jpeg")

        #expect(small.cacheKey != large.cacheKey)
        #expect(small.cacheKey == same.cacheKey)
    }

    @Test
    func persistedEntriesSurviveStoreReload() async throws {
        let defaults = UserDefaults(suiteName: "macaroon-artwork-cache-tests-\(UUID().uuidString)")!
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let settingsStore = ArtworkCacheSettingsStore(defaults: defaults)
        let variant = ArtworkCacheVariant(imageKey: "art", width: 44, height: 44, format: "image/jpeg")

        let firstStore = ArtworkCacheStore(directoryURL: directory, settingsStore: settingsStore)
        let storedURL = try await firstStore.storeImage(
            variant: variant,
            data: Data("first-image".utf8),
            contentType: "image/jpeg"
        )

        #expect(storedURL != nil)

        let secondStore = ArtworkCacheStore(directoryURL: directory, settingsStore: settingsStore)
        let cachedURL = try await secondStore.cachedFileURL(for: variant)
        let stats = try await secondStore.stats()

        #expect(cachedURL?.path == storedURL?.path)
        #expect(stats.entryCount == 1)
        #expect(stats.totalBytes == Data("first-image".utf8).count)
    }

    @Test
    func shrinkingLimitEvictsLeastRecentlyUsedEntries() async throws {
        let defaults = UserDefaults(suiteName: "macaroon-artwork-cache-tests-\(UUID().uuidString)")!
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let settingsStore = ArtworkCacheSettingsStore(defaults: defaults)
        let clock = LockedDateSource()
        let store = ArtworkCacheStore(
            directoryURL: directory,
            settingsStore: settingsStore,
            now: { clock.current }
        )

        let first = ArtworkCacheVariant(imageKey: "art-1", width: 44, height: 44, format: "image/jpeg")
        let second = ArtworkCacheVariant(imageKey: "art-2", width: 44, height: 44, format: "image/jpeg")

        clock.current = Date(timeIntervalSince1970: 10)
        _ = try await store.storeImage(
            variant: first,
            data: Data(repeating: 0x01, count: 10),
            contentType: "image/jpeg"
        )

        clock.current = Date(timeIntervalSince1970: 20)
        _ = try await store.storeImage(
            variant: second,
            data: Data(repeating: 0x02, count: 10),
            contentType: "image/jpeg"
        )

        let stats = try await store.setSettings(ArtworkCacheSettings(maxBytes: 10, clamp: false))
        let firstURL = try await store.cachedFileURL(for: first)
        let secondURL = try await store.cachedFileURL(for: second)

        #expect(stats.totalBytes == 10)
        #expect(firstURL == nil)
        #expect(secondURL != nil)
    }

    @Test
    func oversizedImageIsNotPersistedToManagedCache() async throws {
        let defaults = UserDefaults(suiteName: "macaroon-artwork-cache-tests-\(UUID().uuidString)")!
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let settingsStore = ArtworkCacheSettingsStore(defaults: defaults)
        let store = ArtworkCacheStore(directoryURL: directory, settingsStore: settingsStore)
        let variant = ArtworkCacheVariant(imageKey: "art", width: 44, height: 44, format: "image/jpeg")

        _ = try await store.setSettings(ArtworkCacheSettings(maxBytes: 5, clamp: false))
        let url = try await store.storeImage(
            variant: variant,
            data: Data(repeating: 0x01, count: 10),
            contentType: "image/jpeg"
        )
        let stats = try await store.stats()

        #expect(url == nil)
        #expect(stats.entryCount == 0)
        #expect(stats.totalBytes == 0)
    }
}

private final class LockedDateSource: @unchecked Sendable {
    var current = Date()
}
