import AVKit
import SwiftUI

// The viewer on the TV, as the iPhone's (ios/Verso/Viewer/PhotoViewer.swift) where a remote can have it: a photo filling
// the screen, the preview first and then the full-size image a 4K screen wants; left and right slide to the photo beside
// it, as the iPhone's pages slide, and a click brings up what the iPhone's title capsule says, its place over its day
// and time, and takes it away again. It opens out of its tile and closes into the tile of the photo shown last
// (TVViewerCover). A Live Photo has the Live Photo sign small in the corner, and play/pause plays its movie over the
// photo. A video plays in tvOS's own player, which has the remote while it plays: its transport bar, scrubbing with a
// swipe, its info panel with the place and the day, and a click on the remote's edge steps to the photo beside it. Once a video in HDR has put the TV in HDR, it stays
// there until the viewer closes (TVDisplayMode), rather than going back to SDR and again to HDR from photo to photo.

struct TVViewer: View {
    @State private var items: [TVItem]
    @State private var index: Int
    /// The movie playing, a video's or a Live Photo's, and the photo it belongs to.
    @State private var player: AVPlayer?
    @State private var playerItemID: String?
    @State private var details: AssetResponse?
    @State private var showsInfo = false
    @State private var exhausted = false
    @State private var readingOn = false
    /// The way the last step went, which the pages slide by: 1 to the next, -1 to the previous.
    @State private var direction = 1
    private let more: (@MainActor () async -> [TVItem]?)?
    /// Told of each photo shown, so the page under the viewer keeps its tile in view to close into.
    private let shown: (String) -> Void
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(viewing: TVViewing, shown: @escaping (String) -> Void = { _ in }) {
        _items = State(initialValue: viewing.items)
        _index = State(initialValue: viewing.index)
        more = viewing.more
        self.shown = shown
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

    /// A video is playing in the system's player, which then has the remote.
    private var playingVideo: Bool { item?.isVideo == true && player != nil && playerItemID == item?.id }

    var body: some View {
        ZStack {
            Color.black
            if let item {
                // Above the black, or the photo leaving is drawn under it and vanishes rather than sliding away.
                TVViewerPage(item: item, player: playerItemID == item.id ? player : nil,
                             canSkip: (back: index > 0, forward: index < items.count - 1 || (more != nil && !exhausted)),
                             skip: { step($0) })
                    .id(item.id)
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading),
                                            removal: .move(edge: direction > 0 ? .leading : .trailing)))
            }
        }
        .clipped()
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome }
        .overlay(alignment: .topLeading) { liveSign }
        .modifier(TVRemote(left: { step(-1) }, right: { step(1) }, select: { showsInfo.toggle() },
                           playPause: { playLive() }, menu: { dismiss() }, takesFocus: !playingVideo))
        .modifier(TVPhotoMenu(item: playingVideo ? nil : item, changed: apply))
        .task(id: item?.id) { await show() }
        .task(id: "\(item?.id ?? "")|\(showsInfo)") { await readDetails() }
        .onDisappear { TVDisplayMode.release() }
        .task { await followDebugSteps() }
    }

    /// A development build steps by itself (`-tvViewerSteps right,right,left,close`, one every two seconds), as the
    /// Simulator has no remote to drive it with, for a recording of the slides and the zoom.
    private func followDebugSteps() async {
        #if DEBUG
        guard let steps = UserDefaults.standard.string(forKey: "tvViewerSteps") else { return }
        for move in steps.split(separator: ",") {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            switch move {
            case "right": step(1)
            case "left": step(-1)
            case "close": dismiss()
            default: break
            }
        }
        #endif
    }

    // MARK: Chrome

    /// The title capsule in the middle, once a click has asked for it.
    private var chrome: some View {
        ZStack(alignment: .top) {
            if showsInfo, let item {
                let titles = titles(for: item)
                TVTitleCapsule(title: titles.title, subtitle: titles.subtitle)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 50)
    }

    /// A Live Photo's sign, small in the corner, out of the photo's way: it says play/pause plays the movie.
    @ViewBuilder
    private var liveSign: some View {
        if item?.livePhotoVideoID != nil || debugLive {
            Image(systemName: "livephoto")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(36)
                .ignoresSafeArea()
                .accessibilityLabel(Text("Live Photo"))
        }
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
        guard items.indices.contains(next) else {
            // Past the last photo read: the page reads on, and the step follows once it has.
            if by > 0 { Task { if await readOn() { step(by) } } }
            return
        }
        direction = by
        withAnimation(.smooth(duration: 0.35)) { index = next }
        // Near the last photo read, the page reads on.
        if by > 0, next >= items.count - 3 { Task { await readOn() } }
    }

    /// The photos after the last read, from the page; false when there are none.
    @discardableResult
    private func readOn() async -> Bool {
        guard !exhausted, !readingOn, let more else { return false }
        readingOn = true
        defer { readingOn = false }
        let known = items.count
        guard let all = await more(), all.count > known else {
            exhausted = true
            return false
        }
        items = all
        return true
    }

    /// A photo the menu changed: its heart, or gone, the next taking its place, and the viewer closing after the last.
    private func apply(_ change: TVPhotoChange) {
        guard let at = items.firstIndex(where: { $0.id == change.id }) else { return }
        if case .favorite(_, let on) = change {
            items[at].isFavorite = on
            return
        }
        direction = 1
        withAnimation(.smooth(duration: 0.35)) {
            items.remove(at: at)
            index = min(index, items.count - 1)
        }
        if items.isEmpty { dismiss() }
    }

    // MARK: Movies

    /// A Live Photo's movie, once, over the photo; then the photo again.
    private func playLive() {
        guard let item, let live = item.livePhotoVideoID, let client = model.client else { return }
        let playing = AVPlayerItem(asset: client.videoAsset(live))
        let player = AVPlayer(playerItem: playing)
        self.player = player
        playerItemID = item.id
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playing, queue: .main) { _ in
            Task { @MainActor in
                if self.player === player {
                    self.player = nil
                    self.playerItemID = nil
                }
            }
        }
        player.play()
    }

    /// The photo shown: the page under the viewer is told, and a video starts, holding the TV in HDR where it is HDR.
    private func show() async {
        guard let item, let client = model.client else { return }
        shown(item.id)
        player?.pause()
        player = nil
        playerItemID = nil
        guard item.isVideo else { return }
        let asset = client.videoAsset(item.id)
        await TVDisplayMode.holdHDR(for: asset)
        guard !Task.isCancelled, self.item?.id == item.id else { return }
        let playing = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playing)
        self.player = player
        playerItemID = item.id
        player.play()
        // The player's info panel says what the title capsule says of a photo.
        let read: AssetResponse? = try? await client.get("assets/\(item.id)")
        guard !Task.isCancelled, self.item?.id == item.id else { return }
        details = read
        let titles = titles(for: item)
        playing.externalMetadata = [(AVMetadataIdentifier.commonIdentifierTitle, titles.title),
                                    (AVMetadataIdentifier.iTunesMetadataTrackSubTitle, titles.subtitle)]
            .filter { !$0.1.isEmpty }
            .map { identifier, text in
                let entry = AVMutableMetadataItem()
                entry.identifier = identifier
                entry.value = text as NSString
                entry.extendedLanguageTag = "und"
                return entry
            }
    }
}

