// A memory full screen, as a story: its photos one by one on black, each for the time the account sets in Immich
// (five seconds by default), with a bar for each photo along the top that fills as it shows. A tap on the right two
// thirds goes on, a tap on the left third goes back, and holding a finger on the photo pauses it and hides the
// controls until it lifts. As a memory ends the next one plays, as Immich's own app goes on; after the last the story
// closes. A photo's time starts once it shows, so a slow server never skips one. A video plays, with its sound as the
// ring switch allows, for its own length, over its preview until it can.
//
// The controls float in glass over the photo: Close, and Share (the photo's original, through the system's share
// sheet), Keep (as the Mac's memory actions: Immich's cleanup removes a memory after 30 days unless it is kept) and the
// memory's menu (Show as Grid, Remove from This Memory, Delete Memory). Nothing moves but for what the person does:
// the photos change at once, without a fade. It opens out of its card with the zoom transition and is dragged down
// back into it.

import AVFoundation
import SwiftUI

struct MemoryStory: View {
    let model: MemoriesModel
    /// Shows a memory's photos as a grid, once the story has closed.
    let showGrid: (ExploreMemory) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var memoryID: String
    @State private var photoIndex = 0
    /// The photo shown, and which photo it is.
    @State private var image: CGImage?
    @State private var imageAssetID: String?
    /// The photo whose loading has ended, shown or failed: its time runs from then.
    @State private var readyAssetID: String?
    /// A video's player, and which video it plays.
    @State private var player: AVPlayer?
    @State private var playerAssetID: String?
    /// How long the photo shows: a video's own length, else the account's setting.
    @State private var photoDuration: TimeInterval?
    /// A finger is held on the photo.
    @State private var holding = false
    @State private var controlsHidden = false
    /// How long the photo has shown before the last pause, and since when it shows again.
    @State private var elapsed: TimeInterval = 0
    @State private var runningSince: Date?
    /// Counts the photos shown, so showing the same photo again from its start starts its time again.
    @State private var showings = 0
    @State private var downloading = false
    @State private var sharing: ExploreSharedFile?
    /// The download being shared, removed once the share sheet closes.
    @State private var sharedFile: ExploreSharedFile?
    @State private var removing: AssetResponse?
    @State private var confirmingDelete = false
    @State private var error: String?

    init(model: MemoriesModel, startID: String, showGrid: @escaping (ExploreMemory) -> Void) {
        self.model = model
        self.showGrid = showGrid
        _memoryID = State(initialValue: startID)
    }

    private var session: LibrarySession { model.session }
    private var pipeline: ImagePipeline { model.session.pipeline }
    private var memory: ExploreMemory? { model.memory(memoryID) }
    private var assets: [AssetResponse] { memory?.assets ?? [] }
    private var asset: AssetResponse? { assets.indices.contains(photoIndex) ? assets[photoIndex] : nil }
    private var duration: TimeInterval { photoDuration ?? TimeInterval(model.duration) }

    /// Whether the photo's time runs: it shows, and nothing holds it.
    private var running: Bool {
        guard let asset, readyAssetID == asset.id else { return false }
        return !holding && !downloading && sharing == nil && removing == nil && !confirmingDelete && error == nil
            && scenePhase == .active
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            photo
            touchArea
            controls
                .opacity(controlsHidden ? 0 : 1)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: running) { _, nowRunning in
            if nowRunning {
                runningSince = .now
                player?.play()
            } else {
                player?.pause()
                if let since = runningSince {
                    elapsed += Date.now.timeIntervalSince(since)
                    runningSince = nil
                }
            }
        }
        .onDisappear { player?.pause() }
        // The photo's remaining time, again after each pause.
        .task(id: AdvanceKey(showing: showings, running: running)) {
            guard running else { return }
            let remaining = max(0, duration - elapsed)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            next()
        }
        .task(id: asset?.id) { await loadPhoto() }
        .task(id: memoryID) { model.markSeen(memoryID) }
        .sheet(item: $sharing, onDismiss: removeSharedFile) { file in
            ExploreShareSheet(file: file)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("Remove This Photo from the Memory?", isPresented: removingShown, titleVisibility: .visible,
                            presenting: removing) { asset in
            Button("Remove from Memory", role: .destructive) { remove(asset) }
        } message: { _ in
            Text("The photo stays in your library.")
        }
        .confirmationDialog("Delete This Memory?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Memory", role: .destructive) { deleteMemory() }
        } message: {
            Text("The photos in it stay in your library.")
        }
        .alert("Can't Change This Memory", isPresented: errorShown) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: The photo

