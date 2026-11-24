import SwiftUI

/// How far an album or a link reaches, as on Linux (ARCHITECTURE.md, "Verso on the Mac"): the widest of its people
/// and its links still working. Each has one icon, the same wherever it shows, so it is known again on a cover, in a
/// header and in the Share sheet.
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
        let working = links.filter { !$0.isExpired }
        if working.contains(where: { !$0.hasPassword }) { return .publicLink }
        if !working.isEmpty { return .passwordLink }
        return people > 0 ? .people(people) : .personal
    }

    /// A link's own reach.
    static func link(_ link: SharedLink) -> SharingReach { link.hasPassword ? .passwordLink : .publicLink }

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

/// A reach's icon: a padlock for private, two people, the globe, and the globe with a padlock for a link with a
/// password.
struct SharingReachIcon: View {
    let reach: SharingReach

    var body: some View {
        switch reach {
        case .personal: Image(systemName: "lock")
        case .people: Image(systemName: "person.2")
        case .publicLink: Image(systemName: "globe")
        case .passwordLink:
            Image(systemName: "globe")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill").font(.caption2).imageScale(.small).offset(x: 4, y: 3)
                }
        }
    }
}

/// A reach named beside its icon, as an album's or a link's header shows it.
struct SharingReachLabel: View {
    let reach: SharingReach

    var body: some View {
        Label { Text(reach.title) } icon: { SharingReachIcon(reach: reach) }
            .accessibilityElement(children: .combine)
    }
}

extension SharedLink {
    /// Past its last day: it no longer opens.
    var isExpired: Bool { expiresAt.flatMap(ImmichDate.parse).map { $0 <= Date() } ?? false }
}
