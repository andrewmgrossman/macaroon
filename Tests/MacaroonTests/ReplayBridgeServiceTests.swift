import Foundation
import Testing
@testable import Macaroon

@Suite("ReplayBridgeServiceTests")
struct ReplayBridgeServiceTests {
    @Test
    func loadsLiveCaptureTranscript() throws {
        let transcript = try BridgeReplayTranscript.load(from: fixtureURL())
        #expect(transcript.entries.isEmpty == false)
    }

    @Test
    @MainActor
    func replaysStartupFlowFromLiveCapture() async throws {
        let service = try ReplayBridgeService(transcriptURL: fixtureURL())
        var events: [BridgeEventEnvelope] = []
        service.eventHandler = { message in
            guard case let .event(event) = message else {
                return
            }
            events.append(event)
        }

        try await service.start()

        try await service.send(
            "connect.auto",
            params: ConnectAutoParams(persistedState: persistedState)
        )

        let browseServicesTask = Task { @MainActor in
            try await service.request(
                "browse.services",
                params: EmptyParams(),
                as: BrowseServicesResult.self
            )
        }
        await Task.yield()

        try await service.send("zones.subscribe", params: ZonesSubscribeParams())
        try await service.send(
            "browse.home",
            params: BrowseHomeParams(hierarchy: .albums, zoneOrOutputID: nil)
        )
        try await service.send(
            "queue.subscribe",
            params: QueueSubscribeParams(
                zoneOrOutputID: "1601efbc55143a98dc3a65741915e3f1ff09",
                maxItemCount: 300
            )
        )

        let imageFetchTask = Task { @MainActor in
            try await service.request(
                "image.fetch",
                params: ImageFetchParams(
                    imageKey: "1b6e88d2e47f7f56ed9a2d5696e6b227",
                    width: 104,
                    height: 104,
                    format: "image/jpeg"
                ),
                as: ImageFetchedResult.self
            )
        }
        await Task.yield()

        let browseServices = try await browseServicesTask.value
        let imageResult = try await imageFetchTask.value
        #expect(browseServices.services.contains(where: { $0.title == "TIDAL" }))
        #expect(imageResult.imageKey == "1b6e88d2e47f7f56ed9a2d5696e6b227")

        #expect(events.contains(where: {
            if case let .connectionChanged(event) = $0,
               case let .connected(core) = event.status {
                return core.displayName == "m1mini"
            }
            return false
        }))

        #expect(events.contains(where: {
            if case .zonesSnapshot(let snapshot) = $0 {
                return snapshot.zones.contains(where: { $0.displayName == "MacBook" })
            }
            return false
        }))

        #expect(events.contains(where: {
            if case .browseListChanged(let event) = $0 {
                return event.page.hierarchy == .albums && event.page.list.count == 10906
            }
            return false
        }))

        #expect(events.contains(where: {
            if case .queueSnapshot(let event) = $0 {
                return event.queue?.zoneID == "1601efbc55143a98dc3a65741915e3f1ff09"
            }
            return false
        }))
    }

    private var persistedState: PersistedSessionState {
        PersistedSessionState(
            pairedCoreID: "69a4a691-15ec-459f-94cf-bb35536299cd",
            tokens: ["69a4a691-15ec-459f-94cf-bb35536299cd": "acaea86a-9b80-47d5-9792-a812c078a9a9"],
            endpoints: ["69a4a691-15ec-459f-94cf-bb35536299cd": .init(host: "10.0.7.148", port: 9330)]
        )
    }

    private func fixtureURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Replay")
            .appendingPathComponent("live-core-session-001")
            .appendingPathComponent("bridge-lines.jsonl")
    }
}
