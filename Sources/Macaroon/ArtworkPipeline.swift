import AppKit
import Foundation
import ImageIO

enum ArtworkPipelinePriority: Sendable {
    case visible
    case prefetch

    var taskPriority: TaskPriority {
        switch self {
        case .visible:
            return .userInitiated
        case .prefetch:
            return .utility
        }
    }

    var queueRank: Int {
        switch self {
        case .visible:
            return 0
        case .prefetch:
            return 1
        }
    }
}

struct ArtworkPipelineRequest: Hashable, Sendable {
    var imageKey: String
    var width: Int
    var height: Int
    var format: String

    var variant: ArtworkCacheVariant {
        ArtworkCacheVariant(
            imageKey: imageKey,
            width: width,
            height: height,
            format: format
        )
    }

    var cacheKey: String {
        variant.cacheKey
    }
}

struct ArtworkPipelineResult: @unchecked Sendable {
    var image: NSImage
    var decodedPixelCost: Int
}

actor ArtworkPipeline {
    typealias FetchArtwork = @MainActor @Sendable (String, Int, Int, String) async throws -> ImageFetchedResult

    private final class CacheEntry: NSObject {
        let result: ArtworkPipelineResult

        init(result: ArtworkPipelineResult) {
            self.result = result
        }
    }

    private struct InFlightRequest {
        var id: UUID
        var task: Task<ArtworkPipelineResult?, Never>
        var isPrefetchOnly: Bool
    }

    private struct SlotWaiter {
        var id: Int
        var priority: ArtworkPipelinePriority
        var sequence: Int
        var continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrentFetches: Int
    private let memoryCache = NSCache<NSString, CacheEntry>()
    private var inFlight: [String: InFlightRequest] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var activeFetches = 0
    private var nextWaiterID = 0
    private var nextWaiterSequence = 0
    private var waiters: [SlotWaiter] = []

    init(maxConcurrentFetches: Int = 4) {
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
        memoryCache.totalCostLimit = 64 * 1024 * 1024
        memoryCache.countLimit = 512
    }

    func setMemoryCacheLimit(bytes: Int) {
        memoryCache.totalCostLimit = max(32 * 1024 * 1024, min(128 * 1024 * 1024, bytes))
        memoryCache.countLimit = 512
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    func cachedResult(for request: ArtworkPipelineRequest) -> ArtworkPipelineResult? {
        memoryCache.object(forKey: request.cacheKey as NSString)?.result
    }

    func load(
        request: ArtworkPipelineRequest,
        priority: ArtworkPipelinePriority,
        fetchArtwork: @escaping FetchArtwork
    ) async -> ArtworkPipelineResult? {
        let cacheKey = request.cacheKey
        if let cached = memoryCache.object(forKey: cacheKey as NSString)?.result {
            return cached
        }

        if var existing = inFlight[cacheKey] {
            if priority == .visible {
                existing.isPrefetchOnly = false
                inFlight[cacheKey] = existing
            }
            return await existing.task.value
        }

        let task = Task(priority: priority.taskPriority) { [weak self] in
            await self?.performLoad(
                request: request,
                priority: priority,
                fetchArtwork: fetchArtwork
            )
        }
        let requestID = UUID()
        inFlight[cacheKey] = InFlightRequest(
            id: requestID,
            task: task,
            isPrefetchOnly: priority == .prefetch
        )

        let result = await task.value
        if let current = inFlight[cacheKey], current.id == requestID {
            inFlight.removeValue(forKey: cacheKey)
        }
        return result
    }

    func prefetch(
        requests: [ArtworkPipelineRequest],
        fetchArtwork: @escaping FetchArtwork
    ) {
        let requestedKeys = Set(requests.map(\.cacheKey))
        cancelPrefetches(keeping: requestedKeys)

        for request in requests {
            let cacheKey = request.cacheKey
            if memoryCache.object(forKey: cacheKey as NSString) != nil {
                continue
            }
            if prefetchTasks[cacheKey] != nil {
                continue
            }

            prefetchTasks[cacheKey] = Task(priority: ArtworkPipelinePriority.prefetch.taskPriority) { [weak self] in
                _ = await self?.load(
                    request: request,
                    priority: .prefetch,
                    fetchArtwork: fetchArtwork
                )
                await self?.prefetchDidFinish(cacheKey: cacheKey)
            }
        }
    }

    func cancelPrefetches(keeping cacheKeysToKeep: Set<String> = []) {
        let cacheKeysToCancel = prefetchTasks.keys.filter { cacheKeysToKeep.contains($0) == false }
        for cacheKey in cacheKeysToCancel {
            guard let task = prefetchTasks.removeValue(forKey: cacheKey) else {
                continue
            }
            task.cancel()
            if let request = inFlight[cacheKey], request.isPrefetchOnly {
                request.task.cancel()
                inFlight.removeValue(forKey: cacheKey)
            }
        }
    }

    private func prefetchDidFinish(cacheKey: String) {
        prefetchTasks.removeValue(forKey: cacheKey)
    }

    private func performLoad(
        request: ArtworkPipelineRequest,
        priority: ArtworkPipelinePriority,
        fetchArtwork: @escaping FetchArtwork
    ) async -> ArtworkPipelineResult? {
        do {
            try await acquireSlot(priority: priority)
            defer {
                Task { [weak self] in
                    await self?.releaseSlot()
                }
            }

            try Task.checkCancellation()
            let fetched = try await fetchArtwork(
                request.imageKey,
                request.width,
                request.height,
                request.format
            )
            try Task.checkCancellation()
            let decoded = try await Self.decodeImage(
                at: URL(fileURLWithPath: fetched.localURL),
                width: request.width,
                height: request.height,
                priority: priority.taskPriority
            )
            try Task.checkCancellation()
            let image = await MainActor.run {
                NSImage(
                    cgImage: decoded.cgImage,
                    size: NSSize(width: request.width, height: request.height)
                )
            }
            let result = ArtworkPipelineResult(
                image: image,
                decodedPixelCost: decoded.decodedPixelCost
            )
            memoryCache.setObject(
                CacheEntry(result: result),
                forKey: request.cacheKey as NSString,
                cost: decoded.decodedPixelCost
            )
            return result
        } catch is CancellationError {
            return nil
        } catch {
            MacaroonDebugLogger.logError("artwork_pipeline.load_failed", error: error)
            return nil
        }
    }

    private func acquireSlot(priority: ArtworkPipelinePriority) async throws {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }

        nextWaiterID += 1
        nextWaiterSequence += 1
        let waiterID = nextWaiterID
        let sequence = nextWaiterSequence

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(SlotWaiter(
                    id: waiterID,
                    priority: priority,
                    sequence: sequence,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func releaseSlot() {
        guard waiters.isEmpty == false else {
            activeFetches = max(activeFetches - 1, 0)
            return
        }

        let nextIndex = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority.queueRank == right.priority.queueRank {
                return left.sequence < right.sequence
            }
            return left.priority.queueRank < right.priority.queueRank
        }!
        let waiter = waiters.remove(at: nextIndex)
        waiter.continuation.resume()
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private struct DecodedImage: @unchecked Sendable {
        var cgImage: CGImage
        var decodedPixelCost: Int
    }

    private static func decodeImage(
        at url: URL,
        width: Int,
        height: Int,
        priority: TaskPriority
    ) async throws -> DecodedImage {
        try await Task.detached(priority: priority) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw NativeImageError.invalidResponse
            }

            let maxPixelSize = max(width, height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw NativeImageError.invalidResponse
            }

            return DecodedImage(
                cgImage: cgImage,
                decodedPixelCost: max(cgImage.bytesPerRow * cgImage.height, 1)
            )
        }.value
    }
}
