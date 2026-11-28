// Settings on the Apple TV, at the sidebar's foot, laid out as tvOS's own Settings: the app's icon large on the left,
// with its name and version, and a list on the right, a row at a time under the remote's focus, each saying its value
// and opening a page of its own where it holds more than a switch.
// - Library: the Top Shelf's rows (TVTopShelf has what each holds, and its order), the Locked Folder in Collections,
//   off until turned on, which the iPhone opens each time (TVLockedFolder), and Manage Photos, off until the iPhone
//   allows it (TVManagePhotos).
// - Appearance: the app's icon, Day or Night, as the iPhone's App Icon page offers its designs (tvOS keeps one icon in
//   light and dark alike, so the person chooses), once the app carries its Night icon.
// - Account: who is signed in, to which server, what this Apple TV may do, and Sign Out.
// - About Verso: the version, the credit, the non-affiliation notice every platform's About carries, and the AI line.

import SwiftUI
import UIKit

struct TVSettings: View {
    @Environment(TVModel.self) private var tv
    @State private var icon = TVAppIcon.current
    @State private var confirmingSignOut = false
    @State private var user: User?
    /// The Top Shelf's rows turned on, read again as Settings comes back from their page.
    @State private var shelf = ""
    @AppStorage(TVLockedFolderSetting.key) private var showsLockedFolder = false

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(spacing: 20) {
                Image(icon.preview)
                    .resizable()
                    .aspectRatio(5 / 3, contentMode: .fit)
                    .frame(width: 520)
                    .clipShape(.rect(cornerRadius: 32, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                Text("Verso").font(.title2.bold())
                Text(Self.version).font(.callout).foregroundStyle(.secondary)
            }
            .frame(width: 620)
            .padding(.top, 140)
            Form {
                Section {
                    NavigationLink { TVTopShelfSettings() } label: { LabeledContent("Top Shelf", value: shelf) }
                    Toggle("Show Locked Folder in Collections", isOn: $showsLockedFolder)
                    NavigationLink { TVManagePhotos() } label: {
                        LabeledContent("Manage Photos", value: tv.changes == nil ? String(localized: "Off") : String(localized: "On"))
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("The Locked Folder opens only from your iPhone, with Face ID or your PIN, each time. Manage Photos lets a press and hold on a photo favorite, archive, delete or lock it, once your iPhone allows it.")
                }
                if TVAppIcon.offered {
                    Section("Appearance") {
                        NavigationLink { TVAppIconPage(icon: $icon) } label: { LabeledContent("App Icon", value: icon.title) }
                    }
                }
                Section {
                    if let user {
                        LabeledContent("Name", value: user.name)
                        LabeledContent("Email", value: user.email)
                    }
                    LabeledContent("Server", value: tv.client?.serverURL.host() ?? "")
                    LabeledContent("This Apple TV", value: tv.changes == nil ? String(localized: "Can view") : String(localized: "Can view and change"))
                    // White as the rows around it, as in tvOS's own Settings; the question it asks is the destructive one.
                    Button("Sign Out") { confirmingSignOut = true }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Set up from your iPhone with a key of its own. It stays in Immich until you forget this Apple TV on your iPhone (Account, Apple TV), or delete it in Immich.")
                }
                Section {
                    NavigationLink("About Verso") { TVAboutPage() }
                }
            }
            // A row grows under the focus, past the list's edge: drawn whole, not cut off there.
            .scrollClipDisabled()
            // tvOS draws a switch's and a link's title in the accent, the system blue the TV's asset catalog sets; the
            // rows are in the text's own colour, as in tvOS's own Settings.
            .tint(.primary)
        }
        .task { user = try? await tv.client?.currentUser() }
        .onAppear { shelf = TVTopShelf.summary }
        .confirmationDialog("Sign out of this Apple TV?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { tv.signOut() }
        } message: {
            Text("Set it up with your iPhone again to come back.")
        }
    }

    /// The release line's version and the build, as the iPhone's About says it.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        guard let build = info["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// The non-affiliation notice the app's Info.plist carries, which SPEC.md words.
    static var notice: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Immich project or FUTO."
    }
}

/// The Top Shelf's rows, a switch each, with what decides their order.
private struct TVTopShelfSettings: View {
    @Environment(TVModel.self) private var tv

    var body: some View {
        Form {
            Section {
                ForEach(TVShelfData.Row.allCases, id: \.self) { row in
                    TVTopShelfRowSwitch(row: row) { Task { await tv.refreshTopShelf() } }
                }
            } footer: {
                Text("Above Verso when it is in the top row of the Home Screen, in this order. Albums come with the newest photos first, as Albums shows them; people as People does.")
            }
        }
        .scrollClipDisabled()
        // Its switches' titles in the text's colour, as on the Settings page.
        .tint(.primary)
        .frame(maxWidth: 1200)
        .navigationTitle("Top Shelf")
    }
}

/// The app's icon, Day or Night, as cards with a tick under the one on the Home Screen.
private struct TVAppIconPage: View {
    @Binding var icon: TVAppIcon

    var body: some View {
        HStack(spacing: TVMetrics.cardSpacing) {
            ForEach(TVAppIcon.allCases) { choice in
                Button { choose(choice) } label: {
                    TVAppIconChoice(icon: choice, chosen: choice == icon)
                }
                .buttonStyle(TVLiftStyle(cornerRadius: TVMetrics.cardRadius))
                .tvLifts()
            }
        }
        .navigationTitle("App Icon")
    }

    private func choose(_ choice: TVAppIcon) {
        guard choice != icon, UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            if error == nil { Task { @MainActor in icon = choice } }
        }
    }
}

/// Who made Verso, from what, the notice every platform's About carries, and the AI line.
private struct TVAboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Verso \(TVSettings.version)").font(.title3.bold())
            Text("By Jakob Hviid, under the MIT license. Built from Immich Gallery for the Mac, by Alessandro Craciun, with contributions by Jakob Hviid.")
            Text(TVSettings.notice).foregroundStyle(.secondary)
            Text("Parts of this project were written with the assistance of AI coding agents. All changes are reviewed by the maintainer.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: 1200, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About Verso")
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
