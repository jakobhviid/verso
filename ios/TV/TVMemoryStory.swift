import AVFoundation
import SwiftUI

// A memory full screen, as a story, as the iPhone's (ios/Verso/Memories/MemoryStory.swift): its photos one by one on
// black, each for the time the account sets in Immich (five seconds by default), with a bar for each photo along the top
// that fills as it shows, and what the memory recalls beside them. Right on the remote goes on and left goes back, a click
// or play/pause holds the photo and lets it go again, and Menu closes. As a memory ends the next one plays, as the
// iPhone's does; after the last the story closes. A photo's time starts once it shows, so a slow server never skips one.
// A video plays for its own length. A viewer changes nothing, so a memory is never marked seen from here.

struct TVMemoryStory: View {
    let memories: [ExploreMemory]
    let duration: Int
    @State private var memoryIndex: Int
    @State private var photoIndex = 0
    @State private var image: CGImage?
    /// The photo whose loading has ended, shown or failed: its time runs from then.
    @State private var readyAssetID: String?
    @State private var player: AVPlayer?
    /// How long the photo shows: a video's own length, else the account's setting.
    @State private var photoDuration: TimeInterval?
    @State private var held = false
    /// How long the photo has shown before the last pause, and since when it shows again.
    @State private var elapsed: TimeInterval = 0
    @State private var runningSince: Date?
    /// Counts the photos shown, so the same photo shown again starts its time again.
    @State private var showings = 0
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(memories: [ExploreMemory], start: Int, duration: Int) {
        self.memories = memories
        self.duration = duration
        _memoryIndex = State(initialValue: start)
    }

    private var memory: ExploreMemory? { memories.indices.contains(memoryIndex) ? memories[memoryIndex] : nil }
    private var assets: [AssetResponse] { memory?.assets ?? [] }
    private var asset: AssetResponse? { assets.indices.contains(photoIndex) ? assets[photoIndex] : nil }
    private var shownDuration: TimeInterval { photoDuration ?? TimeInterval(duration) }

    /// Whether the photo's time runs: it shows, and nothing holds it.
    private var running: Bool {
        guard let asset, readyAssetID == asset.id else { return false }
        return !held
    }

    var body: some View {
        ZStack {
            Color.black
            photo
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { top }
        .modifier(TVRemote(left: { previous() }, right: { next() }, select: { held.toggle() },
                           playPause: { held.toggle() }, menu: { dismiss() }))
        .onChange(of: running) { _, nowRunning in runningChanged(nowRunning) }
        .onDisappear { player?.pause() }
        // The photo's remaining time, again after each pause.
        .task(id: AdvanceKey(showing: showings, running: running)) { await advance() }
        .task(id: showings) { await loadPhoto() }
    }

    private func runningChanged(_ nowRunning: Bool) {
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

    /// Waits out what is left of the photo's time, then goes on.
    private func advance() async {
        guard running else { return }
        let remaining = max(0, shownDuration - elapsed)
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        next()
    }

    private struct AdvanceKey: Equatable {
        let showing: Int
        let running: Bool
    }

    // MARK: The photo

    private var photo: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let asset, readyAssetID == asset.id {
                ContentUnavailableView("Can't Load This Photo", systemImage: "photo").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            if let player { TVPlayerView(player: player) }
        }
    }

    /// The bars along the top, and the memory's title and day beneath them.
    private var top: some View {
        VStack(alignment: .leading, spacing: 20) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                TVStoryProgress(count: assets.count, index: photoIndex, progress: progress(at: context.date))
            }
            if let memory {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title).font(.headline)
                    Text(memory.dayLine).font(.callout).opacity(0.85)
                    if let about = memory.aboutLine { Text(about).font(.callout).opacity(0.85) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 50)
        .padding(.bottom, 50)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A fade under the words keeps them readable on a bright photo.
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    private func progress(at date: Date) -> Double {
        guard shownDuration > 0 else { return 0 }
        let live = runningSince.map { date.timeIntervalSince($0) } ?? 0
        return min(1, (elapsed + live) / shownDuration)
    }

    // MARK: Moving on

    private func next() {
        if photoIndex + 1 < assets.count {
            show(photo: photoIndex + 1, of: memoryIndex)
        } else if memoryIndex + 1 < memories.count {
            show(photo: 0, of: memoryIndex + 1)
        } else {
            dismiss()
        }
    }

    private func previous() {
        if photoIndex > 0 {
            show(photo: photoIndex - 1, of: memoryIndex)
        } else if memoryIndex > 0 {
            show(photo: max(0, memories[memoryIndex - 1].assets.count - 1), of: memoryIndex - 1)
        } else {
            show(photo: 0, of: memoryIndex)
        }
    }

    private func show(photo: Int, of memory: Int) {
        memoryIndex = memory
        photoIndex = photo
        showings += 1
        elapsed = 0
        runningSince = nil
        readyAssetID = nil
        photoDuration = nil
        player?.pause()
        player = nil
        image = nil
    }

    private func loadPhoto() async {
        guard let asset, let images = model.images, let client = model.client else { return }
        image = await images.thumbnail(asset.id, size: .preview)
        guard !Task.isCancelled else { return }
        if asset.type == .video {
            let video = client.videoAsset(asset.id)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: video))
            self.player = player
            if let length = try? await video.load(.duration).seconds, length.isFinite, length > 0 { photoDuration = length }
            guard !Task.isCancelled else { return }
            readyAssetID = asset.id
            return
        }
        readyAssetID = asset.id
        if let full = await images.thumbnail(asset.id, size: .fullsize), !Task.isCancelled { image = full }
    }
}

/// A bar for each photo along the top that fills as it shows; one bar for a long memory.
struct TVStoryProgress: View {
    let count: Int
    let index: Int
    /// How far the photo showing is, from 0 to 1.
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            if count > 30 {
                bar(filled: count > 0 ? (Double(index) + progress) / Double(count) : 0)
            } else {
                ForEach(0..<count, id: \.self) { position in
                    bar(filled: position < index ? 1 : position == index ? progress : 0)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func bar(filled: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .overlay(alignment: .leading) {
                Rectangle().fill(.white).scaleEffect(x: filled, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
    }
}
