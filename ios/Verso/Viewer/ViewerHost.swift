// How the viewer shows on iOS: as on the Mac (AssetGridView), in place over the grid it opened from, rather than
// presented. Opening is at once: the viewer is there, its backdrop and controls fading in where they stand, while a
// picture of the photo flies out of its tile to its place (`ViewerFlight`), the photo's page hidden under it until it
// lands. Closing is at once too: the grid takes touches again as Back is pressed, while the picture flies back into the
// tile of the photo shown last and the backdrop and controls fade; a tile tapped meanwhile opens its photo there and
// then, in place of the one closing. Nothing waits for a transition to be reported done: UIKit's zoom, which this
// replaces, reported itself done about 1.0 s after it started, while its photo was home at 0.45 s, and its presented
// screen zoomed with the controls on it, so they could only come after it (ARCHITECTURE.md, "The viewer on the
// iPhone"). A drag down closes the viewer the same way, from where the finger has taken the photo (ViewerState.
// dragToClose). A photo whose tile is off screen, or whose picture is not at hand, fades instead.
//
// A host is put over the tabs, and over each viewer, for a viewer opened from its details (a person's photos, say);
// the grid pages find the nearest in their environment.

import SwiftUI
import UIKit

/// The tiles' anchors on one grid page, by their photo, for the photo's flight to start from and end in.
@MainActor final class ViewerZoomSources {
    private final class Entry {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var entries: [String: Entry] = [:]

    func register(_ view: UIView, for id: String) {
        entries[id] = Entry(view)
    }

    func unregister(_ view: UIView, for id: String) {
        if entries[id]?.view === view { entries[id] = nil }
    }

    /// The tile's anchor while it is on screen; else nothing, and the viewer closes without a tile to go to.
    func view(for id: String) -> UIView? {
        guard let view = entries[id]?.view, view.window != nil else { return nil }
        return view
    }

    /// Where the tile is in its window, and the window's size, while it is on screen.
    func frame(for id: String) -> (tile: CGRect, window: CGSize)? {
        guard let view = view(for: id), let window = view.window else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        return frame.isEmpty ? nil : (frame, window.bounds.size)
    }
}

/// A tile's anchor: an empty view of the tile's size, in its background.
struct ViewerZoomAnchor: UIViewRepresentable {
    let id: String
    let sources: ViewerZoomSources

    func makeUIView(context: Context) -> ViewerZoomAnchorView {
        let view = ViewerZoomAnchorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ViewerZoomAnchorView, context: Context) {
        if let previous = view.id, previous != id { sources.unregister(view, for: previous) }
        view.id = id
        sources.register(view, for: id)
    }

    static func dismantleUIView(_ view: ViewerZoomAnchorView, coordinator: ()) {
        view.id = nil
    }
}

final class ViewerZoomAnchorView: UIView {
    var id: String?
}

/// A viewer shown in place, over what the host is put on.
@MainActor @Observable final class ViewerHost {
    /// The viewer shown, from the tap on its tile until it has closed into it.
    private(set) var shown: ViewerShown?

    /// The photo's flight and the fades beside it: smooth, as the Mac's, and as quick as Photos', whose photo makes most
    /// of its way in about 0.2 s opening and 0.17 s closing.
    static let motion = Animation.smooth(duration: 0.26)

    /// Shows the photo `request` asks for, out of its tile, in place of a viewer still closing.
    func open(_ request: OpenedAsset, grid: GridPageState, session: LibrarySession, model: AssetGridModel,
              readsBackwards: Bool, pushRoute: PushRoute) {
        guard shown?.request != request else { return }
        let state = ViewerState(session: session, model: model, startID: request.id, readsBackwards: readsBackwards)
        let next = ViewerShown(request: request, state: state, grid: grid, pushRoute: pushRoute)
        // In the window, as the tiles and the pages measure themselves.
        if let found = grid.zoomSources.frame(for: request.id), let picture = picture(of: request.id, session) {
            state.flight = ViewerFlight(picture: picture, from: found.tile, to: state.fittedFrame(in: found.window))
        }
        shown = next
        // After the start has been drawn, so there is something to move from.
        Task { @MainActor [weak self] in
            guard self?.shown === next else { return }
            withAnimation(Self.motion) {
                state.flight?.landed = true
                state.isOpen = true
            } completion: {
                state.flight = nil
            }
        }
    }

    /// Closes the viewer into the tile of the photo shown, then does what comes next, such as opening a page on the tab.
    func close(then next: (() -> Void)? = nil) {
        guard let shown, !shown.closing else {
            next?()
            return
        }
        let state = shown.state
        shown.closing = true
        state.closingZoom?(true)
        // The grid is the person's again at once.
        shown.grid?.opened = nil
        if let found = shown.grid?.zoomSources.frame(for: state.currentID),
           let picture = picture(of: state.currentID, state.session) {
            state.flight = ViewerFlight(picture: picture, from: state.drawnFrame(in: found.window), to: found.tile)
        }
        Task { @MainActor [weak self] in
            withAnimation(Self.motion) {
                state.flight?.landed = true
                state.isOpen = false
            } completion: {
                if self?.shown === shown { self?.shown = nil }
                next?()
            }
        }
    }

    /// The grid it opened from has gone (the Locked Folder locking): the viewer goes with it, at once.
    func closeAtOnce(from grid: GridPageState) {
        guard let shown, shown.grid === grid || shown.grid == nil else { return }
        shown.grid?.opened = nil
        self.shown = nil
    }

    /// The picture a tile or a page shows, for the flight: the preview, else the thumbnail, as already loaded.
    private func picture(of id: String, _ session: LibrarySession) -> CGImage? {
        session.pipeline.cachedThumbnail(id, size: .preview) ?? session.pipeline.cachedThumbnail(id, size: .thumbnail)
    }
}

/// One viewer in a host.
@MainActor @Observable final class ViewerShown: Identifiable {
    let request: OpenedAsset
    let state: ViewerState
    weak var grid: GridPageState?
    @ObservationIgnored let pushRoute: PushRoute
    /// Closing: the grid behind takes touches again.
    var closing = false

    init(request: OpenedAsset, state: ViewerState, grid: GridPageState, pushRoute: PushRoute) {
        self.request = request
        self.state = state
        self.grid = grid
        self.pushRoute = pushRoute
    }
}

/// The photo on its way out of its tile or back: a picture of it, filling the frame it is in, so a square tile opens
/// out to the whole photo. Its frames are in the window.
struct ViewerFlight: Equatable {
    let picture: CGImage
    let from: CGRect
    let to: CGRect
    var landed = false

    var frame: CGRect { landed ? to : from }
}

/// The flying picture, drawn in a view whose place in the window is `origin`.
struct ViewerFlightPicture: View {
    let flight: ViewerFlight
    let origin: CGPoint

    var body: some View {
        let frame = flight.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        Image(decorative: flight.picture, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Shows a viewer in place over this view when a grid page under it opens a photo.
    func viewerHost() -> some View {
        modifier(ViewerHostModifier())
    }
}

private struct ViewerHostModifier: ViewModifier {
    @State private var host = ViewerHost()

    func body(content: Content) -> some View {
        let covering = host.shown.map { !$0.closing } ?? false
        content
            .overlay {
                ZStack {
                    if let shown = host.shown {
                        PhotoViewer(state: shown.state, host: host)
                            .environment(\.pushRoute, shown.pushRoute)
                            .id(shown.id)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(covering)
            }
            .environment(host)
    }
}
