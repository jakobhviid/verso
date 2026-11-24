import SwiftUI

/// A reach's icon (SharingReach, from the shared core, as on Linux): a padlock for private, two people, the globe, and
/// the globe with a padlock for a link with a password, the same wherever it shows.
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
