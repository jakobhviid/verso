import Foundation

extension ImmichClient {
    /// Find Similar Photos: one page of timeline photos taken in a date range, oldest first. takenAfter/takenBefore are
    /// deprecated since v3.2 but still honored in v3.3.5, and are the only date filter v2 servers understand.
    func similarPhotosPage(takenAfter: Date, takenBefore: Date, page: SearchPage, size: Int = 250) async throws -> SearchResponse.Assets {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var body = AdvancedSearchRequest(size: size)
        body.type = "IMAGE"
        body.visibility = "timeline"
        body.takenAfter = takenAfter.formatted(format)
        body.takenBefore = takenBefore.formatted(format)
        body.page = page.page
        body.cursor = page.cursor
        body.order = "asc"
        body.withStacked = true
        return try await searchPage(body, smart: false)
    }
}
