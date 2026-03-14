import Foundation
import Testing
@testable import Macaroon

@Suite("NativeBrowseClientTests")
struct NativeBrowseClientTests {
    @Test
    func browseHomeLoadsAlbumsPage() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "0",
                body: Data("""
                {"action":"list","list":{"title":"Albums","count":10906,"level":0,"display_offset":0}}
                """.utf8),
                contentType: "application/json"
            ),
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "1",
                body: Data("""
                {"offset":0,"list":{"title":"Albums","count":10906,"level":0,"display_offset":0},"items":[{"title":"Album A","subtitle":"Artist A","image_key":"image-a","item_key":"350:0","hint":"list"},{"title":"Album B","subtitle":"Artist B","item_key":"350:1","hint":"list"}]}
                """.utf8),
                contentType: "application/json"
            )
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        let result = try await client.home(
            session: session,
            hierarchy: .albums,
            zoneOrOutputID: nil
        )

        #expect(result.page.hierarchy == .albums)
        #expect(result.page.list.title == "Albums")
        #expect(result.page.list.count == 10906)
        #expect(result.page.items.count == 2)
        #expect(result.page.items.first?.title == "Album A")
    }

    @Test
    func browseServicesFiltersLibraryEntries() async throws {
        let transport = MockNativeMooTransport(messages: [
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "0",
                body: Data("""
                {"action":"list","list":{"title":"Browse","count":6,"level":0,"display_offset":0}}
                """.utf8),
                contentType: "application/json"
            ),
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: "1",
                body: Data("""
                {"offset":0,"list":{"title":"Browse","count":6,"level":0,"display_offset":0},"items":[{"title":"Library","item_key":"browse:0","hint":"list"},{"title":"Playlists","item_key":"browse:1","hint":"list"},{"title":"Qobuz","item_key":"browse:2","hint":"list"},{"title":"TIDAL","item_key":"browse:3","hint":"list"}]}
                """.utf8),
                contentType: "application/json"
            )
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        let result = try await client.browseServices(session: session)

        #expect(result.services.map(\.title) == ["Qobuz", "TIDAL"])
    }

    @Test
    func openSearchMatchNavigatesToArtistPage() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Explore","count":1,"level":0,"display_offset":0}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Explore","count":1,"level":0,"display_offset":0},"items":[{"title":"Library","item_key":"library","hint":"list"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"list","list":{"title":"Library","count":1,"level":1,"display_offset":0}}
            """),
            try browseSuccess(requestID: "3", body: """
            {"offset":0,"list":{"title":"Library","count":1,"level":1,"display_offset":0},"items":[{"title":"Search","item_key":"search-prompt","input_prompt":{"prompt":"Search","action":"Go","value":null,"is_password":false}}]}
            """),
            try browseSuccess(requestID: "4", body: """
            {"action":"none"}
            """),
            try browseSuccess(requestID: "5", body: """
            {"offset":0,"list":{"title":"Search","count":2,"level":1,"display_offset":0},"items":[{"title":"Artists","item_key":"artists","hint":"list"},{"title":"Albums","item_key":"albums","hint":"list"}]}
            """),
            try browseSuccess(requestID: "6", body: """
            {"action":"list","list":{"title":"Artists","count":1,"level":2,"display_offset":0}}
            """),
            try browseSuccess(requestID: "7", body: """
            {"offset":0,"list":{"title":"Artists","count":1,"level":2,"display_offset":0},"items":[{"title":"Nirvana","item_key":"nirvana","hint":"list"}]}
            """),
            try browseSuccess(requestID: "8", body: """
            {"action":"list","list":{"title":"Nirvana","count":1,"level":3,"display_offset":0}}
            """),
            try browseSuccess(requestID: "9", body: """
            {"offset":0,"list":{"title":"Nirvana","count":1,"level":3,"display_offset":0},"items":[{"title":"Albums","item_key":"albums-for-artist","hint":"list"}]}
            """)
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        let result = try await client.openSearchMatch(
            session: session,
            query: "nirvana",
            categoryTitle: "Artists",
            matchTitle: "Nirvana",
            zoneOrOutputID: "zone-1"
        )

        #expect(result.page.hierarchy == .search)
        #expect(result.page.list.title == "Nirvana")
        #expect(result.page.items.map(\.title) == ["Albums"])
    }

    @Test
    func openSearchMatchDrillsThroughSingleAlbumRow() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Explore","count":1,"level":0,"display_offset":0}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Explore","count":1,"level":0,"display_offset":0},"items":[{"title":"Library","item_key":"library","hint":"list"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"list","list":{"title":"Library","count":1,"level":1,"display_offset":0}}
            """),
            try browseSuccess(requestID: "3", body: """
            {"offset":0,"list":{"title":"Library","count":1,"level":1,"display_offset":0},"items":[{"title":"Search","item_key":"search-prompt","input_prompt":{"prompt":"Search","action":"Go","value":null,"is_password":false}}]}
            """),
            try browseSuccess(requestID: "4", body: """
            {"action":"none"}
            """),
            try browseSuccess(requestID: "5", body: """
            {"offset":0,"list":{"title":"Search","count":2,"level":1,"display_offset":0},"items":[{"title":"Artists","item_key":"artists","hint":"list"},{"title":"Albums","item_key":"albums","hint":"list"}]}
            """),
            try browseSuccess(requestID: "6", body: """
            {"action":"list","list":{"title":"Albums","count":1,"level":2,"display_offset":0}}
            """),
            try browseSuccess(requestID: "7", body: """
            {"offset":0,"list":{"title":"Albums","count":1,"level":2,"display_offset":0},"items":[{"title":"In Utero","item_key":"in-utero","hint":"list"}]}
            """),
            try browseSuccess(requestID: "8", body: """
            {"action":"list","list":{"title":"Albums","count":1,"level":3,"display_offset":0}}
            """),
            try browseSuccess(requestID: "9", body: """
            {"offset":0,"list":{"title":"Albums","count":1,"level":3,"display_offset":0},"items":[{"title":"In Utero","item_key":"album-detail","hint":"list"}]}
            """),
            try browseSuccess(requestID: "10", body: """
            {"action":"list","list":{"title":"In Utero","count":12,"level":4,"display_offset":0}}
            """),
            try browseSuccess(requestID: "11", body: """
            {"offset":0,"list":{"title":"In Utero","count":12,"level":4,"display_offset":0},"items":[{"title":"Serve the Servants","item_key":"track-1","hint":"action"}]}
            """)
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        let result = try await client.openSearchMatch(
            session: session,
            query: "In Utero",
            categoryTitle: "Albums",
            matchTitle: "In Utero",
            zoneOrOutputID: "zone-1"
        )

        #expect(result.page.hierarchy == .search)
        #expect(result.page.list.title == "In Utero")
        #expect(result.page.items.map(\.title) == ["Serve the Servants"])
    }

    @Test
    func openSearchMatchDecodesPromptWithoutIsPassword() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Explore","count":1,"level":0,"display_offset":0}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Explore","count":1,"level":0,"display_offset":0},"items":[{"title":"Library","item_key":"library","hint":"list"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"list","list":{"title":"Library","count":1,"level":1,"display_offset":0}}
            """),
            try browseSuccess(requestID: "3", body: """
            {"offset":0,"list":{"title":"Library","count":1,"level":1,"display_offset":0},"items":[{"title":"Search","item_key":"search-prompt","input_prompt":{"prompt":"Search","action":"Go"}}]}
            """),
            try browseSuccess(requestID: "4", body: """
            {"action":"none"}
            """),
            try browseSuccess(requestID: "5", body: """
            {"offset":0,"list":{"title":"Search","count":1,"level":1,"display_offset":0},"items":[{"title":"Artists","item_key":"artists","hint":"list"}]}
            """),
            try browseSuccess(requestID: "6", body: """
            {"action":"list","list":{"title":"Artists","count":1,"level":2,"display_offset":0}}
            """),
            try browseSuccess(requestID: "7", body: """
            {"offset":0,"list":{"title":"Artists","count":1,"level":2,"display_offset":0},"items":[{"title":"Nirvana","item_key":"nirvana","hint":"list"}]}
            """),
            try browseSuccess(requestID: "8", body: """
            {"action":"list","list":{"title":"Nirvana","count":1,"level":3,"display_offset":0}}
            """),
            try browseSuccess(requestID: "9", body: """
            {"offset":0,"list":{"title":"Nirvana","count":1,"level":3,"display_offset":0},"items":[{"title":"Albums","item_key":"albums-for-artist","hint":"list"}]}
            """)
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        let result = try await client.openSearchMatch(
            session: session,
            query: "nirvana",
            categoryTitle: "Artists",
            matchTitle: "Nirvana",
            zoneOrOutputID: "zone-1"
        )

        #expect(result.page.list.title == "Nirvana")
    }

    @Test
    func contextActionsUsesSearchSessionAndCleansUp() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Search","count":6,"level":2,"display_offset":0}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Search","count":6,"level":2,"display_offset":0},"items":[{"title":"Nirvana","item_key":"artist-nirvana","hint":"list"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"list","list":{"title":"Play Options","count":1,"level":3,"display_offset":0,"hint":"action_list"}}
            """),
            try browseSuccess(requestID: "3", body: """
            {"offset":0,"list":{"title":"Play Options","count":1,"level":3,"display_offset":0,"hint":"action_list"},"items":[{"title":"Play Now","item_key":"play-now","hint":"action"}]}
            """),
            try browseSuccess(requestID: "4", body: """
            {"action":"none"}
            """)
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        _ = try await client.home(session: session, hierarchy: .search, zoneOrOutputID: "zone-1")
        let menu = try await client.contextActions(
            session: session,
            hierarchy: .search,
            itemKey: "artist-nirvana",
            zoneOrOutputID: "zone-1"
        )

        #expect(menu.title == "Play Options")
        #expect(menu.actions.map(\.title) == ["Play Now"])

        let rawSent = await transport.sentMessages()
        let sent = try rawSent.map { try MooCodec.decodeMessage($0) }
        #expect(sent.count == 5)
        #expect(sent[2].name == "com.roonlabs.browse:1/browse")
        let firstBody = try JSONDecoder().decode(BrowseWireBody.self, from: try #require(sent[2].body))
        #expect(firstBody.hierarchy == "browse")
        #expect(firstBody.multi_session_key == "macaroon-search")
        #expect(firstBody.item_key == "artist-nirvana")

        let cleanupBody = try JSONDecoder().decode(BrowseWireBody.self, from: try #require(sent[4].body))
        #expect(cleanupBody.hierarchy == "browse")
        #expect(cleanupBody.multi_session_key == "macaroon-search")
        #expect(cleanupBody.pop_levels == 1)
    }

    @Test
    func performContextActionIgnoresCleanupFailureAfterSuccessfulAction() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Actions","count":1,"level":2,"display_offset":0,"hint":"action_list"}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Actions","count":1,"level":2,"display_offset":0,"hint":"action_list"},"items":[{"title":"Play Now","item_key":"play-now","hint":"action"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"none"}
            """),
            try MooCodec.encodeMessage(
                verb: .complete,
                name: "NetworkError",
                requestID: "3",
                body: nil,
                contentType: nil
            )
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        try await client.performContextAction(
            session: session,
            hierarchy: .albums,
            itemKey: "album-1",
            zoneOrOutputID: "zone-1",
            contextItemKey: "album-1",
            actionTitle: "Play Now"
        )

        let rawSent = await transport.sentMessages()
        let sent = try rawSent.map { try MooCodec.decodeMessage($0) }
        #expect(sent.count == 4)
        let actionBody = try JSONDecoder().decode(BrowseWireBody.self, from: try #require(sent[2].body))
        #expect(actionBody.item_key == "play-now")
        let cleanupBody = try JSONDecoder().decode(BrowseWireBody.self, from: try #require(sent[3].body))
        #expect(cleanupBody.pop_levels == 2)
    }

    @Test
    func performContextActionUsesPostActionLevelForCleanup() async throws {
        let transport = MockNativeMooTransport(messages: [
            try browseSuccess(requestID: "0", body: """
            {"action":"list","list":{"title":"Beck","count":22,"level":4,"display_offset":0}}
            """),
            try browseSuccess(requestID: "1", body: """
            {"offset":0,"list":{"title":"Beck","count":22,"level":4,"display_offset":0},"items":[{"title":"Colors","item_key":"484:4","hint":"list"}]}
            """),
            try browseSuccess(requestID: "2", body: """
            {"action":"list","list":{"title":"Colors","count":12,"level":5,"display_offset":0}}
            """),
            try browseSuccess(requestID: "3", body: """
            {"offset":0,"list":{"title":"Colors","count":12,"level":5,"display_offset":0},"items":[{"title":"Play Album","item_key":"486:0","hint":"action_list"}]}
            """),
            try browseSuccess(requestID: "4", body: """
            {"action":"list","list":{"title":"Play Album","count":4,"level":6,"display_offset":0,"hint":"action_list"}}
            """),
            try browseSuccess(requestID: "5", body: """
            {"offset":0,"list":{"title":"Play Album","count":4,"level":6,"display_offset":0,"hint":"action_list"},"items":[{"title":"Play Now","item_key":"487:0","hint":"action"}]}
            """),
            try browseSuccess(requestID: "6", body: """
            {"action":"list","list":{"title":"Colors","count":12,"level":5,"display_offset":0}}
            """),
            try browseSuccess(requestID: "7", body: """
            {"action":"list","list":{"title":"Beck","count":22,"level":4,"display_offset":0}}
            """)
        ])

        let session = NativeMooSession(transportFactory: { transport }, currentPairedCoreID: nil)
        try await session.connect(to: RoonCoreEndpoint(host: "10.0.7.148", port: 9330))

        let client = NativeBrowseClient()
        _ = try await client.home(session: session, hierarchy: .search, zoneOrOutputID: "zone-1")

        try await client.performContextAction(
            session: session,
            hierarchy: .search,
            itemKey: "484:4",
            zoneOrOutputID: "zone-1",
            contextItemKey: "484:4",
            actionTitle: "Play Now"
        )

        let rawSent = await transport.sentMessages()
        let sent = try rawSent.map { try MooCodec.decodeMessage($0) }
        #expect(sent.count == 8)
        let cleanupBody = try JSONDecoder().decode(BrowseWireBody.self, from: try #require(sent[7].body))
        #expect(cleanupBody.hierarchy == "browse")
        #expect(cleanupBody.multi_session_key == "macaroon-search")
        #expect(cleanupBody.pop_levels == 1)
    }
}

private func browseSuccess(requestID: String, body: String) throws -> Data {
    try MooCodec.encodeMessage(
        verb: .complete,
        name: "Success",
        requestID: requestID,
        body: Data(body.utf8),
        contentType: "application/json"
    )
}

private struct BrowseWireBody: Decodable {
    var hierarchy: String
    var multi_session_key: String?
    var item_key: String?
    var pop_levels: Int?
}
