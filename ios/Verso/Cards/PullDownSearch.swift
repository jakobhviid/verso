// A search field as a card page draws it, above its cards and hidden at rest above the top of the page (CardGrid's
// `finder`), as Mail's and Settings' search is.

import SwiftUI

/// A search field as iOS draws one in a page: a capsule with the magnifying glass, the text, and a button that clears
/// it.
struct PageSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    /// Whether the field has the keyboard, told to the page: the field keeps its own focus, as it is drawn in a cell
    /// of the page's grid, whose SwiftUI the page's own focus does not reach.
    @Binding var isFocused: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
        .onChange(of: focused) { _, now in if isFocused != now { isFocused = now } }
        .onChange(of: isFocused) { _, now in if focused != now { focused = now } }
    }
}
