import CryptoKit
import Foundation

enum WikipediaLookupTarget: Hashable, Codable, Sendable {
    case artist(name: String)
    case album(title: String, artist: String)

    var cacheIdentity: String {
        switch self {
        case let .artist(name):
            "v2|artist|\(name)"
        case let .album(title, artist):
            "v2|album|\(title)|\(artist)"
        }
    }

    var cacheKey: String {
        SHA256.hash(data: Data(cacheIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var searchQuery: String {
        switch self {
        case let .artist(name):
            "\"\(name)\""
        case let .album(title, artist):
            "\"\(title)\" \"\(artist)\" album"
        }
    }
}

struct WikipediaArticle: Codable, Equatable, Sendable {
    var pageTitle: String
    var canonicalURL: URL
    var body: String
    var summary: String?
    var fetchedAt: Date
    var confidence: Double
}

enum WikipediaSectionState: Equatable, Sendable {
    case idle
    case loading
    case loaded(WikipediaArticle)
    case unavailable
    case failed
}

private enum WikipediaCachePayload: Codable, Equatable, Sendable {
    case article(WikipediaArticle)
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case kind
        case article
    }

    private enum Kind: String, Codable {
        case article
        case unavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .article:
            self = .article(try container.decode(WikipediaArticle.self, forKey: .article))
        case .unavailable:
            self = .unavailable
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .article(article):
            try container.encode(Kind.article, forKey: .kind)
            try container.encode(article, forKey: .article)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }
}

private struct WikipediaCacheRecord: Codable, Equatable, Sendable {
    var payload: WikipediaCachePayload
    var fetchedAt: Date
}

actor WikipediaCacheStore {
    static let shared = WikipediaCacheStore()

    private let directoryURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directoryURL: URL? = nil,
        ttl: TimeInterval = 7 * 24 * 60 * 60,
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
                .appendingPathComponent("Wikipedia", isDirectory: true)
        }

        self.directoryURL = baseDirectory
        self.fileManager = fileManager
        self.now = now
        self.ttl = ttl
        encoder.outputFormatting = [.sortedKeys]
    }

    func cachedPayload(for target: WikipediaLookupTarget) throws -> WikipediaSectionState? {
        try prepare()
        let fileURL = cacheFileURL(for: target)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let record = try decoder.decode(WikipediaCacheRecord.self, from: data)
            if now().timeIntervalSince(record.fetchedAt) > ttl {
                try? fileManager.removeItem(at: fileURL)
                return nil
            }

            switch record.payload {
            case let .article(article):
                return .loaded(article)
            case .unavailable:
                return .unavailable
            }
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    func storeArticle(_ article: WikipediaArticle, for target: WikipediaLookupTarget) throws {
        try storeRecord(.init(payload: .article(article), fetchedAt: now()), for: target)
    }

    func storeUnavailable(for target: WikipediaLookupTarget) throws {
        try storeRecord(.init(payload: .unavailable, fetchedAt: now()), for: target)
    }

    func clear() throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try prepare()
    }

    private func prepare() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func storeRecord(_ record: WikipediaCacheRecord, for target: WikipediaLookupTarget) throws {
        try prepare()
        let data = try encoder.encode(record)
        try data.write(to: cacheFileURL(for: target), options: [.atomic])
    }

    private func cacheFileURL(for target: WikipediaLookupTarget) -> URL {
        directoryURL.appendingPathComponent("\(target.cacheKey).json", isDirectory: false)
    }
}

enum WikipediaError: LocalizedError, Equatable, Sendable {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Wikipedia returned an invalid response."
        }
    }
}

typealias WikipediaFetchDataClosure = @Sendable (URL) async throws -> Data

