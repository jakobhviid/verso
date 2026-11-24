// A photo on its way to Immich, full screen, from the phone (ROADMAP.md, M10, "Backing the iPhone up"): a viewer of its
// own rather than the grid's (PhotoViewer), which pages through a grid's model of Immich's assets and loads each
// photo's details, edits, people and stack from Immich, none of which a photo on the phone has yet. It looks as that
// one does: the photos on black, swiped through left and right in the order of the grid it opened from, opening out of
// their tile with the zoom transition and dragged down back into it, a tap hiding every control. At the top Back, the
// day and time over where it stands (uploading, waiting, waiting for Wi-Fi, needing a look, or in Immich) in one
// capsule, and More, the menu of photo actions (PhotoActionsMenu) with what a photo on its way has beside the bottom
// bar: Copy, the phone's copy; Immich's actions show once it has arrived. Along the bottom Share, the phone's copy at
// once, then Favorite, set in Photos and carried with the upload, Info and Edit, which wait for Immich, then Delete,
// from the phone, which iOS asks about, after which it never uploads. A grid opens it with `phoneViewer`, a
// presentation of its own beside the grid's viewer.

import AVKit
import Photos
import SwiftUI

struct PhoneViewer: View {
    let session: LibrarySession?
    @State private var photos: [BackupWaitingPhoto]
    @State private var currentID: String
    @State private var chromeVisible = true
    @State private var sharing: GridAssetIDs?
    @State private var working = false
    @State private var copyError: String?
    @Environment(\.dismiss) private var dismiss
    /// Told the photo shown, so the grid keeps its tile in view and closing zooms back into it.
    var onShow: (String) -> Void = { _ in }

    /// `photos`: the grid's photos on their way in its reading order, left to right.
    init(session: LibrarySession?, photos: [BackupWaitingPhoto], startID: String, onShow: @escaping (String) -> Void = { _ in }) {
        self.session = session
        _photos = State(initialValue: photos)
        _currentID = State(initialValue: startID)
        self.onShow = onShow
    }

    private var center: BackupCenter { BackupCenter.shared }
    private var current: BackupWaitingPhoto? { photos.first { $0.localID == currentID } }

