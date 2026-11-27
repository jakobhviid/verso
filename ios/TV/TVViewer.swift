import AVKit
import SwiftUI

// The viewer on the TV, as the iPhone's (ios/Verso/Viewer/PhotoViewer.swift) where a remote can have it: a photo filling
// the screen, the preview first and then the full-size image a 4K screen wants; left and right slide to the photo beside
// it, as the iPhone's pages slide, and a click brings up what the iPhone's title capsule says, its place over its day
// and time, and takes it away again. It opens out of its tile and closes into the tile of the photo shown last
// (TVViewerCover). A Live Photo has the Live Photo sign small in the corner, and play/pause plays its movie over the
// photo. A video shows its first picture with a play sign; a click, or play/pause, opens it in tvOS's own player, full
// screen, which has the remote whole (its transport bar, scrubbing, its panels for audio, subtitles and the place and
// day), as Apple's TV app has it, and Menu comes back to the viewer at the video, where left and right step on. Once a
// video in HDR has put the TV in HDR, it stays there until the viewer closes (TVDisplayMode), rather than going back to
// SDR and again to HDR from photo to photo.

struct TVViewer: View {
    @State private var items: [TVItem]
    @State private var index: Int
    /// A Live Photo's movie playing over it, and the photo it belongs to.
    @State private var player: AVPlayer?
    @State private var playerItemID: String?
    /// The system's player, open full screen over the viewer for a video.
    @State private var video: TVVideoPresentation?
    @State private var details: AssetResponse?
    @State private var showsInfo = false
    @State private var exhausted = false
    @State private var readingOn = false
    /// The way the last step went, which the pages slide by: 1 to the next, -1 to the previous.
    @State private var direction = 1
    private let more: (@MainActor () async -> [TVItem]?)?
    /// Told of each photo shown, so the page under the viewer keeps its tile in view to close into.
    private let shown: (String) -> Void
    /// The page's tiles, which the viewer zooms out of and back into; nil where it opens from no page.
    private let frames: TVTileFrames?
    /// Full screen, or at its tile: out of it as the viewer opens, back into it as it closes.
    @State private var expanded: Bool
    /// The remote's focus, which the viewer takes as it opens, so the first click is its own.
    @FocusState private var hasFocus: Bool
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(viewing: TVViewing, frames: TVTileFrames? = nil, shown: @escaping (String) -> Void = { _ in }) {
        _items = State(initialValue: viewing.items)
        _index = State(initialValue: viewing.index)
        more = viewing.more
        self.frames = frames
        self.shown = shown
        _expanded = State(initialValue: frames?.frame(viewing.startID) == nil)
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
            Color.black.opacity(expanded ? 1 : 0)
            if let item {
                // Above the black, or the photo leaving is drawn under it and vanishes rather than sliding away.
                TVViewerPage(item: item, player: playerItemID == item.id ? player : nil,
                             tile: expanded ? nil : frames?.frame(item.id))
                    .id(item.id)
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading),
                                            removal: .move(edge: direction > 0 ? .leading : .trailing)))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome.opacity(expanded ? 1 : 0) }
        .overlay(alignment: .topLeading) { liveSign.opacity(expanded ? 1 : 0) }
        .modifier(TVRemote(left: { step(-1) }, right: { step(1) },
                           select: { if item?.isVideo == true { playVideo() } else { showsInfo.toggle() } },
                           playPause: { if item?.isVideo == true { playVideo() } else { playLive() } },
                           menu: { close() }))
        .focused($hasFocus)
        .defaultFocus($hasFocus, true)
        .task {
            // Once the cover is up: asked as it appears, tvOS leaves the focus where it was.
            try? await Task.sleep(for: .milliseconds(300))
            hasFocus = true
        }
        .modifier(TVPhotoMenu(item: item, changed: apply))
        .task(id: item?.id) { await show() }
        .task(id: "\(item?.id ?? "")|\(showsInfo)") { await readDetails() }
        .onDisappear { TVDisplayMode.release() }
        .task {
            // Out of its tile, once the viewer is on screen at the tile.
            guard !expanded else { return }
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(.smooth(duration: zoomSeconds(0.4))) { expanded = true }
        }
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
            case "close": close()
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

    /// Back into the tile of the photo shown, where it is on screen, then gone; else gone at once.
    private func close() {
        guard let item, frames?.frame(item.id) != nil else { return closeNow() }
        withAnimation(.smooth(duration: zoomSeconds(0.35))) { expanded = false } completion: { closeNow() }
    }

    /// The zoom's length; a development build slows it (`-tvZoomSeconds 4`) for stills of it in the Simulator, whose
    /// recordings leave a presented cover's frames out.
    private func zoomSeconds(_ seconds: Double) -> Double {
        #if DEBUG
        let slowed = UserDefaults.standard.double(forKey: "tvZoomSeconds")
        if slowed > 0 { return slowed }
        #endif
        return seconds
    }

    /// The cover goes without the system's animation, which the zoom has stood in for.
    private func closeNow() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { dismiss() }
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
        if items.isEmpty { closeNow() }
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

    /// The photo shown: the page under the viewer is told, and a Live Photo's movie playing over the last one stops.
    private func show() async {
        guard let item else { return }
        shown(item.id)
        player?.pause()
        player = nil
        playerItemID = nil
    }

    /// The video shown, in the system's player, full screen over the viewer: the TV held in HDR where the video is HDR,
    /// and the player's info panel saying what the title capsule says of a photo.
    private func playVideo() {
        guard let item, item.isVideo, video == nil, let client = model.client else { return }
        let asset = client.videoAsset(item.id)
        let playing = AVPlayerItem(asset: asset)
        let presentation = TVVideoPresentation(player: AVPlayer(playerItem: playing)) { video = nil }
        video = presentation
        // At once, as the click asks; the TV goes to HDR once the video turns out to be HDR, and its details follow.
        presentation.present()
        Task {
            await TVDisplayMode.holdHDR(for: asset)
            let read: AssetResponse? = try? await client.get("assets/\(item.id)")
            details = read
            playing.externalMetadata = metadata(titles(for: item))
        }
    }

    private func metadata(_ titles: (title: String, subtitle: String)) -> [AVMetadataItem] {
        [(AVMetadataIdentifier.commonIdentifierTitle, titles.title),
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

/// tvOS's own player, presented full screen over the viewer as UIKit presents it, so it has the remote whole and Menu
/// closes it as it closes any video on the TV; the movie stops as it goes.
@MainActor
final class TVVideoPresentation: NSObject, AVPlayerViewControllerDelegate {
    private let controller = AVPlayerViewController()
    private let closed: () -> Void

    init(player: AVPlayer, closed: @escaping () -> Void) {
        self.closed = closed
        super.init()
        // The TV's picture mode is TVDisplayMode's: the player would set it for each video and back again as it goes.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        controller.player = player
        controller.delegate = self
    }

    func present() {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return closed() }
        top.present(controller, animated: true) { [controller] in controller.player?.play() }
    }

    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in
            controller.player?.pause()
            closed()
        }
    }
}

