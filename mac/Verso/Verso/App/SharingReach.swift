import Foundation
import VersoCore

// How far an album or a link reaches, for the Mac and the iPhone alike: the shared core tells it, as on Linux
// (`sharingAlbumAudience`, `sharingLinkAudience`), and whether a link has expired (`sharedLinkExpired`). Each app shows
// it in its own icon, the same wherever it shows, so it is known again on a cover, in a header and in the sharing sheet.

/// How far an album or a link reaches: the widest of its people and its links still working.
enum SharingReach: Equatable {
    /// Only its owner.
    case personal
    /// Shared with this many people besides its owner.
    case people(Int)
    /// A working link, each with a password.
    case passwordLink
    /// A working link anyone may open.
    case publicLink

    /// An album's reach: the people it is shared with besides its owner, and its links that still work.
    static func album(people: Int, links: [SharedLink]) -> SharingReach {
        SharingReach(sharingAlbumAudience(others: UInt32(max(people, 0)), links: links.map(SharingLink.init)), people: people)
    }

    /// A link's own reach.
    static func link(_ link: SharedLink) -> SharingReach {
        SharingReach(sharingLinkAudience(link: SharingLink(link)), people: 0)
    }

    private init(_ audience: SharingAudience, people: Int) {
        switch audience {
        case .personal: self = .personal
        case .people: self = .people(people)
        case .passwordLink: self = .passwordLink
        case .publicLink: self = .publicLink
        }
    }

    var title: String {
        switch self {
        case .personal: String(localized: "Private")
        case .people(let count): count == 1 ? String(localized: "Shared with 1 person") : String(localized: "Shared with \(count) people")
        case .passwordLink: String(localized: "Shared with a password")
        case .publicLink: String(localized: "Shared publicly")
        }
    }

    /// Whether it reaches past the owner, which a cover shows; a private album, the usual case, shows nothing.
    var isShared: Bool { self != .personal }
}

extension Album {
    /// How far the album reaches: the people it is shared with besides its owner, and the account's links to it. The
    /// account's list of albums may leave out the members of an album that is not shared.
    func reach(links: [SharedLink]) -> SharingReach {
        let people = albumUsers.map { $0.filter { $0.role != "owner" }.count } ?? (shared ? 1 : 0)
        return SharingReach.album(people: people, links: links)
    }
}

extension SharedLink {
    /// Past its last day: it no longer opens.
    var isExpired: Bool { sharedLinkExpired(expiresAt: expiresAt.flatMap(ImmichDate.parse)) }
}

extension SharingLink {
    /// What a link's reach reads of it.
    init(_ link: SharedLink) {
        self.init(hasPassword: link.hasPassword, expiresAt: link.expiresAt.flatMap(ImmichDate.parse))
    }
}
