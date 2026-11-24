import SwiftUI

/// A page header's controls, as Linux draws them (DESIGN.md, "The apps' interfaces"): a status that can be changed, or
/// an action on the page, rather than a button, in a row under the page's name and details, where the eye already is
/// for it, as Music's and Contacts' headers have theirs. Each is its icon in the accent colour and its current state or
/// name in the body's text, lit under the pointer as the Mac's accessory controls are, so it reads as what is so and is
/// known to be clickable, without a button's frame.
struct HeaderStatusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HeaderStatusBody(configuration: configuration) }
}

private struct HeaderStatusBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(HeaderStatusLabelStyle(isEnabled: isEnabled))
            .font(.body)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(configuration.isPressed ? 1 : hovering && isEnabled ? 0.7 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// The icon in the accent colour, which says it can be clicked; the state or name in the body's colour.
private struct HeaderStatusLabelStyle: LabelStyle {
    let isEnabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            configuration.title.foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
    }
}

extension ButtonStyle where Self == HeaderStatusStyle {
    /// A header's status or action (`HeaderStatusStyle`).
    static var headerStatus: HeaderStatusStyle { HeaderStatusStyle() }
}
