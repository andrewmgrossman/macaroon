import Foundation
import Testing
@testable import Macaroon

@Suite("WikipediaClientTests")
struct WikipediaClientTests {
    @Test
    func exactArtistMatchIsAccepted() async throws {
        let client = WikipediaClient(
            fetchData: wikipediaFetchDataStub(),
            cacheStore: WikipediaCacheStore(
                directoryURL: tempWikipediaDirectory(),
                ttl: 3600
            )
        )

        let article = try await client.lookupArticle(for: .artist(name: "Nirvana"))

        #expect(article?.pageTitle == "Nirvana")
        #expect(article?.canonicalURL.absoluteString == "https://en.wikipedia.org/wiki/Nirvana_(band)")
    }

    @Test
    func ambiguousCommonWordArtistIsRejected() async throws {
        let client = WikipediaClient(
            fetchData: wikipediaFetchDataStub(),
            cacheStore: WikipediaCacheStore(
                directoryURL: tempWikipediaDirectory(),
                ttl: 3600
            )
        )

        let article = try await client.lookupArticle(for: .artist(name: "Journey"))

        #expect(article == nil)
    }

    @Test
    func artistMatchAllowsLeadingTheDifference() async throws {
        let client = WikipediaClient(
            fetchData: wikipediaFetchDataStub(),
            cacheStore: WikipediaCacheStore(
                directoryURL: tempWikipediaDirectory(),
                ttl: 3600
            )
        )

        let article = try await client.lookupArticle(for: .artist(name: "Beatles"))

        #expect(article?.pageTitle == "The Beatles")
    }

    @Test
    func albumWithMatchingArtistIsAccepted() async throws {
        let client = WikipediaClient(
            fetchData: wikipediaFetchDataStub(),
            cacheStore: WikipediaCacheStore(
                directoryURL: tempWikipediaDirectory(),
                ttl: 3600
            )
        )

        let article = try await client.lookupArticle(for: .album(title: "Sea Change", artist: "Beck"))

        #expect(article?.pageTitle == "Sea Change")
    }

    @Test
    func albumWithWrongArtistIsRejected() async throws {
        let client = WikipediaClient(
            fetchData: wikipediaFetchDataStub(),
            cacheStore: WikipediaCacheStore(
                directoryURL: tempWikipediaDirectory(),
                ttl: 3600
            )
        )

        let article = try await client.lookupArticle(for: .album(title: "Sea Change", artist: "Radiohead"))

        #expect(article == nil)
    }

    @Test
    func cachedHitAvoidsRefetch() async throws {
        let counter = WikipediaLockedCounter()
        let cacheStore = WikipediaCacheStore(
            directoryURL: tempWikipediaDirectory(),
            ttl: 3600
        )
        let client = WikipediaClient(
            fetchData: { url in
                await counter.increment()
                return try await wikipediaFetchDataStub()(url)
            },
            cacheStore: cacheStore
        )

        _ = try await client.lookupArticle(for: .artist(name: "Nirvana"))
        _ = try await client.lookupArticle(for: .artist(name: "Nirvana"))

        #expect(await counter.value == 2)
    }

    @Test
    func negativeLookupIsCached() async throws {
        let counter = WikipediaLockedCounter()
        let cacheStore = WikipediaCacheStore(
            directoryURL: tempWikipediaDirectory(),
            ttl: 3600
        )
        let client = WikipediaClient(
            fetchData: { url in
                await counter.increment()
                return try await wikipediaFetchDataStub()(url)
            },
            cacheStore: cacheStore
        )

        _ = try await client.lookupArticle(for: .artist(name: "Journey"))
        _ = try await client.lookupArticle(for: .artist(name: "Journey"))

        #expect(await counter.value == 2)
    }

    @Test
    func expiredCacheRefetches() async throws {
        let counter = WikipediaLockedCounter()
        let start = Date()
        let clock = WikipediaDateBox(start)
        let cacheStore = WikipediaCacheStore(
            directoryURL: tempWikipediaDirectory(),
            ttl: 60,
            now: { clock.now }
        )
        let client = WikipediaClient(
            fetchData: { url in
                await counter.increment()
                return try await wikipediaFetchDataStub()(url)
            },
            cacheStore: cacheStore
        )

        _ = try await client.lookupArticle(for: WikipediaLookupTarget.artist(name: "Nirvana"))
        clock.advance(by: 120)
        _ = try await client.lookupArticle(for: WikipediaLookupTarget.artist(name: "Nirvana"))

        #expect(await counter.value == 4)
    }
}

private func wikipediaFetchDataStub() -> WikipediaFetchDataClosure {
    { url in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let list = queryItems.first(where: { $0.name == "list" })?.value
        let titles = queryItems.first(where: { $0.name == "titles" })?.value
        let search = queryItems.first(where: { $0.name == "srsearch" })?.value ?? ""

        if list == "search" {
            if search == "\"Beatles\"" {
                return """
                {"query":{"search":[{"title":"The Beatles"}]}}
                """.data(using: .utf8)!
            }

            if search.contains("Nirvana") {
                return """
                {"query":{"search":[{"title":"Nirvana"}]}}
                """.data(using: .utf8)!
            }

            if search.contains("Journey") {
                return """
                {"query":{"search":[{"title":"Journey"}]}}
                """.data(using: .utf8)!
            }

            if search.contains("Sea Change") {
                return """
                {"query":{"search":[{"title":"Sea Change"}]}}
                """.data(using: .utf8)!
            }

            return """
            {"query":{"search":[]}}
            """.data(using: .utf8)!
        }

        switch titles {
        case "Nirvana":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 1,
                    "title": "Nirvana",
                    "fullurl": "https://en.wikipedia.org/wiki/Nirvana_(band)",
                    "extract": "Nirvana was an American rock band formed in Aberdeen, Washington, in 1987. The band consisted of Kurt Cobain, Krist Novoselic and Dave Grohl.",
                    "categories": [
                      { "title": "Category:American rock music groups" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        case "The Beatles":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 4,
                    "title": "The Beatles",
                    "fullurl": "https://en.wikipedia.org/wiki/The_Beatles",
                    "extract": "The Beatles were an English rock band formed in Liverpool in 1960. The core lineup comprised John Lennon, Paul McCartney, George Harrison and Ringo Starr.",
                    "categories": [
                      { "title": "Category:English rock music groups" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        case "Journey":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 3,
                    "title": "Journey",
                    "fullurl": "https://en.wikipedia.org/wiki/Journey",
                    "extract": "Journey is a 1995 travel documentary film about long-distance exploration and migration.",
                    "categories": [
                      { "title": "Category:Documentary films" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        case "Sea Change":
            return """
            {
              "query": {
                "pages": [
                  {
                    "pageid": 2,
                    "title": "Sea Change",
                    "fullurl": "https://en.wikipedia.org/wiki/Sea_Change",
                    "extract": "Sea Change is the eighth studio album by Beck, released in 2002. It marked a shift toward a more introspective style.",
                    "categories": [
                      { "title": "Category:2002 albums" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        default:
            return """
            {"query":{"pages":[]}}
            """.data(using: .utf8)!
        }
    }
}

private func tempWikipediaDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("macaroon-wikipedia-\(UUID().uuidString)", isDirectory: true)
}

actor WikipediaLockedCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class WikipediaDateBox: @unchecked Sendable {
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    var now: Date {
        current
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}
