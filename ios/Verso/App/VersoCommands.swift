// The hardware keyboard's commands on the iPad (and on an iPhone with a keyboard), in iPadOS's menu bar and in the
// list that holding ⌘ shows, with the Mac's keys for the commands both have (mac/Verso/Verso/App/VersoApp.swift,
// AppCommands; SPEC.md, "On the iPad"): Settings… (⌘,) opens the account's sheet, where Verso's settings are; New
// Album… (⌥⌘N), Import from Photos… and Import from Files… (⇧⌘I) in File; Find (⌘F) in Edit, which opens Search; and
// Years, Months and All (⌘1, ⌘2, ⌘3) in View. Each window publishes what they act on (LibraryWindow); the window in
// front acts.
//
// The keys of a photo open in the viewer (the arrows, Space, ".", ⌘I, ⌘⌫, Esc) are the viewer's own (ViewerKeys), and
// those of a selection (⌘A, ".", ⌘⌫, Esc) the grid's (TimelineCollection): the menu bar's commands come after the
// scroll views' own use of the arrows and Space, and the key a photo or a selection needs is theirs where they show.
// iPadOS's own Edit menu holds ⌘A (Select All, for text), and a key the menu bar holds twice ends the app as its menu
// is built, so ⌘A stays the text's and Select All's button's (AssetGridPage). Its text styles (Bold, Italic, Underline)
// go, which Verso, with no styled text, has no use for, so ⌘I is the viewer's Show Info alone.

import SwiftUI

/// A window's tabs, as the keyboard's commands reach them.
@MainActor struct LibraryWindow {
    let chrome: LibraryChrome
    let session: LibrarySession

    /// A sheet of the window's own shows over its pages: the account's, an import's pickers, an album's, the Backup page.
    var presents: Bool {
        chrome.accountShown || chrome.choosingPhotos || chrome.choosingFiles || session.albumActions.choosing != nil
            || session.albumActions.creating || BackupCenter.shared.pageShown
    }

    /// The viewer in front, while it is open and nothing shows over it.
    var viewer: ViewerState? {
        guard !presents, let viewer = chrome.viewers.last, viewer.isOpen, !viewer.covered else { return nil }
        return viewer
    }
}

extension FocusedValues {
    @Entry var libraryWindow: LibraryWindow?
}

struct VersoCommands: Commands {
    @FocusedValue(\.libraryWindow) private var window

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { window?.chrome.accountShown = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(window == nil || window?.presents == true || window?.viewer != nil)
        }

        CommandGroup(after: .newItem) {
            let canImport = window.map { ImportCoordinator.of($0.session.upload).canStart } ?? false
            Button("New Album…") { window?.session.albumActions.newAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(window == nil || window?.presents == true)
            Button("Import from Photos…") { window?.chrome.choosingPhotos = true }
                .disabled(!canImport || window?.presents == true)
            Button("Import from Files…") { window?.chrome.choosingFiles = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!canImport || window?.presents == true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find") { window?.chrome.findInSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(window == nil || window?.presents == true || window?.viewer != nil)
        }

        CommandGroup(replacing: .textFormatting) {}

        CommandGroup(before: .toolbar) {
            libraryModeItem(.years, key: "1")
            libraryModeItem(.months, key: "2")
            libraryModeItem(.all, key: "3")
        }
    }

    // MARK: View

    /// Library's Years, Months or All, with Photos' ⌘1, ⌘2 and ⌘3: the Library's own page, shown at that view.
    private func libraryModeItem(_ mode: LibraryMode, key: KeyEquivalent) -> some View {
        Toggle(isOn: Binding(get: { window?.chrome.libraryMode == mode && window?.chrome.selectedTab == .library },
                             set: { _ in
                                 guard let chrome = window?.chrome else { return }
                                 chrome.path(for: .library).routes = []
                                 chrome.selectedTab = .library
                                 chrome.libraryMode = mode
                             })) {
            Text(mode.title)
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(window == nil || window?.presents == true || window?.viewer != nil
            || window?.chrome.isSelecting == true)
    }
}
