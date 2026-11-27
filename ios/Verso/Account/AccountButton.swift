// The account's picture on iOS, at the top right of every tab's own page on the iPhone, as Apple's apps keep an account
// in the top bar, and in Collections' toolbar alone on the iPad (accountToolbar): a circle,
// as an account is everywhere in Verso (DESIGN.md), its profile picture or its initials on Immich's colour for them,
// with a ring round it while the sheet holds notifications (in the accent, orange where one asks something of the
// person), and the unread ones' count in the toolbar's red badge. A tap opens the account's sheet (AccountSheet), which
// the window presents, as the keyboard's Settings… opens it too: the notifications, the profile, the account's Immich
// features and security, Administration for an admin, About Verso, and Sign Out.

import SwiftUI
import UIKit

extension EnvironmentValues {
    /// A tab's own page on the iPhone, whose top bar ends with the account (AccountToolbarItems).
    @Entry var accountInTopBar = false
}

extension View {
    /// Marks a tab's own page: on the iPhone its top bar ends with the account's button; on the iPad the account stays
    /// in Collections alone (CollectionsToolbar). Pushed pages are declared outside the page, so the mark stays on it.
    func accountToolbar() -> some View {
        environment(\.accountInTopBar, UIDevice.current.userInterfaceIdiom == .phone)
    }
}

/// The account's button at the right end of a tab's own page's top bar, after the page's own buttons, which a page
/// puts last in its toolbar; none while a page is selecting, when the selection has the top bar.
struct AccountToolbarItems: ToolbarContent {
    let session: LibrarySession
    let chrome: LibraryChrome?
    let shown: Bool

    var body: some ToolbarContent {
        if shown && chrome?.isSelecting != true {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                AccountButton(services: session.services) { chrome?.accountShown = true }
            }
            // The button draws its own glass, a circle, as on Collections.
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

struct AccountButton: View {
    let services: AccountServices
    /// Opens the account's sheet.
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            AccountCircle(user: services.user, picture: services.profilePicture, size: 32)
                .padding(3)
                .overlay {
                    if services.notificationCount > 0 {
                        Circle()
                            .strokeBorder(services.notificationNeedsLook ? Color.orange : Color.accentColor, lineWidth: 2)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        // A toolbar item's badge, drawn by the system where the button is in a toolbar.
        .badge(services.unreadNotificationCount)
        .accessibilityLabel("Account")
        .accessibilityValue(accessibilityValue)
    }

    /// The account's name, and how many notifications are unread, or kept, when any are.
    private var accessibilityValue: Text {
        let name = Text(verbatim: services.user.map { $0.name.isEmpty ? $0.email : $0.name } ?? "")
        let unread = services.unreadNotificationCount
        let kept = services.notificationCount
        if unread > 0 { return Text("\(name), ^[\(unread) unread notification](inflect: true)") }
        return kept == 0 ? name : Text("\(name), ^[\(kept) notification](inflect: true)")
    }
}

/// An account's circle: its profile picture, or Immich's initials on the colour Immich gave the account, as the Mac's
/// sidebar and Immich's web app draw them.
struct AccountCircle: View {
    let name: String
    let email: String
    let avatarColor: String?
    var picture: UIImage?
    let size: CGFloat

    init(name: String, email: String, avatarColor: String?, picture: UIImage? = nil, size: CGFloat) {
        self.name = name
        self.email = email
        self.avatarColor = avatarColor
        self.picture = picture
        self.size = size
    }

    init(user: User?, picture: UIImage?, size: CGFloat) {
        self.init(name: user?.name ?? "", email: user?.email ?? "", avatarColor: user?.avatarColor, picture: picture,
                  size: size)
    }

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            } else if name.isEmpty && email.isEmpty {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(color)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    /// The first letters of the first and last names, or of the email when the account has no name.
    private var initials: String {
        let words = name.split(separator: " ")
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? String(email.first ?? "?").uppercased() : String(letters).uppercased()
    }

    /// Immich's avatar colours, by the names its API gives them.
    private var color: Color {
        switch avatarColor {
        case "pink": .pink
        case "red": .red
        case "yellow": .yellow
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "orange": .orange
        case "gray": .gray
        case "amber": Color(red: 1, green: 0.75, blue: 0)
        default: .accentColor
        }
    }
}
