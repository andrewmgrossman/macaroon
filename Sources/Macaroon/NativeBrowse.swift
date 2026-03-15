import Foundation

private enum NativeBrowseService {
    static let name = "com.roonlabs.browse:1"
}

private struct NativeBrowseSessionContext: Sendable {
    var requestHierarchy: String
    var multiSessionKey: String?
}

private struct NativeBrowseState: Sendable {
    var list: NativeBrowseListPayload?
    var selectedZoneID: String?
    var requestHierarchy: String
    var multiSessionKey: String?
}

struct NativeBrowseServicesResult: Sendable {
    var services: [BrowseServiceSummary]
}

struct NativeBrowsePageResult: Sendable {
    var hierarchy: BrowseHierarchy
    var page: BrowsePage
}

struct NativeBrowseMutationResult: Sendable {
    var hierarchy: BrowseHierarchy
    var replacedItem: BrowseItem?
    var removedItemKey: String?
    var refreshedPage: BrowsePage?
}

struct NativeBrowseActionMenuResult: Sendable {
    var sessionKey: String
    var title: String
    var actions: [BrowseItem]
}

enum NativeBrowseError: LocalizedError, Equatable, Sendable {
    case missingSession(BrowseHierarchy)
    case browseMessage(String)
    case unsupportedAction(String)

    var errorDescription: String? {
        switch self {
        case let .missingSession(hierarchy):
            return "No browse session exists for \(hierarchy.rawValue)."
        case let .browseMessage(message):
            return message
        case let .unsupportedAction(action):
            return "The native browse client does not support the '\(action)' browse action."
        }
    }
}