/// One photo of the viewer, which slides in and out whole: its preview at once where the grid read it, then the
/// full-size image; a video's player over it once playing.
private struct TVViewerPage: View {
    let item: TVItem
    let player: AVPlayer?
    /// Whether there is a photo before and after it, which a click on the remote's edge steps to from a video.
    let canSkip: (back: Bool, forward: Bool)
    let skip: (Int) -> Void
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let player, item.isVideo {
                TVVideoPlayer(player: player, canSkip: canSkip, skip: skip)
            } else {
                if let picture = image ?? model.images?.cachedThumbnail(item.id, size: .preview) {
                    Image(decorative: picture, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
                if let player { TVPlayerView(player: player) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        guard let images = model.images else { return }
        if image == nil { image = await images.thumbnail(item.id, size: .preview) }
        guard !item.isVideo, let full = await images.thumbnail(item.id, size: .fullsize), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { image = full }
    }
}

/// A video in tvOS's own player, with the remote: its transport bar, scrubbing, its info panel, and a click on the
/// remote's edge steps to the photo beside it (skipping by item, not by seconds). It leaves the TV's picture mode to
/// TVDisplayMode: the system's player would put the TV in each video's own mode and back again as it goes.
struct TVVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let canSkip: (back: Bool, forward: Bool)
    let skip: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(skip: skip) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.skippingBehavior = .skipItem
        controller.delegate = context.coordinator
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.isSkipBackwardEnabled = canSkip.back
        controller.isSkipForwardEnabled = canSkip.forward
        context.coordinator.skip = skip
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var skip: (Int) -> Void

        init(skip: @escaping (Int) -> Void) { self.skip = skip }

        func skipToNextItem(for playerViewController: AVPlayerViewController) { skip(1) }
        func skipToPreviousItem(for playerViewController: AVPlayerViewController) { skip(-1) }
    }
}

/// The TV's picture mode while the viewer is open. Where the person has Match Dynamic Range on, the first video in HDR
/// puts the TV in HDR, and it stays there until the viewer closes: switching to SDR for the photos and back for the next
/// video blacks the screen out each time. SDR photos show as they are in HDR's range.
@MainActor
enum TVDisplayMode {
    private static var held = false

