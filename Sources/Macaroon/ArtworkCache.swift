import CryptoKit
import Foundation

struct ArtworkCacheSettings: Equatable, Sendable {
    static let minimumBytes = 128 * 1024 * 1024
    static let defaultBytes = 512 * 1024 * 1024
    static let maximumBytes = 4 * 1024 * 1024 * 1024

    var maxBytes: Int

    init(maxBytes: Int = ArtworkCacheSettings.defaultBytes, clamp: Bool = true) {
        self.maxBytes = clamp ? Self.clamp(maxBytes) : max(1, maxBytes)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minimumBytes), maximumBytes)
    }
}

struct ArtworkCacheStats: Equatable, Sendable {
    var totalBytes: Int
    var entryCount: Int
}

struct ArtworkCacheVariant: Hashable, Codable, Sendable {
    var imageKey: String
    var width: Int
    var height: Int
    var format: String

    var normalizedFormat: String {
        format.lowercased()
    }

    var cacheKey: String {
        let raw = "\(imageKey)|\(width)|\(height)|\(normalizedFormat)"
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ArtworkCacheEntry: Codable, Equatable, Sendable {
    var variant: ArtworkCacheVariant
    var contentType: String
    var byteCount: Int
    var lastAccessedAt: Date
    var relativePath: String
}

struct ArtworkCacheSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let maxBytesKey = "Macaroon.ArtworkCache.MaxBytes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ArtworkCacheSettings {
        let stored = defaults.object(forKey: maxBytesKey) as? Int
        return ArtworkCacheSettings(maxBytes: stored ?? ArtworkCacheSettings.defaultBytes)
    }

    func save(_ settings: ArtworkCacheSettings) {
        defaults.set(settings.maxBytes, forKey: maxBytesKey)
    }
}

private struct ArtworkCacheIndex: Codable {
    var entries: [String: ArtworkCacheEntry]
}

actor ArtworkCacheStore {
    static let shared = ArtworkCacheStore()

    private let directoryURL: URL
    private let transientDirectoryURL: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let settingsStore: ArtworkCacheSettingsStore
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var settings: ArtworkCacheSettings
    private var entries: [String: ArtworkCacheEntry] = [:]
    private var didLoad = false

    init(
        directoryURL: URL? = nil,
        settingsStore: ArtworkCacheSettingsStore = ArtworkCacheSettingsStore(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let baseDirectory: URL
        if let directoryURL {
            baseDirectory = directoryURL
        } else {
            let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            baseDirectory = cachesDirectory
                .appendingPathComponent("Macaroon", isDirectory: true)
                .appendingPathComponent("Artwork", isDirectory: true)
        }

        self.directoryURL = baseDirectory
        self.transientDirectoryURL = baseDirectory.appendingPathComponent("Transient", isDirectory: true)
        self.indexURL = baseDirectory.appendingPathComponent("index.json", isDirectory: false)
        self.fileManager = fileManager
        self.settingsStore = settingsStore
        self.now = now
        self.settings = settingsStore.load()
        encoder.outputFormatting = [.sortedKeys]
    }

    func setSettings(_ settings: ArtworkCacheSettings) throws -> ArtworkCacheStats {
        try prepare()
        self.settings = settings
        settingsStore.save(settings)
        try trimToLimit()
        try persistIndex()
        return currentStats()
    }

    func currentSettings() -> ArtworkCacheSettings {
        settings
    }

    func stats() throws -> ArtworkCacheStats {
        try prepare()
        return currentStats()
    }

    func cachedFileURL(for variant: ArtworkCacheVariant) throws -> URL? {
        try prepare()
        guard var entry = entries[variant.cacheKey] else {
            return nil
        }

        let fileURL = directoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries.removeValue(forKey: variant.cacheKey)
            try persistIndex()
            return nil
        }

        entry.lastAccessedAt = now()
        entries[variant.cacheKey] = entry
        try persistIndex()
        return fileURL
    }

    func storeImage(
        variant: ArtworkCacheVariant,
        data: Data,
        contentType: String
    ) throws -> URL? {
        try prepare()

        guard data.count <= settings.maxBytes else {
            return nil
        }

        let relativePath = "\(variant.cacheKey).\(fileExtension(for: contentType, format: variant.normalizedFormat))"
        let fileURL = directoryURL.appendingPathComponent(relativePath, isDirectory: false)

        if let existingEntry = entries[variant.cacheKey],
           existingEntry.relativePath != relativePath {
            let existingURL = directoryURL.appendingPathComponent(existingEntry.relativePath, isDirectory: false)
            try? fileManager.removeItem(at: existingURL)
        }

        try data.write(to: fileURL, options: [.atomic])
        entries[variant.cacheKey] = ArtworkCacheEntry(
            variant: variant,
            contentType: contentType,
            byteCount: data.count,
            lastAccessedAt: now(),
            relativePath: relativePath
        )
        try trimToLimit()
        try persistIndex()
        guard let entry = entries[variant.cacheKey] else {
            return nil
        }
        return directoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
    }

    func writeTransientImage(
        variant: ArtworkCacheVariant,
        data: Data,
        contentType: String
    ) throws -> URL {
        try prepare()
        try fileManager.createDirectory(at: transientDirectoryURL, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).\(fileExtension(for: contentType, format: variant.normalizedFormat))"
        let fileURL = transientDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    func clear() throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        entries = [:]
        didLoad = false
        try prepare()
        try persistIndex()
    }

    private func prepare() throws {
        guard didLoad == false else {
            return
        }

        settings = settingsStore.load()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: transientDirectoryURL.path) {
            try? fileManager.removeItem(at: transientDirectoryURL)
        }

        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                let index = try decoder.decode(ArtworkCacheIndex.self, from: data)
                entries = index.entries
            } catch {
                entries = [:]
            }
        } else {
            entries = [:]
        }

        var removedMissingFiles = false
        for (key, entry) in entries {
            let fileURL = directoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: fileURL.path) == false {
                entries.removeValue(forKey: key)
                removedMissingFiles = true
            }
        }

        try trimToLimit()
        didLoad = true

        if removedMissingFiles {
            try persistIndex()
        }
    }

    private func trimToLimit() throws {
        var totalBytes = entries.values.reduce(0) { $0 + $1.byteCount }
        guard totalBytes > settings.maxBytes else {
            return
        }

        let sortedEntries = entries.values.sorted { lhs, rhs in
            if lhs.lastAccessedAt == rhs.lastAccessedAt {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.lastAccessedAt < rhs.lastAccessedAt
        }

        for entry in sortedEntries {
            guard totalBytes > settings.maxBytes else {
                break
            }
            let fileURL = directoryURL.appendingPathComponent(entry.relativePath, isDirectory: false)
            try? fileManager.removeItem(at: fileURL)
            entries.removeValue(forKey: entry.variant.cacheKey)
            totalBytes -= entry.byteCount
        }
    }

    private func persistIndex() throws {
        let data = try encoder.encode(ArtworkCacheIndex(entries: entries))
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: [.atomic])
    }

    private func currentStats() -> ArtworkCacheStats {
        ArtworkCacheStats(
            totalBytes: entries.values.reduce(0) { $0 + $1.byteCount },
            entryCount: entries.count
        )
    }

    private func fileExtension(for contentType: String, format: String) -> String {
        let normalizedType = contentType.lowercased()
        if normalizedType.contains("png") || format.contains("png") {
            return "png"
        }
        if normalizedType.contains("webp") || format.contains("webp") {
            return "webp"
        }
        return "jpg"
    }
}