actor NativeBrowseClient {
    private var sessions: [BrowseHierarchy: NativeBrowseState] = [:]

    func browseServices(session: NativeMooSession) async throws -> NativeBrowseServicesResult {
        let sessionKey = "macaroon-sidebar-services"
        let items = try await loadBrowseRootItems(
            session: session,
            hierarchy: .browse,
            zoneOrOutputID: nil,
            multiSessionKey: sessionKey
        )

        let excludedTitles = Set([
            "albums",
            "artists",
            "composers",
            "genres",
            "internet radio",
            "library",
            "my live radio",
            "playlists",
            "settings"
        ])

        let services = items
            .filter { $0.item_key != nil }
            .filter {
                excludedTitles.contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == false
            }
            .map { BrowseServiceSummary(title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return NativeBrowseServicesResult(services: services)
    }

    func home(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowsePageResult {
        try await browse(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: nil,
            input: nil,
            popAll: true,
            popLevels: nil,
            refreshList: false
        )
    }

    func open(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?,
        itemKey: String?
    ) async throws -> NativeBrowsePageResult {
        try await browse(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey,
            input: nil,
            popAll: false,
            popLevels: nil,
            refreshList: false
        )
    }

    func openService(
        session: NativeMooSession,
        title: String,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowsePageResult {
        let rootItems = try await loadBrowseRootItems(
            session: session,
            hierarchy: .browse,
            zoneOrOutputID: zoneOrOutputID,
            multiSessionKey: nil
        )

        guard let serviceItem = rootItems.first(where: {
            $0.item_key != nil &&
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }), let itemKey = serviceItem.item_key else {
            throw NativeBrowseError.browseMessage("Browse service '\(title)' was not found.")
        }

        return try await open(
            session: session,
            hierarchy: .browse,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey
        )
    }

    func back(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?,
        levels: Int
    ) async throws -> NativeBrowsePageResult {
        try await browse(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: nil,
            input: nil,
            popAll: false,
            popLevels: levels,
            refreshList: false
        )
    }

    func refresh(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowsePageResult {
        try await browse(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: nil,
            input: nil,
            popAll: false,
            popLevels: nil,
            refreshList: true
        )
    }

    func loadPage(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        offset: Int,
        count: Int
    ) async throws -> NativeBrowsePageResult {
        guard let state = sessions[hierarchy] else {
            throw NativeBrowseError.missingSession(hierarchy)
        }

        let loaded = try await loadRequest(
            session: session,
            options: NativeBrowseLoadRequest(
                hierarchy: state.requestHierarchy,
                offset: offset,
                count: count,
                set_display_offset: offset,
                multi_session_key: state.multiSessionKey
            )
        )

        let list = loaded.list ?? state.list
        let nextState = NativeBrowseState(
            list: list,
            selectedZoneID: state.selectedZoneID,
            requestHierarchy: state.requestHierarchy,
            multiSessionKey: state.multiSessionKey
        )
        sessions[hierarchy] = nextState

        return NativeBrowsePageResult(
            hierarchy: hierarchy,
            page: toBrowsePage(
                hierarchy: hierarchy,
                list: try require(list),
                items: loaded.items ?? [],
                offset: loaded.offset ?? offset,
                selectedZoneID: state.selectedZoneID
            )
        )
    }

    func submitInput(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        itemKey: String,
        input: String,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowseMutationResult {
        try await browseMutation(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey,
            input: input,
            popAll: false,
            popLevels: nil,
            refreshList: false
        )
    }

    func openSearchMatch(
        session: NativeMooSession,
        query: String,
        categoryTitle: String,
        matchTitle: String,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowsePageResult {
        let hierarchy = BrowseHierarchy.search
        let context = sessionContext(for: hierarchy)
        let rootItems = try await loadBrowseRootItems(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            multiSessionKey: context.multiSessionKey
        )

        guard let libraryItemKey = rootItems.first(where: {
            $0.item_key != nil &&
            $0.title.localizedCaseInsensitiveCompare("Library") == .orderedSame
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Library search entry was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: libraryItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let promptPage = try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
        guard let promptItemKey = (promptPage.items ?? []).first(where: {
            guard let prompt = $0.input_prompt?.prompt else {
                return false
            }
            return prompt.isEmpty == false
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Search prompt was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: promptItemKey,
                input: query,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let resultsPage = try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
        guard let categoryItemKey = (resultsPage.items ?? []).first(where: {
            $0.item_key != nil &&
            $0.title.localizedCaseInsensitiveCompare(categoryTitle) == .orderedSame
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Search category '\(categoryTitle)' was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: categoryItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let categoryPage = try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
        guard let matchedItemKey = (
            (categoryPage.items ?? []).first(where: {
                $0.item_key != nil &&
                $0.title.localizedCaseInsensitiveCompare(matchTitle) == .orderedSame
            })?.item_key ??
            (categoryPage.items ?? []).first(where: { $0.item_key != nil })?.item_key
        ) else {
            throw NativeBrowseError.browseMessage("No search result was available for '\(matchTitle)'.")
        }

        var result = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: matchedItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        if categoryTitle.localizedCaseInsensitiveCompare("Albums") == .orderedSame,
           let drilledItemKey = try await singleExactMatchItem(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey,
            matchTitle: matchTitle
           )?.item_key {
            result = try await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: context.requestHierarchy,
                    multi_session_key: context.multiSessionKey,
                    item_key: drilledItemKey,
                    input: nil,
                    zone_or_output_id: zoneOrOutputID,
                    pop_all: nil,
                    pop_levels: nil,
                    refresh_list: nil
                )
            )
        }

        return try await activateBrowseResult(
            session: session,
            hierarchy: hierarchy,
            result: result,
            zoneOrOutputID: zoneOrOutputID,
            requestHierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
    }

    func searchSections(
        session: NativeMooSession,
        query: String,
        zoneOrOutputID: String?
    ) async throws -> SearchResultsPage {
        let previousSearchState = sessions[.search]
        defer { sessions[.search] = previousSearchState }

        let context = NativeBrowseSessionContext(
            requestHierarchy: "browse",
            multiSessionKey: "macaroon-search-results"
        )
        let resultsPage = try await prepareSearchResultsSession(
            session: session,
            query: query,
            zoneOrOutputID: zoneOrOutputID,
            context: context
        )

        sessions[.search] = NativeBrowseState(
            list: resultsPage.list,
            selectedZoneID: zoneOrOutputID,
            requestHierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )

        var sections: [SearchResultsSection] = []
        for kind in SearchResultsSectionKind.allCases {
            guard let categoryItemKey = (resultsPage.items ?? []).first(where: {
                $0.item_key != nil &&
                $0.title.localizedCaseInsensitiveCompare(kind.title) == .orderedSame
            })?.item_key else {
                continue
            }

            _ = try await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: context.requestHierarchy,
                    multi_session_key: context.multiSessionKey,
                    item_key: categoryItemKey,
                    input: nil,
                    zone_or_output_id: zoneOrOutputID,
                    pop_all: nil,
                    pop_levels: nil,
                    refresh_list: nil
                )
            )

            let categoryPage = try await loadAllCurrentSessionItems(
                session: session,
                hierarchy: context.requestHierarchy,
                multiSessionKey: context.multiSessionKey
            )

            let items = (categoryPage.items ?? []).map(toBrowseItem)
            if items.isEmpty == false {
                sections.append(SearchResultsSection(kind: kind, items: items))
            }

            _ = try? await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: context.requestHierarchy,
                    multi_session_key: context.multiSessionKey,
                    item_key: nil,
                    input: nil,
                    zone_or_output_id: nil,
                    pop_all: nil,
                    pop_levels: 1,
                    refresh_list: nil
                )
            )
        }

        return SearchResultsPage(
            query: query,
            topHit: (resultsPage.items ?? []).first.map(toBrowseItem),
            sections: sections
        )
    }

    func performSearchMatchAction(
        session: NativeMooSession,
        query: String,
        categoryTitle: String,
        matchTitle: String,
        preferredActionTitles: [String],
        zoneOrOutputID: String?
    ) async throws {
        let previousSearchState = sessions[.search]
        defer { sessions[.search] = previousSearchState }

        let context = NativeBrowseSessionContext(
            requestHierarchy: "browse",
            multiSessionKey: "macaroon-search-action"
        )
        let resultsPage = try await prepareSearchResultsSession(
            session: session,
            query: query,
            zoneOrOutputID: zoneOrOutputID,
            context: context
        )

        guard let categoryItemKey = (resultsPage.items ?? []).first(where: {
            $0.item_key != nil &&
            $0.title.localizedCaseInsensitiveCompare(categoryTitle) == .orderedSame
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Search category '\(categoryTitle)' was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: categoryItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        var categoryPage = try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
        var actionContextItemKey = (
            (categoryPage.items ?? []).first(where: {
                $0.item_key != nil &&
                $0.title.localizedCaseInsensitiveCompare(matchTitle) == .orderedSame
            })?.item_key ??
            (categoryPage.items ?? []).first(where: { $0.item_key != nil })?.item_key
        )
        guard actionContextItemKey != nil else {
            throw NativeBrowseError.browseMessage("No search result was available for '\(matchTitle)'.")
        }

        if categoryTitle.localizedCaseInsensitiveCompare("Albums") == .orderedSame {
            let drilledKey = try await drillToAlbumPlaybackItemKey(
                session: session,
                hierarchy: context.requestHierarchy,
                multiSessionKey: context.multiSessionKey,
                zoneOrOutputID: zoneOrOutputID,
                matchTitle: matchTitle,
                categoryPage: &categoryPage,
                initialItemKey: actionContextItemKey
            )
            actionContextItemKey = drilledKey
        }

        sessions[.search] = NativeBrowseState(
            list: categoryPage.list,
            selectedZoneID: zoneOrOutputID,
            requestHierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )

        let actionTitle = preferredActionTitles.first ?? "Play Now"
        try await performResolvedContextAction(
            session: session,
            hierarchy: .search,
            contextItemKey: try require(actionContextItemKey),
            actionTitle: actionTitle,
            zoneOrOutputID: zoneOrOutputID
        )
    }

    func contextActions(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        itemKey: String,
        zoneOrOutputID: String?
    ) async throws -> NativeBrowseActionMenuResult {
        let context = sessionContext(for: hierarchy)
        let resolved = try await resolveActionsInCurrentSession(
            session: session,
            hierarchy: hierarchy,
            itemKey: itemKey,
            zoneOrOutputID: zoneOrOutputID
        )

        let result = NativeBrowseActionMenuResult(
            sessionKey: "\(hierarchy.rawValue):\(itemKey)",
            title: resolved.title,
            actions: resolved.actions.map(toBrowseItem)
        )

        if resolved.popLevels > 0 {
            _ = try? await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: context.requestHierarchy,
                    multi_session_key: context.multiSessionKey,
                    item_key: nil,
                    input: nil,
                    zone_or_output_id: nil,
                    pop_all: nil,
                    pop_levels: resolved.popLevels,
                    refresh_list: nil
                )
            )
        }

        return result
    }

    func performContextAction(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        itemKey: String,
        zoneOrOutputID: String?,
        contextItemKey: String?,
        actionTitle: String?
    ) async throws {
        if let contextItemKey, let actionTitle {
            try await performResolvedContextAction(
                session: session,
                hierarchy: hierarchy,
                contextItemKey: contextItemKey,
                actionTitle: actionTitle,
                zoneOrOutputID: zoneOrOutputID
            )
            return
        }

        let context = sessionContext(for: hierarchy)
        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: itemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )
    }

    private func browse(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?,
        itemKey: String?,
        input: String?,
        popAll: Bool,
        popLevels: Int?,
        refreshList: Bool
    ) async throws -> NativeBrowsePageResult {
        let mutation = try await browseMutation(
            session: session,
            hierarchy: hierarchy,
            zoneOrOutputID: zoneOrOutputID,
            itemKey: itemKey,
            input: input,
            popAll: popAll,
            popLevels: popLevels,
            refreshList: refreshList
        )

        if let page = mutation.refreshedPage {
            return NativeBrowsePageResult(hierarchy: hierarchy, page: page)
        }
        throw NativeBrowseError.unsupportedAction("none")
    }

    private func browseMutation(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?,
        itemKey: String?,
        input: String?,
        popAll: Bool,
        popLevels: Int?,
        refreshList: Bool
    ) async throws -> NativeBrowseMutationResult {
        let context = sessionContext(for: hierarchy)
        let result = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: itemKey,
                input: input,
                zone_or_output_id: zoneOrOutputID,
                pop_all: popAll ? true : nil,
                pop_levels: popLevels,
                refresh_list: refreshList ? true : nil
            )
        )

        switch result.action {
        case "message":
            throw NativeBrowseError.browseMessage(result.message ?? "Browse request failed.")
        case "replace_item":
            let replacedItem = result.item.map(toBrowseItem)
            let refreshedPage = input == nil ? nil : try await refreshCurrentBrowsePage(
                session: session,
                hierarchy: hierarchy
            )
            return NativeBrowseMutationResult(
                hierarchy: hierarchy,
                replacedItem: replacedItem,
                removedItemKey: nil,
                refreshedPage: refreshedPage
            )
        case "remove_item":
            let refreshedPage = input == nil ? nil : try await refreshCurrentBrowsePage(
                session: session,
                hierarchy: hierarchy
            )
            return NativeBrowseMutationResult(
                hierarchy: hierarchy,
                replacedItem: nil,
                removedItemKey: itemKey,
                refreshedPage: refreshedPage
            )
        case "list":
            let offset = max(result.list?.display_offset ?? 0, 0)
            sessions[hierarchy] = NativeBrowseState(
                list: result.list,
                selectedZoneID: zoneOrOutputID,
                requestHierarchy: context.requestHierarchy,
                multiSessionKey: context.multiSessionKey
            )
            let page = try await loadPage(
                session: session,
                hierarchy: hierarchy,
                offset: offset,
                count: 100
            )
            return NativeBrowseMutationResult(
                hierarchy: hierarchy,
                replacedItem: nil,
                removedItemKey: nil,
                refreshedPage: page.page
            )
        case "none":
            if input != nil {
                return NativeBrowseMutationResult(
                    hierarchy: hierarchy,
                    replacedItem: nil,
                    removedItemKey: nil,
                    refreshedPage: try await refreshCurrentBrowsePage(session: session, hierarchy: hierarchy)
                )
            }
            throw NativeBrowseError.unsupportedAction("none")
        default:
            throw NativeBrowseError.unsupportedAction(result.action)
        }
    }

    private func refreshCurrentBrowsePage(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy
    ) async throws -> BrowsePage {
        guard let state = sessions[hierarchy], let list = state.list else {
            throw NativeBrowseError.missingSession(hierarchy)
        }
        let offset = max(list.display_offset ?? 0, 0)
        return try await loadPage(session: session, hierarchy: hierarchy, offset: offset, count: 100).page
    }

    private func prepareSearchResultsSession(
        session: NativeMooSession,
        query: String,
        zoneOrOutputID: String?,
        context: NativeBrowseSessionContext
    ) async throws -> NativeBrowseLoadPayload {
        let rootItems = try await loadBrowseRootItems(
            session: session,
            hierarchy: .search,
            zoneOrOutputID: zoneOrOutputID,
            multiSessionKey: context.multiSessionKey
        )

        guard let libraryItemKey = rootItems.first(where: {
            $0.item_key != nil &&
            $0.title.localizedCaseInsensitiveCompare("Library") == .orderedSame
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Library search entry was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: libraryItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let promptPage = try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
        guard let promptItemKey = (promptPage.items ?? []).first(where: {
            guard let prompt = $0.input_prompt?.prompt else {
                return false
            }
            return prompt.isEmpty == false
        })?.item_key else {
            throw NativeBrowseError.browseMessage("Search prompt was not available.")
        }

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: promptItemKey,
                input: query,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        return try await loadCurrentSessionItems(
            session: session,
            hierarchy: context.requestHierarchy,
            multiSessionKey: context.multiSessionKey
        )
    }

    private func loadCurrentSessionItems(
        session: NativeMooSession,
        hierarchy: String,
        multiSessionKey: String?
    ) async throws -> NativeBrowseLoadPayload {
        try await loadRequest(
            session: session,
            options: NativeBrowseLoadRequest(
                hierarchy: hierarchy,
                offset: 0,
                count: 100,
                set_display_offset: 0,
                multi_session_key: multiSessionKey
            )
        )
    }

    private func loadAllCurrentSessionItems(
        session: NativeMooSession,
        hierarchy: String,
        multiSessionKey: String?
    ) async throws -> NativeBrowseLoadPayload {
        let initial = try await loadCurrentSessionItems(
            session: session,
            hierarchy: hierarchy,
            multiSessionKey: multiSessionKey
        )

        guard let list = initial.list else {
            return initial
        }

        var mergedItems = initial.items ?? []
        let totalCount = list.count
        guard mergedItems.count < totalCount else {
            return initial
        }

        var nextOffset = mergedItems.count
        while nextOffset < totalCount {
            let loaded = try await loadRequest(
                session: session,
                options: NativeBrowseLoadRequest(
                    hierarchy: hierarchy,
                    offset: nextOffset,
                    count: min(100, totalCount - nextOffset),
                    set_display_offset: nextOffset,
                    multi_session_key: multiSessionKey
                )
            )
            mergedItems.append(contentsOf: loaded.items ?? [])
            nextOffset = mergedItems.count
        }

        return NativeBrowseLoadPayload(
            items: mergedItems,
            offset: initial.offset,
            list: list
        )
    }

    private func drillToAlbumPlaybackItemKey(
        session: NativeMooSession,
        hierarchy: String,
        multiSessionKey: String?,
        zoneOrOutputID: String?,
        matchTitle: String,
        categoryPage: inout NativeBrowseLoadPayload,
        initialItemKey: String?
    ) async throws -> String? {
        guard let initialItemKey else {
            return nil
        }

        func exactMatchKey(in page: NativeBrowseLoadPayload, title: String) -> String? {
            (page.items ?? []).first(where: {
                $0.item_key != nil &&
                $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
            })?.item_key
        }

        var currentItemKey = initialItemKey
        var drilledPage = categoryPage

        if let candidateKey = exactMatchKey(in: drilledPage, title: matchTitle), candidateKey != currentItemKey {
            currentItemKey = candidateKey
        }

        for _ in 0..<2 {
            _ = try await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: hierarchy,
                    multi_session_key: multiSessionKey,
                    item_key: currentItemKey,
                    input: nil,
                    zone_or_output_id: zoneOrOutputID,
                    pop_all: nil,
                    pop_levels: nil,
                    refresh_list: nil
                )
            )

            drilledPage = try await loadCurrentSessionItems(
                session: session,
                hierarchy: hierarchy,
                multiSessionKey: multiSessionKey
            )

            if let playAlbumKey = (drilledPage.items ?? []).first(where: {
                $0.item_key != nil &&
                $0.title.localizedCaseInsensitiveCompare("Play Album") == .orderedSame
            })?.item_key {
                categoryPage = drilledPage
                return playAlbumKey
            }

            guard let candidateKey = exactMatchKey(in: drilledPage, title: matchTitle),
                  candidateKey != currentItemKey else {
                break
            }
            currentItemKey = candidateKey
        }

        categoryPage = drilledPage
        return currentItemKey
    }

    private func singleExactMatchItem(
        session: NativeMooSession,
        hierarchy: String,
        multiSessionKey: String?,
        matchTitle: String
    ) async throws -> NativeBrowseItemPayload? {
        let page = try await loadCurrentSessionItems(
            session: session,
            hierarchy: hierarchy,
            multiSessionKey: multiSessionKey
        )
        let candidates = (page.items ?? []).filter { $0.item_key != nil }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }

        guard candidate.title.localizedCaseInsensitiveCompare(matchTitle) == .orderedSame else {
            return nil
        }

        return candidate
    }

    private func activateBrowseResult(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        result: NativeBrowseActionPayload,
        zoneOrOutputID: String?,
        requestHierarchy: String,
        multiSessionKey: String?
    ) async throws -> NativeBrowsePageResult {
        if result.action == "message" {
            throw NativeBrowseError.browseMessage(result.message ?? "Browse request failed.")
        }
        guard result.action == "list" else {
            throw NativeBrowseError.browseMessage("Browse request did not produce a list.")
        }

        let offset = max(result.list?.display_offset ?? 0, 0)
        sessions[hierarchy] = NativeBrowseState(
            list: result.list,
            selectedZoneID: zoneOrOutputID,
            requestHierarchy: requestHierarchy,
            multiSessionKey: multiSessionKey
        )

        return try await loadPage(
            session: session,
            hierarchy: hierarchy,
            offset: offset,
            count: 100
        )
    }

    private func resolveActionsInCurrentSession(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        itemKey: String,
        zoneOrOutputID: String?
    ) async throws -> ResolvedBrowseActions {
        let state = sessions[hierarchy]
        let context = currentSessionContext(for: hierarchy)
        let baselineLevel = state?.list?.level ?? 0

        let topLevelResult = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: itemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let topLevelList = try await resolveListForSession(
            session: session,
            hierarchy: hierarchy,
            result: topLevelResult,
            zoneOrOutputID: zoneOrOutputID
        )

        if topLevelList.list.hint == "action_list" {
            return ResolvedBrowseActions(
                title: topLevelList.list.title,
                actions: topLevelList.items,
                popLevels: max(topLevelList.list.level - baselineLevel, 0)
            )
        }

        guard let actionListItemKey = topLevelList.items.first(where: { $0.hint == "action_list" })?.item_key else {
            throw NativeBrowseError.browseMessage("No action list available for the selected item.")
        }

        let actionsResult = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: actionListItemKey,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: nil,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let actionsList = try await resolveListForSession(
            session: session,
            hierarchy: hierarchy,
            result: actionsResult,
            zoneOrOutputID: zoneOrOutputID
        )

        return ResolvedBrowseActions(
            title: actionsList.list.title,
            actions: actionsList.items,
            popLevels: max(actionsList.list.level - baselineLevel, 0)
        )
    }

    private func resolveListForSession(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        result: NativeBrowseActionPayload,
        zoneOrOutputID: String?
    ) async throws -> ResolvedBrowseList {
        let state = sessions[hierarchy]
        let context = sessionContext(for: hierarchy)

        if result.action == "message" {
            throw NativeBrowseError.browseMessage(result.message ?? "Browse request failed.")
        }
        guard result.action == "list", let resultList = result.list else {
            throw NativeBrowseError.browseMessage("Browse request did not return a list.")
        }

        let offset = max(resultList.display_offset ?? 0, 0)
        let loaded = try await loadRequest(
            session: session,
            options: NativeBrowseLoadRequest(
                hierarchy: state?.requestHierarchy ?? context.requestHierarchy,
                offset: offset,
                count: 100,
                set_display_offset: offset,
                multi_session_key: state?.multiSessionKey ?? context.multiSessionKey
            )
        )

        return ResolvedBrowseList(
            list: loaded.list ?? resultList,
            items: loaded.items ?? [],
            selectedZoneID: zoneOrOutputID
        )
    }

    private func performResolvedContextAction(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        contextItemKey: String,
        actionTitle: String,
        zoneOrOutputID: String?
    ) async throws {
        let context = currentSessionContext(for: hierarchy)
        let baselineLevel = sessions[hierarchy]?.list?.level ?? 0
        let resolved = try await resolveActionsInCurrentSession(
            session: session,
            hierarchy: hierarchy,
            itemKey: contextItemKey,
            zoneOrOutputID: zoneOrOutputID
        )

        var actionError: Error?
        var cleanupLevels = resolved.popLevels
        do {
            guard let actionItemKey = resolved.actions.first(where: {
                $0.title.localizedCaseInsensitiveCompare(actionTitle) == .orderedSame
            })?.item_key else {
                throw NativeBrowseError.browseMessage("The action \"\(actionTitle)\" is no longer available for this item.")
            }

            let actionResult = try await browseRequest(
                session: session,
                options: NativeBrowseRequest(
                    hierarchy: context.requestHierarchy,
                    multi_session_key: context.multiSessionKey,
                    item_key: actionItemKey,
                    input: nil,
                    zone_or_output_id: zoneOrOutputID,
                    pop_all: nil,
                    pop_levels: nil,
                    refresh_list: nil
                )
            )

            if actionResult.action == "list", let list = actionResult.list {
                cleanupLevels = max(list.level - baselineLevel, 0)
            }
        } catch {
            actionError = error
        }

        if cleanupLevels > 0 {
            do {
                _ = try await browseRequest(
                    session: session,
                    options: NativeBrowseRequest(
                        hierarchy: context.requestHierarchy,
                        multi_session_key: context.multiSessionKey,
                        item_key: nil,
                        input: nil,
                        zone_or_output_id: nil,
                        pop_all: nil,
                        pop_levels: cleanupLevels,
                        refresh_list: nil
                    )
                )
            } catch {
                if actionError != nil {
                    throw error
                }
            }
        }

        if let actionError {
            throw actionError
        }
    }

    private func loadBrowseRootItems(
        session: NativeMooSession,
        hierarchy: BrowseHierarchy,
        zoneOrOutputID: String?,
        multiSessionKey: String?
    ) async throws -> [NativeBrowseItemPayload] {
        let context = NativeBrowseSessionContext(
            requestHierarchy: hierarchy == .search ? "browse" : hierarchy.rawValue,
            multiSessionKey: multiSessionKey
        )

        _ = try await browseRequest(
            session: session,
            options: NativeBrowseRequest(
                hierarchy: context.requestHierarchy,
                multi_session_key: context.multiSessionKey,
                item_key: nil,
                input: nil,
                zone_or_output_id: zoneOrOutputID,
                pop_all: true,
                pop_levels: nil,
                refresh_list: nil
            )
        )

        let loaded = try await loadRequest(
            session: session,
            options: NativeBrowseLoadRequest(
                hierarchy: context.requestHierarchy,
                offset: 0,
                count: 100,
                set_display_offset: 0,
                multi_session_key: context.multiSessionKey
            )
        )

        return loaded.items ?? []
    }

    private func sessionContext(for hierarchy: BrowseHierarchy) -> NativeBrowseSessionContext {
        if hierarchy == .search {
            return NativeBrowseSessionContext(requestHierarchy: "browse", multiSessionKey: "macaroon-search")
        }
        return NativeBrowseSessionContext(requestHierarchy: hierarchy.rawValue, multiSessionKey: nil)
    }

    private func currentSessionContext(for hierarchy: BrowseHierarchy) -> NativeBrowseSessionContext {
        if let state = sessions[hierarchy] {
            return NativeBrowseSessionContext(
                requestHierarchy: state.requestHierarchy,
                multiSessionKey: state.multiSessionKey
            )
        }
        return sessionContext(for: hierarchy)
    }

    private func browseRequest(
        session: NativeMooSession,
        options: NativeBrowseRequest
    ) async throws -> NativeBrowseActionPayload {
        let message = try await session.request("\(NativeBrowseService.name)/browse", body: options)
        guard message.name == "Success" else {
            throw NativeBrowseError.browseMessage(message.name)
        }
        return try decodeBody(NativeBrowseActionPayload.self, from: message)
    }

    private func loadRequest(
        session: NativeMooSession,
        options: NativeBrowseLoadRequest
    ) async throws -> NativeBrowseLoadPayload {
        let message = try await session.request("\(NativeBrowseService.name)/load", body: options)
        guard message.name == "Success" else {
            throw NativeBrowseError.browseMessage(message.name)
        }
        return try decodeBody(NativeBrowseLoadPayload.self, from: message)
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, from message: MooMessageEnvelope) throws -> T {
        guard let body = message.body else {
            throw NativeSessionError.emptyResponse
        }
        return try JSONDecoder().decode(T.self, from: body)
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NativeSessionError.emptyResponse
        }
        return value
    }

    private func toBrowsePage(
        hierarchy: BrowseHierarchy,
        list: NativeBrowseListPayload,
        items: [NativeBrowseItemPayload],
        offset: Int,
        selectedZoneID: String?
    ) -> BrowsePage {
        BrowsePage(
            hierarchy: hierarchy,
            list: BrowseList(
                title: list.title,
                subtitle: list.subtitle,
                count: list.count,
                level: list.level,
                displayOffset: list.display_offset ?? 0,
                hint: list.hint,
                imageKey: list.image_key
            ),
            items: items.map(toBrowseItem),
            offset: offset,
            selectedZoneID: selectedZoneID
        )
    }

    private func toBrowseItem(_ item: NativeBrowseItemPayload) -> BrowseItem {
        let lines = browseLines(for: item)
        return BrowseItem(
            title: lines.title,
            subtitle: lines.subtitle,
            imageKey: item.image_key,
            itemKey: item.item_key,
            hint: item.hint,
            inputPrompt: item.input_prompt.map {
                BrowsePrompt(
                    prompt: $0.prompt,
                    action: $0.action,
                    value: $0.value,
                    isPassword: $0.is_password
                )
            },
            detail: lines.detail,
            length: item.length ?? item.duration
        )
    }

    private func browseLines(for item: NativeBrowseItemPayload) -> (title: String, subtitle: String?, detail: String?) {
        if let threeLine = item.three_line {
            return (
                title: threeLine.line1 ?? item.title,
                subtitle: threeLine.line2 ?? item.subtitle,
                detail: threeLine.line3
            )
        }

        if let twoLine = item.two_line {
            return (
                title: twoLine.line1 ?? item.title,
                subtitle: twoLine.line2 ?? item.subtitle,
                detail: item.detail
            )
        }

        if let oneLine = item.one_line {
            return (
                title: oneLine.line1 ?? item.title,
                subtitle: item.subtitle,
                detail: item.detail
            )
        }

        return (item.title, item.subtitle, item.detail)
    }
}

private struct ResolvedBrowseList: Sendable {
    var list: NativeBrowseListPayload
    var items: [NativeBrowseItemPayload]
    var selectedZoneID: String?
}

private struct ResolvedBrowseActions: Sendable {
    var title: String
    var actions: [NativeBrowseItemPayload]
    var popLevels: Int
}

private struct NativeBrowseRequest: Codable {
    var hierarchy: String
    var multi_session_key: String?
    var item_key: String?
    var input: String?
    var zone_or_output_id: String?
    var pop_all: Bool?
    var pop_levels: Int?
    var refresh_list: Bool?
}

private struct NativeBrowseLoadRequest: Codable {
    var hierarchy: String
    var offset: Int
    var count: Int
    var set_display_offset: Int?
    var multi_session_key: String?
}

private struct NativeBrowseActionPayload: Codable {
    var action: String
    var item: NativeBrowseItemPayload?
    var list: NativeBrowseListPayload?
    var message: String?
    var is_error: Bool?
}

private struct NativeBrowseLoadPayload: Codable {
    var items: [NativeBrowseItemPayload]?
    var offset: Int?
    var list: NativeBrowseListPayload?
}

private struct NativeBrowseListPayload: Codable, Sendable {
    var title: String
    var subtitle: String?
    var count: Int
    var level: Int
    var display_offset: Int?
    var hint: String?
    var image_key: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case count
        case level
        case display_offset
        case hint
        case image_key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeLossyStringIfPresent(forKey: .title) ?? ""
        subtitle = try container.decodeLossyStringIfPresent(forKey: .subtitle)
        count = try container.decodeLossyIntIfPresent(forKey: .count) ?? 0
        level = try container.decodeLossyIntIfPresent(forKey: .level) ?? 0
        display_offset = try container.decodeLossyIntIfPresent(forKey: .display_offset)
        hint = try container.decodeLossyStringIfPresent(forKey: .hint)
        image_key = try container.decodeLossyStringIfPresent(forKey: .image_key)
    }
}

private struct NativeBrowseItemPayload: Codable, Sendable {
    var title: String
    var subtitle: String?
    var detail: String?
    var image_key: String?
    var item_key: String?
    var hint: String?
    var input_prompt: NativeBrowsePromptPayload?
    var one_line: NativeBrowseOneLine?
    var two_line: NativeBrowseTwoLine?
    var three_line: NativeBrowseThreeLine?
    var length: Double?
    var duration: Double?

    private enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case detail
        case image_key
        case item_key
        case hint
        case input_prompt
        case one_line
        case two_line
        case three_line
        case length
        case duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeLossyStringIfPresent(forKey: .title) ?? ""
        subtitle = try container.decodeLossyStringIfPresent(forKey: .subtitle)
        detail = try container.decodeLossyStringIfPresent(forKey: .detail)
        image_key = try container.decodeLossyStringIfPresent(forKey: .image_key)
        item_key = try container.decodeLossyStringIfPresent(forKey: .item_key)
        hint = try container.decodeLossyStringIfPresent(forKey: .hint)
        input_prompt = try container.decodeIfPresent(NativeBrowsePromptPayload.self, forKey: .input_prompt)
        one_line = try container.decodeIfPresent(NativeBrowseOneLine.self, forKey: .one_line)
        two_line = try container.decodeIfPresent(NativeBrowseTwoLine.self, forKey: .two_line)
        three_line = try container.decodeIfPresent(NativeBrowseThreeLine.self, forKey: .three_line)
        length = try container.decodeLossyDoubleIfPresent(forKey: .length)
        duration = try container.decodeLossyDoubleIfPresent(forKey: .duration)
    }
}

private struct NativeBrowseOneLine: Codable, Sendable {
    var line1: String?
}

private struct NativeBrowseTwoLine: Codable, Sendable {
    var line1: String?
    var line2: String?
}

private struct NativeBrowseThreeLine: Codable, Sendable {
    var line1: String?
    var line2: String?
    var line3: String?
}

private struct NativeBrowsePromptPayload: Codable, Sendable {
    var prompt: String
    var action: String
    var value: String?
    var is_password: Bool

    private enum CodingKeys: String, CodingKey {
        case prompt
        case action
        case value
        case is_password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeLossyStringIfPresent(forKey: .prompt) ?? ""
        action = try container.decodeLossyStringIfPresent(forKey: .action) ?? "Go"
        value = try container.decodeLossyStringIfPresent(forKey: .value)
        is_password = try container.decodeIfPresent(Bool.self, forKey: .is_password) ?? false
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key) else {
            return nil
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return String(intValue)
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return String(doubleValue)
        }
        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key) else {
            return nil
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return intValue
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return Int(doubleValue)
        }
        if let stringValue = try? decode(String.self, forKey: key),
           let parsed = Int(stringValue) {
            return parsed
        }
        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key) else {
            return nil
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? decode(String.self, forKey: key),
           let parsed = Double(stringValue) {
            return parsed
        }
        return nil
    }
}
