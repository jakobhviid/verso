// The room iPadOS's window controls take at a window's top leading corner, where a window is resized (Stage Manager,
// windowed apps): the system's bars keep clear of them on their own, and the views Verso draws in the bars' place (a
// page's title, the viewer's top bar) ask for it here, from UIKit's corner-adapted safe area. Nothing elsewhere, and on
// an iPhone.

import SwiftUI
import UIKit

extension View {
    /// Tells `leading` how far from the view's leading edge its content keeps clear of the window's controls, as they
    /// come and go: 0 where there are none.
    func windowControlsInset(_ leading: Binding<CGFloat>) -> some View {
        background(WindowControlsReader { inset in
            if abs(leading.wrappedValue - inset) > 0.5 { leading.wrappedValue = inset }
        })
    }
}

private struct WindowControlsReader: UIViewRepresentable {
    let found: (CGFloat) -> Void

    func makeUIView(context: Context) -> Reader {
        let reader = Reader()
        reader.isUserInteractionEnabled = false
        reader.found = found
        return reader
    }

    func updateUIView(_ reader: Reader, context: Context) {
        reader.found = found
        reader.setNeedsLayout()
    }

    final class Reader: UIView {
        var found: ((CGFloat) -> Void)?
        private var told: CGFloat?

        override func layoutSubviews() {
            super.layoutSubviews()
            look()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            look()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            look()
        }

        /// The corner-adapted safe area's leading inset beyond the plain one's.
        private func look() {
            guard window != nil else { return }
            let corner = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal)).leading
            let plain = directionalEdgeInsets(for: .safeArea()).leading
            let inset = max(0, corner - plain)
            guard told.map({ abs($0 - inset) > 0.5 }) ?? true else { return }
            told = inset
            // Not inside the layout pass it was found in.
            Task { @MainActor [weak self] in self?.found?(inset) }
        }
    }
}
