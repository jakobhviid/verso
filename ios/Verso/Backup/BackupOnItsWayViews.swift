// On Its Way, at the top of the Backup page (ROADMAP.md, M10, "Backing the iPhone up"): the photos waiting or
// uploading, newest first, read from the backup's store and shown from the phone (BackupPhoneTile), each with its
// state's mark. A tap opens the photo from the phone (PhoneViewer), where it can be shared at once. The page shows the
// newest few rows; Show All opens every one in a grid of its own, read a page at a time.

import SwiftUI

/// The Backup page's On Its Way: the newest photos on their way, and Show All when there are more. The page reads them
/// (`load`) and opens the one tapped.
struct BackupOnItsWaySection: View {
    /// How many the page shows before Show All.
    static let shown = 30

    let photos: [BackupWaitingPhoto]
    let zoomNamespace: Namespace.ID
    let open: (BackupWaitingPhoto) -> Void
    @State private var width: CGFloat = 0

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        let count = center.waitingCount
        Section {
            // The photos stand on the page, as a grid of Photos' does, in the list's width.
            BackupOnItsWayGrid(photos: photos, width: width, zoomNamespace: zoomNamespace, open: open)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if count > photos.count {
                NavigationLink {
                    BackupOnItsWayPage()
                } label: {
                    Text("Show All \(count.formatted())")
                }
            }
        } header: {
            Text("On Its Way")
                .accessibilityIdentifier("On Its Way")
        } footer: {
            Text("Newest first, from this \(DeviceWords.model). Tap one to see or share it now.")
        }
    }

    /// The newest photos on their way, for the page to show.
    @MainActor
    static func load() async -> [BackupWaitingPhoto] {
        await BackupCenter.shared.waitingPhotos(limit: shown)
    }
}

/// Every photo on its way, in a grid of its own, newest first, read a page at a time as it scrolls.
struct BackupOnItsWayPage: View {
    @State private var photos: [BackupWaitingPhoto] = []
    @State private var opened: OpenedAsset?
    @State private var width: CGFloat = 0
    @State private var finished = false
    @Namespace private var zoomNamespace

    private var center: BackupCenter { BackupCenter.shared }
    private let page = 300

    var body: some View {
        ScrollView {
            BackupOnItsWayGrid(photos: photos, width: width, zoomNamespace: zoomNamespace, onLast: loadMore) { photo in
                opened = OpenedAsset(id: photo.localID)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .overlay {
            if finished && photos.isEmpty {
                ContentUnavailableView("Everything Is in Immich", systemImage: "checkmark.icloud")
            }
        }
        .navigationTitle("On Its Way")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: center.snapshot) { await reload() }
        .fullScreenCover(item: $opened) { opened in
            PhoneViewer(session: nil, photos: photos, startID: opened.id)
                .navigationTransition(.zoom(sourceID: opened.id, in: zoomNamespace))
        }
    }

    /// The pages read so far, read again as backing up moves on.
    private func reload() async {
        let fresh = await center.waitingPhotos(limit: max(page, photos.count))
        if fresh != photos { photos = fresh }
        finished = true
    }

    private func loadMore() {
        Task {
            let more = await center.waitingPhotos(limit: page, offset: photos.count)
            let known = Set(photos.map(\.localID))
            photos += more.filter { !known.contains($0.localID) }
        }
    }
}

/// Photos on their way as square tiles, five to a row on a phone, each with its mark.
private struct BackupOnItsWayGrid: View {
    let photos: [BackupWaitingPhoto]
    let width: CGFloat
    let zoomNamespace: Namespace.ID
    var onLast: (() -> Void)? = nil
    let open: (BackupWaitingPhoto) -> Void

    private let spacing: CGFloat = 2
    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        let columns = max(1, Int((width / 78).rounded()))
        let side = max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns), spacing: spacing) {
            ForEach(photos) { photo in
                BackupPhoneTile(photo: photo, mark: center.mark(photo), side: side)
                    .matchedTransitionSource(id: photo.localID, in: zoomNamespace)
                    .onTapGesture { open(photo) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(BackupPhoneTileLabel.text(photo, mark: center.mark(photo)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("On Its Way Tile")
                    .onAppear { if photo.localID == photos.last?.localID { onLast?() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What VoiceOver says of a photo on its way: its kind, its day, a favourite, and where it stands.
enum BackupPhoneTileLabel {
    static func text(_ photo: BackupWaitingPhoto, mark: BackupTileMark?) -> String {
        var parts = [photo.isVideo ? "Video" : "Photo"]
        if let created = photo.created { parts.append(created.formatted(date: .abbreviated, time: .shortened)) }
        if photo.favorite { parts.append("Favorite") }
        parts.append(mark?.words ?? "In Immich")
        return parts.joined(separator: ", ")
    }
}
