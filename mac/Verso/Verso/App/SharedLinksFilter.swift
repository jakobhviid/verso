import Foundation
import VersoCore

// Shared links: the Immich web app's All, Albums and Individual tabs (shared-links/(list)/+layout.svelte),
// plus hiding expired links. The shared core decides which show (`sharedLinksShown`), as on Linux.

/// Which shared links show, kept in the settings by Immich's tab names, the same as Linux's.
enum SharedLinksFilter: String, CaseIterable, Identifiable {
    // Immich's tab names.
    case all, album, individual
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All Links"
        case .album: "Album Links"
        case .individual: "Individual Shares"
        }
    }

    /// The links this filter shows, without the expired ones when they are hidden, in the server's order.
    func links(_ links: [SharedLink], hideExpired: Bool) -> [SharedLink] {
        let facts = links.map { SharedLinkFacts(kind: $0.type, expiresAt: $0.expiresAt.flatMap(ImmichDate.parse)) }
        return sharedLinksShown(links: facts, filter: rawValue, hideExpired: hideExpired).map { links[Int($0)] }
    }
}