    var body: some View {
        NavigationStack {
            TabView(selection: $currentID) {
                ForEach(photos) { photo in
                    PhonePhotoPage(photo: photo)
                        .tag(photo.localID)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
            .toolbar { toolbar }
            .toolbarVisibility(chromeVisible ? .visible : .hidden, for: .navigationBar, .bottomBar)
            .statusBarHidden(!chromeVisible)
            .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
            .shareSheet(item: $sharing) { request in
                ShareContent(session: session, phoneIDs: request.ids)
            }
            .alert("Can't Copy the Photo", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })) {
                Button("OK") {}
            } message: {
                Text(copyError ?? "")
            }
        }
        .onChange(of: currentID, initial: true) { _, id in onShow(id) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Back", systemImage: "chevron.backward") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            PhoneTitleCapsule(title: title, subtitle: standing)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                PhotoActionsMenu(context: moreContext) { action in
                    if case .copy = action { copy() }
                }
            }
            .disabled(current == nil)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") { sharing = GridAssetIDs(ids: [currentID]) }
                .disabled(current == nil)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            let favorite = current?.favorite == true
            Button(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart") {
                setFavorite(!favorite)
            }
            .contentTransition(.symbolEffect(.replace))
            .disabled(current == nil || working)
            Button("Info", systemImage: "info.circle") {}
                .disabled(true)
                .accessibilityHint("On its way to Immich")
            Button("Edit", systemImage: "slider.horizontal.3") {}
                .disabled(true)
                .accessibilityHint("On its way to Immich")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash") { delete() }
                .disabled(current == nil || working)
        }
    }

    /// A photo on its way has Copy, Share, Favorite and Delete; the bottom bar has all but Copy.
    private var moreContext: PhotoActionsContext {
        var context = PhotoActionsContext(place: .viewer)
        context.copy = true
        context.share = true
        context.favorite = true
        context.allFavorite = current?.favorite == true
        context.delete = String(localized: "Delete from \(UIDevice.current.localizedModel)")
        return context
    }

    // MARK: Title

    /// Its day and time, by its own clock, as the grid's viewer names a photo's.
    private var title: String {
        guard let created = current?.created else { return "" }
        let wallClock = created.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: created)))
        return ViewerDays.name(wallClock) + " " + ImmichDate.time(wallClock)
    }

    /// Where it stands: in Immich once its upload landed, else its mark's words.
    private var standing: String {
        guard let current else { return "" }
        if let tile = center.libraryTiles.first(where: { $0.id == current.localID }), tile.arrivedAsset != nil {
            return "In Immich"
        }
        return center.mark(current).words
    }

    // MARK: Actions

    /// The phone's copy on the pasteboard.
    private func copy() {
        let id = currentID
        Task {
            do {
                try await PhotoActionWork.copy([], phone: [id], client: nil)
            } catch where !error.isCancellation {
                copyError = error.localizedDescription
            } catch {}
        }
    }

    private func setFavorite(_ favorite: Bool) {
        let id = currentID
        working = true
        Task {
            if await center.setFavorite([id], favorite), let index = photos.firstIndex(where: { $0.localID == id }) {
                photos[index].favorite = favorite
            }
            working = false
        }
    }

    /// Deletes it from the phone, which iOS asks about; the next photo shows, or the viewer closes after the last.
    private func delete() {
        let id = currentID
        working = true
        Task {
            if await center.deleteFromPhone([id]), let index = photos.firstIndex(where: { $0.localID == id }) {
                photos.remove(at: index)
                if photos.isEmpty {
                    dismiss()
                } else {
                    currentID = photos[min(index, photos.count - 1)].localID
                }
            }
            working = false
        }
    }
}

extension View {
    /// The Library grid's photos on their way, opened from the phone over the grid (GridPageState.openedPhone), in the
    /// grid's reading order so a swipe goes to the tile beside it, oldest first where the grid reads up to its newest
    /// photos at the bottom; closing zooms back into the tile of the photo shown last.
    func phoneViewer(session: LibrarySession, state: GridPageState, photos: [BackupWaitingPhoto], readsUp: Bool,
                     zoomNamespace: Namespace.ID) -> some View {
        @Bindable var state = state
        return fullScreenCover(item: $state.openedPhone) { opened in
            let ordered = photos.sorted { left, right in
                let earlier = (left.created ?? .distantPast) < (right.created ?? .distantPast)
                return readsUp ? earlier : !earlier
            }
            PhoneViewer(session: session, photos: ordered,
                        startID: BackupWaitingPhoto.localID(gridID: opened.id) ?? opened.id) { localID in
                state.shownPhone = BackupWaitingPhoto.gridPrefix + localID
            }
            .navigationTransition(.zoom(sourceID: state.shownPhone ?? opened.id, in: zoomNamespace))
        }
    }
}

/// The day and time over where the photo stands, in a glass capsule of its own, as the grid's viewer titles a photo.
private struct PhoneTitleCapsule: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Photo Title")
        .opacity(title.isEmpty && subtitle.isEmpty ? 0 : 1)
    }
}

/// One photo on its way, whole on black: its picture at the screen's size, or its video in the system's player.
private struct PhonePhotoPage: View {
    let photo: BackupWaitingPhoto
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: photo.localID) { await load(geometry.size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.isVideo ? "Video" : "Photo")
        .accessibilityIdentifier("Phone Photo")
    }

    private func load(_ size: CGSize) async {
        if photo.isVideo {
            if let item = await PhoneImages.playerItem(photo.localID) { player = AVPlayer(playerItem: item) }
            return
        }
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        for await picture in PhoneImages.pictures(photo.localID, size: pixels, mode: .aspectFit) {
            image = picture
        }
    }
}
