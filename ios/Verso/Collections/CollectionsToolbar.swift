// Collections' toolbar on iOS (ROADMAP.md, M10), the one place the account shows, as Photos keeps the profile in
// Collections: a "+" menu, then the account's picture with a red badge counting the unread notifications, which its
// sheet opens with. The menu makes a New Album as Albums does (a name, then the album opens on Collections' stack),
// and starts an import into the library, from Photos or from Files (ImportPickers.swift). The window presents the
// account's sheet and the import's pickers (LibraryTabs), as the keyboard's commands ask for them too.

import SwiftUI

extension View {
    func collectionsToolbar(session: LibrarySession) -> some View {
        modifier(CollectionsToolbar(session: session))
    }
}

/// A modifier of its own, so photos being prepared for an import draw the toolbar again and not the page.
private struct CollectionsToolbar: ViewModifier {
    let session: LibrarySession
    @Environment(\.pushRoute) private var pushRoute
    /// The window's, which presents the account's sheet and the import's pickers, as the keyboard also asks for them.
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?
    @State private var naming = false
    @State private var newName = ""

    func body(content: Content) -> some View {
        let canImport = ImportCoordinator.of(session.upload).canStart
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button("New Album", systemImage: "rectangle.stack.badge.plus") {
                                newName = ""
                                naming = true
                            }
                        }
                        Section {
                            Button("Import from Photos…", systemImage: "photo.on.rectangle") { chrome?.choosingPhotos = true }
                            Button("Import from Files…", systemImage: "folder") { chrome?.choosingFiles = true }
                        }
                        .disabled(!canImport)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    AccountButton(services: session.services) { chrome?.accountShown = true }
                }
                // The button draws its own glass, a circle as the +'s: the toolbar's around a view of our own is a
                // capsule, wider than it is tall.
                .sharedBackgroundVisibility(.hidden)
            }
            .alert("New Album", isPresented: $naming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: createAlbum)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Enter a name for this album.")
            }
    }

    /// Makes the album, then opens it on Collections' stack, as Albums does; a failure is the window's Album Error.
    private func createAlbum() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let push = pushRoute
        Task {
            do {
                let made = try await session.client.createAlbum(name: name, assetIDs: [])
                await session.reloadAlbums()
                push(.album(session.albums.first { $0.id == made.id }
                    ?? Album(id: made.id, albumName: made.albumName, assetCount: made.assetCount, shared: made.shared)))
            } catch {
                session.handle(error)
                session.albumActions.error = error.localizedDescription
            }
        }
    }
}
