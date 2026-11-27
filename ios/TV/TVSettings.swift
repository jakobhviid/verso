// Settings on the Apple TV, at the sidebar's foot: the app's icon, Day or Night, as the iPhone's App Icon page offers
// its designs (tvOS keeps one icon in light and dark alike, so the person chooses); what the Top Shelf shows, a switch
// for each of its rows (TVTopShelf has what each holds, and its order); the Locked Folder in Collections,
// off until turned on, which the iPhone opens each time (TVLockedFolder); the account, with Sign Out; and About, with
// the non-affiliation notice every platform's About carries.

import SwiftUI
import UIKit

struct TVSettings: View {
    @Environment(TVModel.self) private var tv
    @State private var icon = TVAppIcon.current
    @State private var confirmingSignOut = false
    @AppStorage(TVLockedFolderSetting.key) private var showsLockedFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                TVPageTitle("Settings")
                if TVAppIcon.offered {
                VStack(alignment: .leading, spacing: 24) {
                    TVSectionHeader(title: String(localized: "App Icon"))
                    HStack(spacing: TVMetrics.cardSpacing) {
                        ForEach(TVAppIcon.allCases) { choice in
                            Button { choose(choice) } label: {
                                TVAppIconChoice(icon: choice, chosen: choice == icon)
                            }
                            .buttonStyle(TVLiftStyle(cornerRadius: TVMetrics.cardRadius))
                            .tvLifts()
                        }
                    }
                }
                }
                VStack(alignment: .leading, spacing: 24) {
                    TVSectionHeader(title: String(localized: "Top Shelf"))
                    ForEach(TVShelfData.Row.allCases, id: \.self) { row in
                        TVTopShelfRowSwitch(row: row) { Task { await tv.refreshTopShelf() } }
                            .frame(maxWidth: 1100)
                    }
                    Text("Above Verso when it is in the top row of the Home Screen. Albums come with the newest photos first, as Albums shows them; people as People does.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 24) {
                    TVSectionHeader(title: String(localized: "Locked Folder"))
                    Toggle("Show Locked Folder in Collections", isOn: $showsLockedFolder)
                        .frame(maxWidth: 1100)
                    Text("It opens only from your iPhone, with Face ID or your PIN, each time, and locks as you leave it. The Apple TV never learns the PIN.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 24) {
                    TVSectionHeader(title: String(localized: "Account"))
                    if let server = tv.client?.serverURL.host() {
                        Text(server)
                            .font(.headline)
                    }
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    Text("The key the iPhone made for this Apple TV stays in Immich until you forget the Apple TV on the iPhone, or delete the key in Immich.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TVSectionHeader(title: String(localized: "About"))
                    Text("Verso \(Self.version), by Jakob Hviid, under the MIT license. Built from Immich Gallery for the Mac, by Alessandro Craciun, with contributions by Jakob Hviid.")
                    Text(Self.notice)
                        .foregroundStyle(.secondary)
                    Text("Parts of this project were written with the assistance of AI coding agents. All changes are reviewed by the maintainer.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: 1100, alignment: .leading)
                // Text is not focusable: a last focusable row lets the remote scroll down to About.
                .focusable()
            }
        }
        .scrollClipDisabled()
        .confirmationDialog("Sign out of this Apple TV?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { tv.signOut() }
        } message: {
            Text("Set it up with your iPhone again to come back.")
        }
    }

    private func choose(_ choice: TVAppIcon) {
        guard choice != icon, UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            if error == nil { Task { @MainActor in icon = choice } }
        }
    }

    /// The release line's version and the build, as the iPhone's About says it.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        guard let build = info["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// The non-affiliation notice the app's Info.plist carries, which SPEC.md words.
    private static var notice: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Immich project or FUTO."
    }
}

/// A Top Shelf row's switch, kept in the app's settings (TVShelfData.Row.settingKey); the shelf is written again as it
/// changes.
private struct TVTopShelfRowSwitch: View {
    let row: TVShelfData.Row
    let changed: () -> Void
    @AppStorage private var shown: Bool

    init(row: TVShelfData.Row, changed: @escaping () -> Void) {
        self.row = row
        self.changed = changed
        _shown = AppStorage(wrappedValue: row.shownByDefault, row.settingKey)
    }

    var body: some View {
        Toggle(row.title, isOn: $shown)
            .onChange(of: shown) { changed() }
    }
}

/// The TV's two icons (ios/TV/make-tv-icons.py): Day, the app's own, and Night, its alternate.
enum TVAppIcon: String, CaseIterable, Identifiable {
    case day, night

    var id: Self { self }

    /// Whether the app carries its Night icon as an alternate (Info.plist's CFBundleAlternateIcons, which the asset
    /// catalog writes for the project's alternate icons).
    static var offered: Bool {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        return (icons?["CFBundleAlternateIcons"] as? [String: Any])?["AppIconNight"] != nil
    }

    @MainActor static var current: TVAppIcon { UIApplication.shared.alternateIconName == nil ? .day : .night }

    /// The alternate icon's name, as the asset catalog has it; nil for the app's own.
    var alternateName: String? { self == .day ? nil : "AppIconNight" }

    var title: String { self == .day ? String(localized: "Day") : String(localized: "Night") }

    /// Its picture, flat, as the Home Screen shows it.
    var preview: String { self == .day ? "TV Icon Day" : "TV Icon Night" }
}

/// An icon to choose: its picture, its name, and a tick under the one on the Home Screen.
private struct TVAppIconChoice: View {
    let icon: TVAppIcon
    let chosen: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(icon.preview)
                .resizable()
                .aspectRatio(5 / 3, contentMode: .fit)
                .frame(width: 400)
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
            Label(icon.title, systemImage: chosen ? "checkmark.circle.fill" : "circle")
                .font(.headline)
                .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(20)
    }
}
