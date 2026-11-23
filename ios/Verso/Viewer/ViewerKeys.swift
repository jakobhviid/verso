// The viewer's keys on a hardware keyboard (an iPad's, or an iPhone's), as the Mac's viewer has them (SPEC.md, "On the
// iPad"): ← and → go to the photo beside, Space plays or pauses a video and plays a Live Photo, "." favorites or
// unfavorites, ⌘I shows or hides the details, ⌘⌫ deletes (asking first, as the bar's Delete does) and Esc closes. A view
// of UIKit's in the viewer takes the keyboard as the photo opens, so its keys come ahead of the scroll views' own, which
// scroll with the arrows and Space, and they show where ⌘ held lists the keys. A field being typed in (a caption) keeps
// its keys; the viewer takes them again once it is left. A sheet over the viewer has the keyboard while it shows.

import SwiftUI
import UIKit

struct ViewerKeys: UIViewRepresentable {
    let state: ViewerState

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.isUserInteractionEnabled = false
        view.state = state
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        view.state = state
        // Read so a change of these takes the keyboard back: the details going, a sheet over the viewer closing.
        _ = (state.covered, state.showsDetails, state.currentID)
        view.takeKeyboard()
    }

    final class KeyView: UIView {
        weak var state: ViewerState?

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            takeKeyboard()
        }

        /// Takes the keyboard, unless a field is being typed in or it has it already.
        func takeKeyboard() {
            guard window != nil, !isFirstResponder, !(UIResponder.firstResponder is UITextInput) else { return }
            // Once the update in progress is over, so a sheet closing has handed the keyboard back first.
            Task { @MainActor [weak self] in
                guard let self, window != nil, !isFirstResponder, !(UIResponder.firstResponder is UITextInput) else { return }
                becomeFirstResponder()
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard let state, state.isOpen, !state.covered, let item = state.currentItem else { return [] }
            var commands = [
                key(UIKeyCommand.inputLeftArrow, [], String(localized: "Previous Photo"), #selector(previousPhoto)),
                key(UIKeyCommand.inputRightArrow, [], String(localized: "Next Photo"), #selector(nextPhoto)),
            ]
            if item.isVideo {
                let title = state.video.isPlaying ? String(localized: "Pause") : String(localized: "Play")
                commands.append(key(" ", [], title, #selector(playOrPause)))
            } else if item.livePhotoVideoID != nil {
                commands.append(key(" ", [], String(localized: "Play Live Photo"), #selector(playOrPause)))
            }
            if state.canFavorite {
                let title = item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite")
                commands.append(key(".", [], title, #selector(favorite)))
            }
            let info = state.showsDetails ? String(localized: "Hide Info") : String(localized: "Show Info")
            commands.append(key("i", .command, info, #selector(toggleInfo)))
            if state.canDelete {
                let title = state.deletesPermanently ? String(localized: "Delete Permanently") : String(localized: "Delete")
                commands.append(key(UIKeyCommand.inputDelete, .command, title, #selector(deletePhoto)))
            }
            commands.append(key(UIKeyCommand.inputEscape, [], String(localized: "Close Photo"), #selector(close)))
            return commands
        }

        private func key(_ input: String, _ modifiers: UIKeyModifierFlags, _ title: String,
                         _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            // Ahead of the scroll views' arrows and Space, and of the system's Esc.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        @objc private func previousPhoto() { state?.step(-1) }
        @objc private func nextPhoto() { state?.step(1) }
        @objc private func playOrPause() { state?.playOrPause() }
        @objc private func favorite() { state?.keyActions?.favorite() }
        @objc private func toggleInfo() { state?.toggleDetails() }
        @objc private func deletePhoto() { state?.keyActions?.delete() }
        @objc private func close() { state?.closeViewer() }
    }
}

extension UIResponder {
    @MainActor private static weak var found: UIResponder?

    /// The window's first responder: a field being typed in keeps the keyboard's keys.
    @MainActor static var firstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(reportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func reportFirstResponder() {
        MainActor.assumeIsolated { UIResponder.found = self }
    }
}
