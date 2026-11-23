import AppKit
import SwiftUI

/// The app icon's looks on the Mac (Settings, General; ARCHITECTURE.md, "The app icon's designs on the Mac, the
/// iPhone and the iPad"): one for light mode and one for dark mode, each any of the 28. macOS has no alternate app
/// icons, a sandboxed app cannot change the icon Finder and Launchpad show, and changing the bundle would break its
/// signature, so the look is the picture the Dock and the app switcher show while Verso runs
/// (`applicationIconImage`), set as Verso starts and whenever the choice or the system's appearance changes. The
/// choices are user defaults of the app's, as the menu bar icon's color is, not settings of `config.toml`.
enum AppIconChoice {
    static let lightKey = "appIcon.light"
    static let darkKey = "appIcon.dark"

    /// The look in light mode: Mist unless another is chosen.
    static var light: AppIconLook {
        AppIconLook(rawValue: UserDefaults.standard.string(forKey: lightKey) ?? "") ?? .mist
    }

    /// The look in dark mode: Mist Night unless another is chosen.
    static var dark: AppIconLook {
        AppIconLook(rawValue: UserDefaults.standard.string(forKey: darkKey) ?? "") ?? .mistNight
    }

    /// The look's icon in this build: the app icon for Mist on Day paper in color, else the PNG set of its name, which
    /// the build compiles as an alternate icon (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES).
    static func picture(_ look: AppIconLook) -> NSImage? {
        NSImage(named: look.iconName())
    }

    /// What the bundle's own icon shows: Mist, and in dark mode from macOS 26, whose Icon Composer document has a dark
    /// appearance, Mist Night.
    static func bundleIcon(dark: Bool) -> AppIconLook {
        if #available(macOS 26, *), dark { return .mistNight }
        return .mist
    }

    @MainActor private static var appearanceObservation: NSKeyValueObservation?

    /// As Verso starts: the chosen look in the Dock, and again whenever the system's appearance changes.
    @MainActor static func applyAtLaunch() {
        apply()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in apply() }
        }
    }

    /// The look of the system's appearance in the Dock and the app switcher; where it is what the bundle's own icon
    /// shows, the bundle's icon itself.
    @MainActor static func apply() {
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let look = dark ? self.dark : light
        if look == bundleIcon(dark: dark) {
            NSApplication.shared.applicationIconImage = nil
        } else if let image = picture(look) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}

/// App Icon in Settings, General: a row for light mode and one for dark mode, each the seven designs side by side in
/// that row's paper and lens, the chosen one ringed in the accent color as System Settings marks its Appearance, and
/// under them Day or Night and Color or Graphite; under the rows, that Finder and Launchpad keep Mist.
struct AppIconChoiceSection: View {
    @AppStorage(AppIconChoice.lightKey) private var light = AppIconLook.mist
    @AppStorage(AppIconChoice.darkKey) private var dark = AppIconLook.mistNight
    /// The icons' pictures: the build's catalog, or the PNG sets for the offline design check.
    var picture: (AppIconLook) -> NSImage? = AppIconChoice.picture

    var body: some View {
        Section {
            AppIconLookRow(title: "Light Mode", look: $light, picture: picture)
            AppIconLookRow(title: "Dark Mode", look: $dark, picture: picture)
        } header: {
            Text("App Icon")
        } footer: {
            Text("The Dock and the app switcher show them while Verso runs, as the Mac is in light or dark mode. Finder and Launchpad keep Mist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: light) { AppIconChoice.apply() }
        .onChange(of: dark) { AppIconChoice.apply() }
    }
}

/// One mode's look: the seven designs in its paper and lens, and its paper and lens as two small segmented controls.
private struct AppIconLookRow: View {
    let title: LocalizedStringKey
    @Binding var look: AppIconLook
    let picture: (AppIconLook) -> NSImage?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(AppIconDesign.allCases) { design in
                        let shown = AppIconLook(design: design, paper: look.paper, lens: look.lens)
                        AppIconChoiceTile(title: design.title, chosen: design == look.design, picture: picture(shown)) {
                            look.design = design
                        }
                    }
                }
                HStack(spacing: 8) {
                    Picker("Paper", selection: $look.paper) {
                        ForEach(AppIconPaper.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Lens", selection: $look.lens) {
                        ForEach(AppIconLens.allCases) { Text($0.title).tag($0) }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

/// One design: its icon, ringed while chosen, and its name under it.
private struct AppIconChoiceTile: View {
    let title: String
    let chosen: Bool
    let picture: NSImage?
    let action: () -> Void

    /// A Mac icon's square is 824 of its 1024 points, in the middle, its corners 185 round (make-icons.py): the ring
    /// follows the square rather than the image's edge.
    private static let side: CGFloat = 48
    private static let square = side * 824 / 1024
    private static let gap: CGFloat = 3

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: picture ?? NSImage())
                    .resizable()
                    .frame(width: Self.side, height: Self.side)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.square * 185 / 824 + Self.gap, style: .continuous)
                            .strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 2.5)
                            .frame(width: Self.square + 2 * Self.gap + 2.5, height: Self.square + 2 * Self.gap + 2.5)
                    }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(chosen ? .primary : .secondary)
            }
            .frame(width: 54)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
