import AVKit
import SwiftUI

// The viewer on the TV, as the iPhone's (ios/Verso/Viewer/PhotoViewer.swift) where a remote can have it: a photo filling
// the screen, the preview first and then the full-size image a 4K screen wants; left and right step through the photos of
// the page, and a click brings up what the iPhone's title capsule says, its place over its day and time, and takes it
// away again. A Live Photo wears the iPhone's LIVE badge, and play/pause plays its movie over the photo. A video plays
// with the system's controls, as tvOS's own.

struct TVViewer: View {
    @State private var items: [TVItem]
    @State private var index: Int
    @State private var image: CGImage?
    @State private var player: AVPlayer?
    @State private var details: AssetResponse?
    @State private var showsInfo = false
    @State private var exhausted = false
    private let more: (@MainActor () async -> [TVItem]?)?
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(viewing: TVViewing) {
        _items = State(initialValue: viewing.items)
        _index = State(initialValue: viewing.index)
        more = viewing.more
        #if DEBUG
        // A development build opens with the title capsule up (`-tvShowInfo`), to look at it.
        _showsInfo = State(initialValue: UserDefaults.standard.bool(forKey: "tvShowInfo"))
        #endif
    }

    private var debugLive: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "tvShowLive")
        #else
        false
        #endif
    }

    private var item: TVItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black
            if let player, item?.isVideo == true {
                VideoPlayer(player: player)
            } else {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
                if let player { TVPlayerView(player: player) }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome }
        .modifier(TVRemote(left: { step(-1) }, right: { step(1) }, select: { showsInfo.toggle() },
                           playPause: { playLive() }, menu: { dismiss() }))
        .task(id: index) { await show() }
        .task(id: "\(item?.id ?? "")|\(showsInfo)") { await readDetails() }
    }

    // MARK: Chrome

    /// The LIVE badge at the leading edge, and the title capsule in the middle once a click has asked for it.
    private var chrome: some View {
        ZStack(alignment: .top) {
            HStack {
                if item?.livePhotoVideoID != nil || debugLive { TVLiveBadge() }
                Spacer(minLength: 0)
            }
            if showsInfo, let item {
                let titles = titles(for: item)
                TVTitleCapsule(title: titles.title, subtitle: titles.subtitle)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 50)
    }

    /// As the iPhone titles a photo: its place over the day and time; with no place, the day over the time.
    private func titles(for item: TVItem) -> (title: String, subtitle: String) {
        let exif = details?.exifInfo
        let place = [exif?.city, exif?.state, exif?.country].compactMap { $0 }.first { !$0.isEmpty }
        guard let date = details.flatMap({ ImmichDate.parse($0.localDateTime) }) ?? item.date else { return (place ?? "", "") }
        let day = TVFormat.day(date)
        if let place { return (place, day + " " + ImmichDate.time(date)) }
        return (day, ImmichDate.time(date))
    }

    private func readDetails() async {
        guard showsInfo, let item, details?.id != item.id, let client = model.client else { return }
        details = nil
        let read: AssetResponse? = try? await client.get("assets/\(item.id)")
        guard !Task.isCancelled else { return }
        details = read
    }

    // MARK: Stepping

    private func step(_ by: Int) {
        let next = index + by
        guard items.indices.contains(next) else { return }
        index = next
        // Near the last photo read, the page reads on.
        if by > 0, !exhausted, let more, next >= items.count - 3 {
            Task {
                let known = items.count
                if let all = await more(), all.count > known { items = all } else { exhausted = true }
            }
        }
    }

    // MARK: Pictures and movies

    /// A Live Photo's movie, once, over the photo; then the photo again.
    private func playLive() {
        guard let live = item?.livePhotoVideoID, let client = model.client else { return }
        let playing = AVPlayerItem(asset: client.videoAsset(live))
        let player = AVPlayer(playerItem: playing)
        self.player = player
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playing, queue: .main) { _ in
            Task { @MainActor in if self.player === player { self.player = nil } }
        }
        player.play()
    }

    private func show() async {
        guard let item, let images = model.images, let client = model.client else { return }
        player?.pause()
        player = nil
        image = await images.thumbnail(item.id, size: .preview)
        if item.isVideo {
            let player = AVPlayer(playerItem: AVPlayerItem(asset: client.videoAsset(item.id)))
            self.player = player
            player.play()
            return
        }
        if let full = await images.thumbnail(item.id, size: .fullsize), self.item?.id == item.id {
            withAnimation(.easeInOut(duration: 0.3)) { image = full }
        }
    }
}

/// A Live Photo's badge, as the iPhone's: LIVE on glass tinted yellow with dark text, as the Camera's Live is yellow when
/// on. The remote's play/pause plays the movie.
struct TVLiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "livephoto")
            Text("LIVE")
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.yellow), in: .capsule)
        .accessibilityLabel(Text("Live Photo"))
    }
}

/// The place over the day and time in a glass capsule, as the iPhone's viewer titles a photo.
struct TVTitleCapsule: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 2) {
            if !title.isEmpty { Text(title).font(.headline).lineLimit(1) }
            if !subtitle.isEmpty { Text(subtitle).font(.callout.weight(.medium)).lineLimit(1) }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .opacity(title.isEmpty && subtitle.isEmpty ? 0 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A movie filling the screen as its photo would, without the player's controls: a Live Photo's, and a story's video.
struct TVPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
