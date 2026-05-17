import AppKit
import Foundation
import Testing
@testable import Macaroon

@Suite("ArtworkPipelineTests")
struct ArtworkPipelineTests {
    @Test
    @MainActor
    func visibleLoadCancelsSaturatedPrefetchWork() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let visibleURL = directory.appendingPathComponent("visible.jpg")
        try makePipelineJPEGData().write(to: visibleURL)

        let pipeline = ArtworkPipeline(maxConcurrentFetches: 1)
        let gate = ArtworkPipelineGate()
        let prefetchRequest = ArtworkPipelineRequest(
            imageKey: "prefetch",
            width: 44,
            height: 44,
            format: "image/jpeg"
        )
        let visibleRequest = ArtworkPipelineRequest(
            imageKey: "visible",
            width: 44,
            height: 44,
            format: "image/jpeg"
        )

        let fetcher: ArtworkPipeline.FetchArtwork = { imageKey, _, _, _ in
            if imageKey == "prefetch" {
                await gate.markPrefetchStarted()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    await gate.markPrefetchCancelled()
                    throw error
                }
            }
            return ImageFetchedResult(imageKey: imageKey, localURL: visibleURL.path)
        }

        await pipeline.prefetch(requests: [prefetchRequest], fetchArtwork: fetcher)
        await gate.waitForPrefetchStarted()

        let visible = await pipeline.load(
            request: visibleRequest,
            priority: .visible,
            fetchArtwork: fetcher
        )

        #expect(visible?.image.isValid == true)
        #expect(await gate.prefetchCancelled == true)
    }

    @Test
    @MainActor
    func cancelledVisibleLoadCancelsInFlightFetchAndFreesSlot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let currentURL = directory.appendingPathComponent("current.jpg")
        try makePipelineJPEGData().write(to: currentURL)

        let pipeline = ArtworkPipeline(maxConcurrentFetches: 1)
        let gate = ArtworkPipelineGate()
        let staleRequest = ArtworkPipelineRequest(
            imageKey: "stale-visible",
            width: 44,
            height: 44,
            format: "image/jpeg"
        )
        let currentRequest = ArtworkPipelineRequest(
            imageKey: "current-visible",
            width: 44,
            height: 44,
            format: "image/jpeg"
        )

        let fetcher: ArtworkPipeline.FetchArtwork = { imageKey, _, _, _ in
            if imageKey == "stale-visible" {
                await gate.markStarted(imageKey)
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    await gate.markCancelled(imageKey)
                    throw error
                }
            }
            return ImageFetchedResult(imageKey: imageKey, localURL: currentURL.path)
        }

        let staleTask = Task {
            await pipeline.load(
                request: staleRequest,
                priority: .visible,
                fetchArtwork: fetcher
            )
        }
        await gate.waitForStarted("stale-visible")

        staleTask.cancel()
        let staleResult = await staleTask.value
        #expect(staleResult == nil)
        #expect(await gate.wasCancelled("stale-visible") == true)

        let current = await pipeline.load(
            request: currentRequest,
            priority: .visible,
            fetchArtwork: fetcher
        )

        #expect(current?.image.isValid == true)
    }
}

private actor ArtworkPipelineGate {
    private var startedKeys: Set<String> = []
    private var startedContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelledKeys: Set<String> = []
    private(set) var prefetchCancelled = false

    func markPrefetchStarted() {
        markStarted("prefetch")
    }

    func waitForPrefetchStarted() async {
        await waitForStarted("prefetch")
    }

    func markStarted(_ key: String) {
        startedKeys.insert(key)
        let continuations = startedContinuations.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForStarted(_ key: String) async {
        if startedKeys.contains(key) {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuations[key, default: []].append(continuation)
        }
    }

    func markPrefetchCancelled() {
        markCancelled("prefetch")
    }

    func markCancelled(_ key: String) {
        cancelledKeys.insert(key)
        if key == "prefetch" {
            prefetchCancelled = true
        }
    }

    func wasCancelled(_ key: String) -> Bool {
        cancelledKeys.contains(key)
    }
}

private func makePipelineJPEGData() -> Data {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
    image.unlockFocus()
    let tiffData = image.tiffRepresentation!
    let representation = NSBitmapImageRep(data: tiffData)!
    return representation.representation(using: .jpeg, properties: [:])!
}