    static func holdHDR(for asset: AVAsset) async {
        guard !held, let manager = displayManager, manager.isDisplayCriteriaMatchingEnabled,
              let track = try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo).first,
              let format = try? await track.load(.formatDescriptions).first, !held else { return }
        // The screen's own rate, not the video's, so the photos and their slides stay smooth.
        let rate = Float(displayWindow?.screen.maximumFramesPerSecond ?? 60)
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format)
        held = true
    }

    static func release() {
        guard held else { return }
        displayManager?.preferredDisplayCriteria = nil
        held = false
    }

    private static var displayWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    private static var displayManager: AVDisplayManager? { displayWindow?.avDisplayManager }
}

extension EnvironmentValues {
    /// The zoom a page's tiles open the viewer from (TVViewerCover).
    @Entry var tvZoom: Namespace.ID?
}

/// The viewer over a page of tiles, as the iPhone opens a photo: it grows out of its tile, and closes into the tile of
/// the photo shown last, which the page scrolls to under the viewer and the focus lands on after it.
struct TVViewerCover: ViewModifier {
    @Binding var viewing: TVViewing?
    var focused: FocusState<String?>.Binding
    /// Keeps a photo's tile in view; nil where the page cannot scroll to it.
    var scroll: ((String) -> Void)?
    @Namespace private var zoom
    @State private var shownID: String?

    func body(content: Content) -> some View {
        content
            .environment(\.tvZoom, zoom)
            .fullScreenCover(item: $viewing, onDismiss: closed) { viewing in
                TVViewer(viewing: viewing) { id in
                    shownID = id
                    scroll?(id)
                }
                .navigationTransition(.zoom(sourceID: shownID ?? viewing.startID, in: zoom))
            }
    }

    /// The focus on the tile of the photo shown last, and nothing kept for the next opening.
    private func closed() {
        guard let id = shownID else { return }
        shownID = nil
        // Once the viewer has gone: while it goes, tvOS puts the focus back where it was before it opened.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            focused.wrappedValue = id
        }
    }
}

extension View {
    /// A tile the viewer opens out of and closes into (TVViewerCover).
    @ViewBuilder
    func tvZoomSource(_ id: String, in zoom: Namespace.ID?) -> some View {
        if let zoom { matchedTransitionSource(id: id, in: zoom) } else { self }
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