    /// The photo, or a video over its preview.
    private var photo: some View {
        ZStack {
            let playing = player != nil && asset != nil && playerAssetID == asset?.id
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else if let asset, readyAssetID == asset.id {
                if !playing {
                    ContentUnavailableView("Can't Load This Photo", systemImage: "photo")
                        .foregroundStyle(.white)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
            if playing, let player {
                MemoryStoryVideo(player: player)
                    .ignoresSafeArea()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(asset?.originalFileName ?? "")
    }

    /// Taps on the left third go back, on the rest on; a finger held pauses.
    private var touchArea: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    if location.x < geometry.size.width / 3 { previous() } else { next() }
                }
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) {
                    withAnimation(.easeOut(duration: 0.2)) { controlsHidden = true }
                } onPressingChanged: { pressing in
                    holding = pressing
                    if !pressing && controlsHidden {
                        withAnimation(.easeOut(duration: 0.2)) { controlsHidden = false }
                    }
                }
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel(memory?.title ?? "")
        .accessibilityValue(Text("Photo \(photoIndex + 1) of \(assets.count)"))
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: "Next Photo") { next() }
        .accessibilityAction(named: "Previous Photo") { previous() }
    }

    // MARK: The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                MemoryStoryProgress(count: assets.count, index: photoIndex, progress: progress(at: context.date))
            }
            HStack(alignment: .center, spacing: 12) {
                GlassEffectContainer {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                }
                if let memory {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(memory.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(memory.dayLine)
                            .font(.caption)
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                }
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// Share, Keep and the memory's menu, in glass that merges where they meet.
    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { share() } label: {
                    if downloading {
                        ProgressView()
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(asset == nil || downloading)
                let kept = memory?.isSaved == true
                Button(kept ? "Kept" : "Keep", systemImage: kept ? "bookmark.fill" : "bookmark") { setKept(!kept) }
                    .accessibilityHint(kept ? "Immich won't remove it. Lets it go again."
                                            : "Immich removes a memory after 30 days unless it is kept.")
                Menu {
                    Button("Show as Grid", systemImage: "square.grid.2x2") {
                        guard let memory else { return }
                        showGrid(memory)
                        dismiss()
                    }
                    Button("Remove from This Memory…", systemImage: "minus.circle") { removing = asset }
                        .disabled(asset == nil)
                    Divider()
                    Button("Delete Memory…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Label("Memory", systemImage: "ellipsis")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
    }

    // MARK: Time

    private func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let shown = elapsed + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
        return min(1, max(0, shown / duration))
    }

    private struct AdvanceKey: Equatable {
        let showing: Int
        let running: Bool
    }

    private func next() {
        if photoIndex + 1 < assets.count {
            show(memoryID, photo: photoIndex + 1)
        } else if let following = neighbour(after: true) {
            show(following, photo: 0)
        } else {
            dismiss()
        }
    }

    private func previous() {
        if photoIndex > 0 {
            show(memoryID, photo: photoIndex - 1)
        } else if let preceding = neighbour(after: false) {
            show(preceding, photo: 0)
        } else {
            show(memoryID, photo: 0)
        }
    }

    /// The memory after or before this one in the list.
    private func neighbour(after: Bool) -> String? {
        guard let index = model.memories.firstIndex(where: { $0.id == memoryID }) else { return nil }
        let other = after ? index + 1 : index - 1
        return model.memories.indices.contains(other) ? model.memories[other].id : nil
    }

    /// Shows a photo from its start.
    private func show(_ id: String, photo index: Int) {
        let sameAsset = asset?.id
        memoryID = id
        photoIndex = index
        showings += 1
        elapsed = 0
        if asset?.id == sameAsset {
            // The same photo again, from its start.
            player?.seek(to: .zero)
            if running { player?.play() }
        } else {
            player?.pause()
            player = nil
            playerAssetID = nil
            photoDuration = nil
        }
        runningSince = running ? .now : nil
    }

    private func loadPhoto() async {
        guard let asset else { return }
        let id = asset.id
        await loadPreview(id)
        guard !Task.isCancelled else { return }
        if asset.type == .video {
            await prepareVideo(id)
            guard !Task.isCancelled else { return }
        }
        readyAssetID = id
        prefetchNext()
    }

    private func loadPreview(_ id: String) async {
        if let cached = pipeline.cachedThumbnail(id, size: .preview) {
            image = cached
            imageAssetID = id
            return
        }
        // The small thumbnail, where it is at hand, until the preview comes; else the last photo stays until then.
        if let small = pipeline.cachedThumbnail(id, size: .thumbnail) {
            image = small
            imageAssetID = id
        }
        let preview = await pipeline.thumbnail(id, size: .preview)
        guard !Task.isCancelled else { return }
        if let preview {
            image = preview
            imageAssetID = id
        } else if imageAssetID != id {
            image = nil
        }
    }

    /// A video's player, once its length is known; a video that cannot be read shows its preview for the usual time.
    private func prepareVideo(_ id: String) async {
        let client = session.client
        let video = AVURLAsset(url: client.videoURL(id), options: ["AVURLAssetHTTPHeaderFieldsKey": client.credential?.headers ?? [:]])
        guard let length = try? await video.load(.duration), !Task.isCancelled else { return }
        player = AVPlayer(playerItem: AVPlayerItem(asset: video))
        playerAssetID = id
        if length.seconds.isFinite, length.seconds > 0 { photoDuration = length.seconds }
    }

    /// The next photo's preview loads while this one shows, so it shows at once.
    private func prefetchNext() {
        let nextID: String? = if photoIndex + 1 < assets.count {
            assets[photoIndex + 1].id
        } else {
            neighbour(after: true).flatMap { model.memory($0)?.assets.first?.id }
        }
        guard let nextID, pipeline.cachedThumbnail(nextID, size: .preview) == nil else { return }
        let pipeline = pipeline
        Task { _ = await pipeline.thumbnail(nextID, size: .preview) }
    }

    // MARK: Actions

    private func share() {
        guard let asset else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let file = try await ExploreSharedFile.download(asset, client: session.client)
                sharedFile = file
                sharing = file
            } catch {
                report(error)
            }
        }
    }

    private func removeSharedFile() {
        sharedFile?.remove()
        sharedFile = nil
    }

    private func setKept(_ keep: Bool) {
        let id = memoryID
        Task {
            do { try await model.setKept(id, keep) }
            catch { report(error) }
        }
    }

    private func remove(_ asset: AssetResponse) {
        let id = memoryID
        let following = neighbour(after: true)
        Task {
            do {
                try await model.remove(asset.id, from: id)
                guard memoryID == id else { return }
                if model.memory(id) == nil {
                    if let following { show(following, photo: 0) } else { dismiss() }
                } else {
                    show(id, photo: min(photoIndex, max(0, assets.count - 1)))
                }
            } catch {
                report(error)
            }
        }
    }

    private func deleteMemory() {
        let id = memoryID
        let following = neighbour(after: true)
        Task {
            do {
                try await model.delete(id)
                guard memoryID == id else { return }
                if let following { show(following, photo: 0) } else { dismiss() }
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        session.handle(error)
        self.error = error.localizedDescription
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { shown in if !shown { removing = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }
}

/// A bar for each photo along the top: the ones shown full, the one showing filling, the rest empty. A memory of very
/// many photos has one bar that fills across them all, as bars a point wide could not be read.
struct MemoryStoryProgress: View {
    let count: Int
    let index: Int
    /// How far the photo showing is, from 0 to 1.
    let progress: Double

    var body: some View {
        HStack(spacing: 3) {
            if count > 30 {
                bar(filled: count > 0 ? (Double(index) + progress) / Double(count) : 0)
            } else {
                ForEach(0..<count, id: \.self) { position in
                    bar(filled: position < index ? 1 : position == index ? progress : 0)
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func bar(filled: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.white)
                    .scaleEffect(x: filled, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
    }
}

/// A memory's video, filling the screen as its photo would, without the player's controls.
struct MemoryStoryVideo: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MemoryStoryVideoView {
        let view = MemoryStoryVideoView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: MemoryStoryVideoView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// A view whose layer is the player's.
final class MemoryStoryVideoView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
