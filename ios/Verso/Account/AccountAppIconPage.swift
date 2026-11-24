// App Icon in the account's sheet on the iPhone and the iPad (ARCHITECTURE.md, "The app icon's designs on the Mac, the
// iPhone and the iPad"): the app icon's seven designs, each by its picture and name, as Linux offers them in
// Preferences (`app.icon`). A design other than Mist is one of the app's alternate icons, which iOS keeps and shows on
// the Home Screen, in Spotlight and in Settings, and says so in a notice of its own when it changes; Mist is the app
// icon itself. Verso keeps no setting of its own for it.

import SwiftUI
import UIKit

/// The row in the sheet's On This iPhone, with the design shown now; none where iOS offers no alternate icons.
struct AccountAppIconRow: View {
    @State private var design = AppIconDesign.current

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            NavigationLink {
                AccountAppIconPage(design: $design)
            } label: {
                LabeledContent("App Icon", value: design.title)
            }
        }
    }
}

/// The seven designs in a grid, as Settings shows its Appearance: each its picture, its name, and a circle under them,
/// ticked for the one on the Home Screen. A tap sets that one.
struct AccountAppIconPage: View {
    @Binding var design: AppIconDesign
    @State private var changing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                // Four and three on the iPhone and in the iPad's sheet alike, never six and one.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4),
                          spacing: 20) {
                    ForEach(AppIconDesign.allCases) { choice in
                        AppIconChoiceButton(design: choice, chosen: choice == design) { choose(choice) }
                    }
                }
                .padding(.vertical, 12)
                .disabled(changing)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Verso's icon on the Home Screen, in Spotlight and in Settings.")
                }
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Mist is the app icon itself, so choosing it takes the alternate icon away. The completion handler, as the async
    /// form of the call has crashed when its answer came back off the main thread.
    private func choose(_ choice: AppIconDesign) {
        guard choice != design, !changing else { return }
        changing = true
        error = nil
        UIApplication.shared.setAlternateIconName(choice == .mist ? nil : choice.iconName()) { failure in
            let message = failure?.localizedDescription
            Task { @MainActor in
                changing = false
                if let message {
                    error = message
                } else {
                    design = choice
                }
            }
        }
    }
}

private struct AppIconChoiceButton: View {
    let design: AppIconDesign
    let chosen: Bool
    let action: () -> Void

    private static let side: CGFloat = 64

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let picture = UIImage.appIconPicture(design) {
                    // The picture's corners are the icon's own; a hairline keeps a light one apart from the row.
                    Image(uiImage: picture)
                        .resizable()
                        .frame(width: Self.side, height: Self.side)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.side * 0.225, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                }
                Text(design.title)
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
        .accessibilityLabel(design.title)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

extension AppIconDesign {
    /// The design on the Home Screen now: the one the app's alternate icon is, or Mist.
    @MainActor static var current: AppIconDesign {
        AppIconDesign(iconName: UIApplication.shared.alternateIconName)
    }
}

extension UIImage {
    /// The picture of a design's icon in this build, light and dark: AppIconImage for Mist, AppIcon-SandImage for Sand,
    /// AppIconDevImage and so on in Verso Dev (ios/Verso/Assets.xcassets, which mac/Verso/make-icons.py writes).
    static func appIconPicture(_ design: AppIconDesign) -> UIImage? {
        UIImage(named: design.iconName() + "Image")
    }
}
