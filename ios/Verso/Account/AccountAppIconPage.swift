// App Icon in the account's sheet on the iPhone and the iPad (ARCHITECTURE.md, "The app icon's designs on the Mac, the
// iPhone and the iPad"): the app icon's seven designs, each by its picture and name, with the lens in color or in
// graphite, as Linux offers them in Preferences (`app.icon`). Each design and lens is one icon set, its Day look as
// its light appearance and its Night look as its dark one, which the Home Screen shows where its icons are dark (its
// Customize menu, Dark), as iOS switches an icon's appearance itself. One other than Mist in color
// is one of the app's alternate icons, which iOS keeps and shows on the Home Screen, in Spotlight and in Settings, and
// says so in a notice of its own when it changes; Mist in color is the app icon itself. Verso keeps no setting of its
// own for it.

import SwiftUI
import UIKit

/// The row in the sheet's On This iPhone, with the design and lens shown now; none where iOS offers no alternate icons.
struct AccountAppIconRow: View {
    @State private var look = AppIconLook.current

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            NavigationLink {
                AccountAppIconPage(look: $look)
            } label: {
                LabeledContent("App Icon", value: look.title)
            }
        }
    }
}

/// Color or Graphite above the seven designs in a grid, as Settings shows its Appearance: each its picture, its name,
/// and a circle under them, ticked for the one on the Home Screen. A tap on a design, or on the other lens, sets it.
struct AccountAppIconPage: View {
    /// The icon on the Home Screen, as its Day look: a design and a lens.
    @Binding var look: AppIconLook
    @State private var changing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("Lens", selection: Binding(get: { look.lens }, set: { lens in
                    choose(AppIconLook(design: look.design, lens: lens))
                })) {
                    ForEach(AppIconLens.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                // Four and three on the iPhone and in the iPad's sheet alike, never six and one.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4),
                          spacing: 20) {
                    ForEach(AppIconDesign.allCases) { design in
                        let choice = AppIconLook(design: design, lens: look.lens)
                        AppIconChoiceButton(look: choice, chosen: choice == look) { choose(choice) }
                    }
                }
                .padding(.vertical, 12)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Verso's icon on the Home Screen, in Spotlight and in Settings. Where the Home Screen's icons are dark, it shows its night version, on dark paper.")
                }
            }
            .disabled(changing)
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Mist in color is the app icon itself, so choosing it takes the alternate icon away. The completion handler, as
    /// the async form of the call has crashed when its answer came back off the main thread.
    private func choose(_ choice: AppIconLook) {
        guard choice != look, !changing else { return }
        changing = true
        error = nil
        UIApplication.shared.setAlternateIconName(choice == .mist ? nil : choice.iconName()) { failure in
            let message = failure?.localizedDescription
            Task { @MainActor in
                changing = false
                if let message {
                    error = message
                } else {
                    look = choice
                }
            }
        }
    }
}

private struct AppIconChoiceButton: View {
    let look: AppIconLook
    let chosen: Bool
    let action: () -> Void

    private static let side: CGFloat = 64

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let picture = UIImage.appIconPicture(look) {
                    // The picture's corners are the icon's own; a hairline keeps a light one apart from the row.
                    Image(uiImage: picture)
                        .resizable()
                        .frame(width: Self.side, height: Self.side)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.side * 0.225, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                }
                Text(look.design.title)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

extension AppIconLook {
    /// The icon on the Home Screen now, as its Day look: the one the app's alternate icon is, or Mist in color.
    @MainActor static var current: AppIconLook {
        AppIconLook(iconName: UIApplication.shared.alternateIconName)
    }
}

extension UIImage {
    /// The picture of a design and lens's icon in this build, its Day look and, in dark mode, its Night look:
    /// AppIconImage for Mist in color, AppIcon-SandGraphiteImage for Sand in graphite, AppIconDevImage and so on in
    /// Verso Dev (ios/Verso/Assets.xcassets, which mac/Verso/make-icons.py writes).
    static func appIconPicture(_ look: AppIconLook) -> UIImage? {
        UIImage(named: AppIconLook(design: look.design, lens: look.lens).iconName() + "Image")
    }
}