/// One photo of the viewer, which slides in and out whole: its preview at once where the grid read it, then the
/// full-size image; a Live Photo's movie over it while it plays; a video's first picture with a play sign.
private struct TVViewerPage: View {
    let item: TVItem
    let player: AVPlayer?
    /// Its tile's frame on screen while the viewer zooms out of it or back into it; nil full screen.
    let tile: CGRect?
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                // Its ThumbHash where the server has no picture for it yet, as a tile shows it.
                if let picture = image ?? model.images?.cachedThumbnail(item.id, size: .preview)
                    ?? item.thumbhash.flatMap({ ThumbHash.cachedImage(base64: $0) }) {
                    // Filling a frame that goes from the tile's square to the photo fitted to the screen, so the
                    // photo grows out of its tile as the tile shows it, and back.
                    let page = geometry.frame(in: .global)
                    let frame = tile.map { $0.offsetBy(dx: -page.minX, dy: -page.minY) }
                        ?? Self.fitted(CGSize(width: picture.width, height: picture.height), in: geometry.size)
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .position(x: frame.midX, y: frame.midY)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if tile == nil, let player { TVPlayerView(player: player) }
            if tile == nil, item.isVideo {
                VStack(spacing: 16) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 120))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(color: .black.opacity(0.4), radius: 12)
                    if let duration = item.durationMS {
                        Text(Duration.formatMilliseconds(duration)).font(.headline).monospacedDigit()
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 4)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Play Video"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
    }

    /// A picture of `size` fitted into `bounds`, centred.
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func load() async {
        guard let images = model.images else { return }
        if image == nil { image = await images.thumbnail(item.id, size: .preview) }
        guard !item.isVideo, let full = await images.thumbnail(item.id, size: .fullsize), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { image = full }
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

/// Where a page's tiles are on screen, by photo, which they write as they are laid out: the viewer zooms out of the
/// tile it opens at, and back into the tile of the photo it shows last (tvOS has no zoom transition of its own for a
/// full-screen cover, which the iPhone's uses).
@MainActor
final class TVTileFrames {
    var frames: [String: CGRect] = [:]

    /// A tile's frame on screen, where it is on screen.
    func frame(_ id: String) -> CGRect? {
        guard let frame = frames[id], frame.intersects(CGRect(x: 0, y: 0, width: 1920, height: 1080)) else { return nil }
        return frame
    }
}

extension EnvironmentValues {
    /// The page's tile frames, which its tiles write (TVViewerCover).
    @Entry var tvTileFrames: TVTileFrames?
}

/// The viewer over a page of tiles, as the iPhone opens a photo: it grows out of its tile, and closes into the tile of
/// the photo shown last, which the page scrolls to under the viewer and the focus lands on after it. The cover is
/// clear and comes without the system's animation; the viewer draws the zoom itself.
struct TVViewerCover: ViewModifier {
    @Binding var viewing: TVViewing?
    var focused: FocusState<String?>.Binding
    /// Keeps a photo's tile in view; nil where the page cannot scroll to it.
    var scroll: ((String) -> Void)?
    @State private var frames = TVTileFrames()
    @State private var presented: TVViewing?
    @State private var shownID: String?

    func body(content: Content) -> some View {
        content
            .environment(\.tvTileFrames, frames)
            .onChange(of: viewing?.id) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { presented = viewing }
            }
            .fullScreenCover(item: Binding(get: { presented }, set: { presented = $0; if $0 == nil { viewing = nil } }),
                             onDismiss: closed) { viewing in
                TVViewer(viewing: viewing, frames: frames) { id in
                    // The photo it opens at is on screen, its tile what the zoom starts from: only a step scrolls.
                    let stepped = shownID != nil
                    shownID = id
                    if stepped { scroll?(id) }
                }
                .presentationBackground(.clear)
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
