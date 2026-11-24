import SwiftUI

extension View {
    /// Keep menu construction and its observable reads out of the view's update, until the menu opens.
    func deferredContextMenu<MenuItems: View>(@ViewBuilder content: @escaping () -> MenuItems) -> some View {
        contextMenu { DeferredMenuItems(content: content) }
    }
}

private struct DeferredMenuItems<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
