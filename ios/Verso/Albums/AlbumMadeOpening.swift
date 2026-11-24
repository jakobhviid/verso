// Opening an album made from photos chosen in a grid (New Album with the selection), as the Mac opens it: once the
// window's New Album sheet has made it, `AlbumsActions.navigationAlbumID` names it, and the stack of the tab shown
// pushes it as a `Route`. Albums' own New Album pushes the album it makes itself (AlbumsView).

import SwiftUI

extension View {
    /// Pushes an album made from a selection onto this stack while its tab is the one shown. Each tab's NavigationStack
    /// applies it to its root view, inside the stack, where `pushRoute` is the stack's own.
    func opensAlbumMade(session: LibrarySession, whileShown isShown: Bool) -> some View {
        modifier(AlbumMadeOpening(session: session, isShown: isShown))
    }
}

private struct AlbumMadeOpening: ViewModifier {
    let session: LibrarySession
    let isShown: Bool
    @Environment(\.pushRoute) private var pushRoute

    func body(content: Content) -> some View {
        content.onChange(of: session.albumActions.navigationAlbumID) { _, albumID in
            guard isShown, let albumID else { return }
            session.albumActions.navigationAlbumID = nil
            // The sheet reads the albums again before it names the new one, so the list has it, with its cover and
            // owner; the album page reads the rest.
            let album = session.albums.first { $0.id == albumID }
                ?? Album(id: albumID, albumName: "", assetCount: 0, shared: false)
            pushRoute(.album(album))
        }
    }
}
