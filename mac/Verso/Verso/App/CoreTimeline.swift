import Foundation
import VersoCore

// A timeline as the shared core asks it, through immich-api's typed calls (ARCHITECTURE.md, "Verso on the Mac"): its
// scope and settings, which the core makes for a page with its view options (`gridQuery`), as for Linux's window. Where
// no core answers (the offline checks), it goes as the request the core makes for the same (`timelineParameters`).

/// A timeline the core asks: its scope, and how it is narrowed and ordered.
struct CoreTimeline: TimelineRequest, Hashable {
    let source: TimelineSource
    let settings: TimelineSettings

    var parameters: [String: String?] { timelineParameters(source: source, settings: settings).mapValues { Optional($0) } }
}

extension TimelineSettings {
    /// Every Asset of the timeline.
    static let plain = TimelineSettings(favoritesOnly: false, oldestFirst: false, byDateAdded: false, stacked: false, coordinates: false)
    /// Each stack as its primary Asset, as the Mac and the iPhone show every timeline.
    static let stacked = TimelineSettings(favoritesOnly: false, oldestFirst: false, byDateAdded: false, stacked: true, coordinates: false)
}
