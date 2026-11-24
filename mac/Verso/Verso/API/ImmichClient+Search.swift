import Foundation

extension ImmichClient {
    func advancedSearch(_ query: SearchQuery, smartEnabled: Bool, page: SearchPage, progress: (@MainActor @Sendable (Int) -> Void)? = nil) async throws -> SearchResponse.Assets {
        let smart = query.mode == .context && smartEnabled && !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dateSort = smart && query.sort != .automatic
        let body = AdvancedSearchRequest(query, smart: smart, page: dateSort ? .init(page: 1) : page)
        let first: SearchResponse.Assets
        do {
            first = try await searchPage(body, smart: smart)
        } catch ImmichError.http(404, _) where smart {
            return try await searchPage(AdvancedSearchRequest(query, smart: false, page: page), smart: false)
        }
        guard smart, query.sort != .automatic else { return first }
        // Keep the server’s most relevant matches before sorting by date,
        // so weak matches from later pages cannot displace them.
        let limit = AdvancedSearchRequest.smartDateResultLimit
        var seen: Set<String> = []
        var items = Array(first.items.filter { seen.insert($0.id).inserted }.prefix(limit))
        var current = 1
        await progress?(items.count)
        var next = first.nextPage
        while items.count < limit, let token = next {
            guard let number = Int(token), number > current else {
                throw ImmichError.http(502, String(localized: "Invalid search pagination"))
            }
            current = number
            try Task.checkCancellation()
            let more = try await searchPage(AdvancedSearchRequest(query, smart: true, page: .init(page: number)), smart: true)
            items.append(contentsOf: more.items.filter { seen.insert($0.id).inserted }.prefix(limit - items.count))
            await progress?(items.count)
            next = more.nextPage
        }
        try Task.checkCancellation()
        return Self.sortSearchAssets(items, order: query.sort)
    }

    /// One page of a search: smart, or by its filters. Through the core's typed call when it is installed.
    func searchPage(_ body: AdvancedSearchRequest, smart: Bool) async throws -> SearchResponse.Assets {
        if let typed = try await Self.core?(apiURL, credential)?.search(body, smart: smart) { return typed }
        let response: SearchResponse = try await send("POST", smart ? "search/smart" : "search/metadata", body: body)
        return response.assets
    }

    static func sortSearchAssets(_ items: [AssetResponse], order: SearchSort) -> SearchResponse.Assets {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        let dated = items.map { asset in
            (asset: asset, date: (try? fractional.parse(asset.fileCreatedAt)) ?? (try? plain.parse(asset.fileCreatedAt)))
        }
        let sorted = dated.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right:
                return order == .oldest ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.asset.id < rhs.asset.id
            }
        }
        return .init(items: sorted.map(\.asset))
    }

    func searchSuggestions(_ type: String, filters: SearchQuery) async throws -> [String] {
        let parameters = Self.searchSuggestionParameters(type, filters: filters)
        if let typed = try await Self.core?(apiURL, credential)?.searchSuggestions(
            type: type, country: parameters["country"] ?? nil, state: parameters["state"] ?? nil, make: parameters["make"] ?? nil,
            model: parameters["model"] ?? nil) { return typed }
        return try await get("search/suggestions", query: parameters)
    }

    static func searchSuggestionParameters(_ type: String, filters: SearchQuery) -> [String: String?] {
        func value(_ text: String) -> String? { text.isEmpty ? nil : text }
        return [
            "type": type,
            "country": type == "state" || type == "city" ? value(filters.country) : nil,
            "state": type == "city" ? value(filters.state) : nil,
            "make": type == "camera-model" || type == "camera-lens-model" ? value(filters.make) : nil,
            "model": type == "camera-lens-model" ? value(filters.model) : nil,
        ]
    }
    func searchPreferences() async throws -> SearchPreferences { try await get("users/me/preferences") }
    func searchExplore() async throws -> [SearchExploreGroup] {
        if let typed = try await Self.core?(apiURL, credential)?.searchExplore() { return typed }
        return try await get("search/explore")
    }
}