actor WikipediaClient {
    private struct SearchCandidate: Equatable, Sendable {
        var title: String
    }

    private struct CandidateDetails: Equatable, Sendable {
        var title: String
        var canonicalURL: URL
        var extract: String
        var categories: [String]
    }

    private let fetchData: WikipediaFetchDataClosure
    private let cacheStore: WikipediaCacheStore

    init(
        fetchData: WikipediaFetchDataClosure? = nil,
        cacheStore: WikipediaCacheStore = .shared
    ) {
        self.fetchData = fetchData ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw WikipediaError.invalidResponse
            }
            return data
        }
        self.cacheStore = cacheStore
    }

    func lookupArticle(for target: WikipediaLookupTarget) async throws -> WikipediaArticle? {
        if let cached = try await cacheStore.cachedPayload(for: target) {
            switch cached {
            case let .loaded(article):
                return article
            case .unavailable:
                return nil
            case .idle, .loading, .failed:
                break
            }
        }

        let searchCandidates = try await fetchSearchCandidates(for: target)
        let prioritized = prioritize(searchCandidates, for: target)

        for candidate in prioritized.prefix(5) {
            let details = try await fetchDetails(forPageTitle: candidate.title)
            if let article = article(from: details, for: target) {
                try? await cacheStore.storeArticle(article, for: target)
                return article
            }
        }

        try? await cacheStore.storeUnavailable(for: target)
        return nil
    }

    private func fetchSearchCandidates(for target: WikipediaLookupTarget) async throws -> [SearchCandidate] {
        let url = try makeSearchURL(query: target.searchQuery)
        let data = try await fetchData(url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.query.search.map { SearchCandidate(title: $0.title) }
    }

    private func fetchDetails(forPageTitle title: String) async throws -> CandidateDetails {
        let url = try makePageDetailsURL(title: title)
        let data = try await fetchData(url)
        let response = try JSONDecoder().decode(PageDetailsResponse.self, from: data)
        guard let page = response.query.pages.first,
              page.missing != true
        else {
            throw WikipediaError.invalidResponse
        }

        let canonicalURL = page.fullurl ?? Self.fallbackArticleURL(for: page.title)
        let extract = Self.cleanedArticleText(page.extract ?? "")
        let categories = page.categories?.map { Self.cleanedCategoryTitle($0.title) } ?? []

        return CandidateDetails(
            title: page.title,
            canonicalURL: canonicalURL,
            extract: extract,
            categories: categories
        )
    }

    private func article(from details: CandidateDetails, for target: WikipediaLookupTarget) -> WikipediaArticle? {
        let confidence = confidenceScore(for: details, target: target)
        guard confidence >= 0.8, details.extract.isEmpty == false else {
            return nil
        }

        return WikipediaArticle(
            pageTitle: details.title,
            canonicalURL: details.canonicalURL,
            body: details.extract,
            summary: Self.articleSummary(from: details.extract),
            fetchedAt: Date(),
            confidence: confidence
        )
    }

    private func prioritize(_ candidates: [SearchCandidate], for target: WikipediaLookupTarget) -> [SearchCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsExact = Self.normalizedBaseTitle(lhs.title) == Self.normalizedTargetTitle(for: target)
            let rhsExact = Self.normalizedBaseTitle(rhs.title) == Self.normalizedTargetTitle(for: target)
            if lhsExact != rhsExact {
                return lhsExact && !rhsExact
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func confidenceScore(for details: CandidateDetails, target: WikipediaLookupTarget) -> Double {
        switch target {
        case let .artist(name):
            return artistConfidenceScore(details: details, name: name)
        case let .album(title, artist):
            return albumConfidenceScore(details: details, title: title, artist: artist)
        }
    }

    private func artistConfidenceScore(details: CandidateDetails, name: String) -> Double {
        let targetName = Self.normalized(name)
        let targetNameSansArticle = Self.normalizedDroppingLeadingArticle(name)
        let baseTitle = Self.normalizedBaseTitle(details.title)
        let baseTitleSansArticle = Self.normalizedDroppingLeadingArticle(details.title)
        let extract = Self.normalized(details.extract)
        let categories = details.categories.map(Self.normalized)
        let categoryText = categories.joined(separator: " ")

        var score = 0.0

        if baseTitle == targetName || baseTitleSansArticle == targetNameSansArticle {
            score += 0.55
        } else if
            baseTitle.contains(targetName) ||
            targetName.contains(baseTitle) ||
            baseTitleSansArticle.contains(targetNameSansArticle) ||
            targetNameSansArticle.contains(baseTitleSansArticle)
        {
            score += 0.2
        }

        if Self.containsAnyKeyword(in: categoryText, keywords: Self.artistCategoryKeywords) {
            score += 0.3
        }

        if Self.containsAnyKeyword(in: extract, keywords: Self.artistExtractKeywords) {
            score += 0.2
        }

        if
            extract.hasPrefix(targetName) ||
            extract.hasPrefix(targetNameSansArticle) ||
            extract.contains("\(targetName) is") ||
            extract.contains("\(targetNameSansArticle) is") ||
            extract.contains("\(targetName) were") ||
            extract.contains("\(targetNameSansArticle) were")
        {
            score += 0.1
        }

        return min(score, 1.0)
    }

    private func albumConfidenceScore(details: CandidateDetails, title: String, artist: String) -> Double {
        let targetTitle = Self.normalized(title)
        let baseTitle = Self.normalizedBaseTitle(details.title)
        let extract = Self.normalized(details.extract)
        let artistName = Self.normalized(artist)
        let categories = details.categories.map(Self.normalized)
        let categoryText = categories.joined(separator: " ")

        guard extract.contains(artistName) || categoryText.contains(artistName) else {
            return 0
        }

        var score = 0.0

        if baseTitle == targetTitle {
            score += 0.45
        } else if baseTitle.contains(targetTitle) || targetTitle.contains(baseTitle) {
            score += 0.15
        }

        if Self.containsAnyKeyword(in: categoryText, keywords: Self.albumCategoryKeywords) {
            score += 0.2
        }

        if Self.containsAnyKeyword(in: extract, keywords: Self.albumExtractKeywords) {
            score += 0.2
        }

        if extract.contains(artistName) {
            score += 0.25
        }

        if Self.normalized(details.title).contains("(album)") {
            score += 0.1
        }

        return min(score, 1.0)
    }

    private func makeSearchURL(query: String) throws -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query),
            .init(name: "srlimit", value: "5"),
            .init(name: "utf8", value: "1"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2")
        ]
        guard let url = components?.url else {
            throw WikipediaError.invalidResponse
        }
        return url
    }

    private func makePageDetailsURL(title: String) throws -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "prop", value: "extracts|categories|info"),
            .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"),
            .init(name: "cllimit", value: "max"),
            .init(name: "inprop", value: "url"),
            .init(name: "explaintext", value: "1"),
            .init(name: "exsectionformat", value: "plain"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2")
        ]
        guard let url = components?.url else {
            throw WikipediaError.invalidResponse
        }
        return url
    }

    private static func articleSummary(from body: String) -> String? {
        body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    private static func cleanedArticleText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedCategoryTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "Category:", with: "")
    }

    private static func fallbackArticleURL(for title: String) -> URL {
        let escaped = title.replacingOccurrences(of: " ", with: "_")
        return URL(string: "https://en.wikipedia.org/wiki/\(escaped)")!
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBaseTitle(_ value: String) -> String {
        let withoutParenthetical = value.replacingOccurrences(of: "\\s*\\([^\\)]*\\)$", with: "", options: .regularExpression)
        return normalized(withoutParenthetical)
    }

    private static func normalizedDroppingLeadingArticle(_ value: String) -> String {
        let normalizedValue = normalizedBaseTitle(value)
        if normalizedValue.hasPrefix("the ") {
            return String(normalizedValue.dropFirst(4))
        }
        return normalizedValue
    }

    private static func normalizedTargetTitle(for target: WikipediaLookupTarget) -> String {
        switch target {
        case let .artist(name):
            normalized(name)
        case let .album(title, _):
            normalized(title)
        }
    }

    private static func containsAnyKeyword(in value: String, keywords: [String]) -> Bool {
        keywords.contains(where: { value.contains($0) })
    }

    private static let artistCategoryKeywords = [
        "musicians", "music groups", "bands", "singers", "songwriters", "rappers",
        "composers", "record producers", "vocalists", "guitarists", "pianists", "duos", "trios"
    ]

    private static let artistExtractKeywords = [
        " musician", " singer", " songwriter", " rapper", " composer",
        " band", " music group", " rock group", " duo", " trio"
    ]

    private static let albumCategoryKeywords = [
        "albums", "eps", "mixtapes", "soundtrack albums", "live albums", "compilation albums"
    ]

    private static let albumExtractKeywords = [
        " album", " ep", " mixtape", " soundtrack", " live album", " studio album", " compilation album"
    ]
}

private struct SearchResponse: Decodable {
    struct Query: Decodable {
        struct Result: Decodable {
            var title: String
        }

        var search: [Result]
    }

    var query: Query
}

private struct PageDetailsResponse: Decodable {
    struct Query: Decodable {
        struct Page: Decodable {
            struct Category: Decodable {
                var title: String
            }

            var pageid: Int?
            var title: String
            var fullurl: URL?
            var extract: String?
            var categories: [Category]?
            var missing: Bool?
        }

        var pages: [Page]
    }

    var query: Query
}
