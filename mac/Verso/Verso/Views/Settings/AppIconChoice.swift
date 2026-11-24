import AppKit
import SwiftUI

/// The app icon's design on the Mac (Settings, General; ARCHITECTURE.md, "The app icon's designs on the Mac, the
/// iPhone and the iPad"). macOS has no alternate app icons, a sandboxed app cannot change the icon Finder and
/// Launchpad show, and changing the bundle would break its signature, so the design chosen is the picture the Dock and
/// the app switcher show while Verso runs (`applicationIconImage`), set as Verso starts and when the choice changes.
/// The choice is a user default of the app's, as the menu bar icon's colour is, not a setting of `config.toml`.
enum AppIconChoice {
    static let designKey = "appIcon.design"

    static var chosen: AppIconDesign {
        AppIconDesign(rawValue: UserDefaults.standard.string(forKey: designKey) ?? "") ?? .mist
    }

    /// The design's icon in this build: the app icon for Mist, else the alternate icon set of its name, which the
    /// build compiles (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES).
    static func picture(_ design: AppIconDesign) -> NSImage? {
        NSImage(named: design.iconName())
    }

    /// As Verso starts: the Dock shows the bundle's icon until a design other than Mist is chosen.
    @MainActor static func applyAtLaunch() {
        if chosen != .mist { apply(chosen) }
    }

    /// The design in the Dock and the app switcher; Mist gives them the bundle's own icon back.
    @MainActor static func apply(_ design: AppIconDesign) {
        if design == .mist {
            NSApplication.shared.applicationIconImage = nil
        } else if let image = picture(design) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}

/// App Icon in Settings, General: the seven designs side by side, each its icon and name, the chosen one ringed in the
/// accent colour as System Settings marks its Appearance, and under them that Finder and Launchpad keep Mist.
struct AppIconChoiceSection: View {
    @AppStorage(AppIconChoice.designKey) private var chosen = AppIconDesign.mist
    /// The icons' pictures: the build's catalog, or the PNG sets for the offline design check.
    var picture: (AppIconDesign) -> NSImage? = AppIconChoice.picture

    var body: some View {
        Section {
            LabeledContent("App Icon") {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(AppIconDesign.allCases) { design in
                        AppIconChoiceTile(design: design, chosen: design == chosen, picture: picture(design)) {
                            chosen = design
                        }
                    }
                }
            }
        } footer: {
            Text("The Dock and the app switcher show it while Verso runs. Finder and Launchpad keep Mist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: chosen) { _, design in AppIconChoice.apply(design) }
    }
}

/// One design: its icon, ringed while chosen, and its name under it.
private struct AppIconChoiceTile: View {
    let design: AppIconDesign
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
                Text(design.title)
                    .font(.caption)
                    .foregroundStyle(chosen ? .primary : .secondary)
            }
            .frame(width: 54)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(design.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
