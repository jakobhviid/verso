import AVKit
import os
import SwiftUI

// The viewer on the TV, as the iPhone's (ios/Verso/Viewer/PhotoViewer.swift) where a remote can have it: a photo filling
// the screen, the preview first and then the full-size image a 4K screen wants; left and right slide to the photo beside
// it, as the iPhone's pages slide, and a click brings up what the iPhone's title capsule says, its place over its day
// and time, and takes it away again. It opens out of its tile and closes into the tile of the photo shown last
// (TVViewerCover). A Live Photo has the Live Photo sign small in the corner, and play/pause plays its movie over the
// photo. A video plays at once, as in Apple's Photos, and left and right step on from it as from a photo; a click or up
// brings tvOS's own controls over it, still playing (the timeline, scrubbed with a swipe or left and right, audio,
// subtitles, the place and the day), as YouTube's up-into-the-controls has it, and Menu leaves them for the video playing
// on in the viewer; play/pause pauses and plays on, with a play sign while it is paused. A video stepped to slides in as
// its picture and starts once the slide has settled, and its player shows once it has a frame, so the video takes over
// from its picture where it lies. On a box without HLG (TVDevice), an iPhone's HDR video plays converted to SDR; a video
// that cannot play says why over its picture. Once a video in HDR has put the TV in HDR, it stays there until the viewer
// closes (TVDisplayMode), rather than going back to SDR and again to HDR from photo to photo.

private let videoLog = Logger(subsystem: "dev.hviid.Verso", category: "video")

struct TVViewer: View {
    @State private var items: [TVItem]
    @State private var index: Int
    /// A Live Photo's movie playing over it, and the photo it belongs to.
    @State private var player: AVPlayer?
    @State private var playerItemID: String?
    /// tvOS's own controls, over the video playing in the viewer.
    @State private var video: TVVideoPresentation?
    /// The video shown is paused, by play/pause.
    @State private var videoPaused = false
    /// Why the video shown cannot play.
    @State private var videoFailure: String?
    /// The player whose picture has come: its first frame drawn.
    @State private var pictureCame: ObjectIdentifier?
    /// A photo has been shown: the next comes by a step, sliding in.
    @State private var shownOne = false
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
        // An older box opens at full screen at once (TVDevice).
        _expanded = State(initialValue: TVDevice.simpler || frames?.frame(viewing.startID) == nil)
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
        // A button, so a click is its own and a press and hold the photo's menu's: on a view with a tap of its own, the
        // menu took the click, and a video's middle-of-the-clickpad press did not play it.
        Button(action: select) { screen }
            .buttonStyle(TVPressedAsIs())
            .accessibilityIdentifier("Viewer")
            .onMoveCommand { direction in
                switch direction {
                case .left: step(-1)
                case .right: step(1)
                case .up: if item?.isVideo == true { showControls() }
                default: break
                }
            }
            .onPlayPauseCommand { if item?.isVideo == true { pauseOrPlay() } else { playLive() } }
            .onExitCommand { close() }
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
            .onDisappear {
                player?.pause()
                TVDisplayMode.release()
            }
            .task {
                // Out of its tile, once the viewer is on screen at the tile.
                guard !expanded else { return }
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.smooth(duration: zoomSeconds(0.4))) { expanded = true }
            }
            .task { await followDebugSteps() }
    }

    /// A click: a video's controls come up, a photo's title capsule comes or goes.
    private func select() {
        if item?.isVideo == true { showControls() } else { showsInfo.toggle() }
    }

    private var screen: some View {
        ZStack {
            Color.black.opacity(expanded ? 1 : 0)
            if let item {
                // Above the black, or the photo leaving is drawn under it and vanishes rather than sliding away.
                TVViewerPage(item: item, player: playerItemID == item.id ? player : nil,
                             tile: expanded ? nil : frames?.frame(item.id), paused: videoPaused,
                             failure: videoFailure, pictureCame: { pictureCame = ObjectIdentifier($0) })
                    .id(item.id)
                    .zIndex(1)
                    .transition(TVDevice.simpler ? .identity : .asymmetric(
                        insertion: .move(edge: direction > 0 ? .trailing : .leading),
                        removal: .move(edge: direction > 0 ? .leading : .trailing)))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome.opacity(expanded ? 1 : 0) }
        .overlay(alignment: .topLeading) { liveSign.opacity(expanded ? 1 : 0) }
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
        guard !TVDevice.simpler, let item, frames?.frame(item.id) != nil else { return closeNow() }
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
        // An older box steps at once (TVDevice).
        withAnimation(TVDevice.simpler ? nil : .smooth(duration: 0.35)) { index = next }
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
        withAnimation(TVDevice.simpler ? nil : .smooth(duration: 0.35)) {
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

    /// The photo shown: the page under the viewer is told, the last one's movie stops, and a video plays at once, as in
    /// Photos: the TV held in HDR where it is HDR, and its details read for the controls' info panel.
    private func show() async {
        guard let item else { return }
        shown(item.id)
        player?.pause()
        player = nil
        playerItemID = nil
        videoPaused = false
        videoFailure = nil
        let stepped = shownOne
        shownOne = true
        guard item.isVideo, let client = model.client else { return }
        // Stepped to, it starts once its picture has slid in: a player put on the page during the slide is not part of
        // it, and stood in the middle at once while the picture slid in under it.
        if stepped, !TVDevice.simpler {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        let asset = client.videoAsset(item.id)
        let format = await Self.format(of: asset)
        let hlg = format?.hlg ?? false
        guard !Task.isCancelled else { return }
        // On a box without HLG (TVDevice), an iPhone's HDR video plays converted to SDR; should the box refuse that, as
        // recorded, and only then does the viewer say why.
        var playing: AVPlayerItem?
        var how = String(localized: "as recorded")
        if hlg, !TVDevice.playsHLG, let converted = await Self.convertedToSDR(asset, framesPerSecond: format?.framesPerSecond) {
            playing = await play(converted.item, of: item)
            if playing == nil, !Task.isCancelled, self.item?.id == item.id {
                videoLog.error("the video converted to SDR cannot play: \(videoFailure ?? "", privacy: .public); playing it as recorded")
                how = String(localized: "as recorded, the conversion to SDR refused: \(videoFailure ?? "")")
                videoFailure = nil
            } else {
                how = converted.how
            }
        }
        if playing == nil, !Task.isCancelled, self.item?.id == item.id {
            playing = await play(AVPlayerItem(asset: asset), of: item)
        }
        guard let playing, !Task.isCancelled, self.item?.id == item.id, let player else { return }
        // The sound can play while the picture never comes, which AVFoundation reports as no error: after three
        // seconds of sound with no frame drawn, the viewer says so, with what the video is and how it was played.
        let described = format?.summary ?? String(localized: "a video of an unknown format")
        videoLog.notice("a video plays: \(described, privacy: .public), \(how, privacy: .public)")
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard self.player === player, videoFailure == nil, pictureCame != ObjectIdentifier(player),
                  player.currentTime().seconds > 1 else { return }
            videoFailure = String(localized: "The sound plays, but no picture has come. The video: \(described), played \(how).")
            videoLog.error("no picture: \(described, privacy: .public), played \(how, privacy: .public); presentation size \(playing.presentationSize.debugDescription, privacy: .public)")
        }
        // The TV goes to HDR for a video in HDR, but not to an HLG the box cannot give it.
        if !hlg || TVDevice.playsHLG { await TVDisplayMode.holdHDR(for: asset) }
        let read: AssetResponse? = try? await client.get("assets/\(item.id)")
        guard !Task.isCancelled, self.item?.id == item.id else { return }
        details = read
        playing.externalMetadata = metadata(titles(for: item))
    }

    /// The video's player, playing in the viewer: the item where it starts, nil where it cannot play (`videoFailure`
    /// says why) or the viewer has moved on.
    private func play(_ playing: AVPlayerItem, of item: TVItem) async -> AVPlayerItem? {
        guard !Task.isCancelled, self.item?.id == item.id else { return nil }
        let player = AVPlayer(playerItem: playing)
        self.player = player
        playerItemID = item.id
        // Played to its end, it waits at its start with the play sign, for play/pause.
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playing, queue: .main) { _ in
            Task { @MainActor in
                guard self.player === player else { return }
                await player.seek(to: .zero)
                if self.player === player, player.rate == 0 { videoPaused = true }
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playing, queue: .main) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard self.player === player else { return }
                videoFailure = Self.reason(error)
                videoLog.error("a video stopped: \(videoFailure ?? "", privacy: .public)")
            }
        }
        player.play()
        // Ready, or failed, within 30 seconds; and ready is not playing: a composition the box refuses fails as it renders
        // the first frames, while the sound plays on. A failure in its first second and a half is this attempt's; the
        // video plays meanwhile.
        var loading = 0, ready = 0
        while self.player === player, videoFailure == nil, playing.status != .failed, loading < 300, ready < 15 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
            if playing.status == .readyToPlay { ready += 1 } else { loading += 1 }
        }
        if playing.status == .failed, self.player === player, videoFailure == nil { videoFailure = Self.reason(playing.error) }
        guard self.player === player, videoFailure == nil else {
            if self.player === player { videoLog.error("a video cannot play: \(videoFailure ?? "", privacy: .public)") }
            return nil
        }
        return playing
    }

    /// What the viewer knows of a video's picture: whether it is HLG, as an iPhone records its HDR (Dolby Vision 8.4 over
    /// an HLG base), its frame rate, and a line saying what it is, for the notice where its picture never comes.
    private struct VideoFormat {
        var hlg: Bool
        var framesPerSecond: Float
        var summary: String
    }

    private static func format(of asset: AVAsset) async -> VideoFormat? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        let framesPerSecond = (try? await track.load(.nominalFrameRate)) ?? 0
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        let hlg = transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any] ?? [:]
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let codecName = String(decoding: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xFF) }, as: UTF8.self)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        var parts = [codecName, "\(size.width)×\(size.height)", "\(Int(framesPerSecond.rounded())) fps"]
        if let bits = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int {
            parts.append("\(bits)-bit")
        }
        parts.append(hlg ? "HLG" : transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String ? "PQ" : "SDR")
        if !atoms.keys.filter({ ["dvcC", "dvvC", "dvwC"].contains($0) }).isEmpty { parts.append("Dolby Vision") }
        return VideoFormat(hlg: hlg, framesPerSecond: framesPerSecond, summary: parts.joined(separator: ", "))
    }

    /// The video through a composition that renders it in SDR, Rec. 709, at most 1920 wide and 30 frames a second, so a
    /// box without HLG gives it as the SDR its specifications list (2160p at 60 fps, Main 10), not as the HDR at 60 fps
    /// it lacks. The Simulator plays no composition at all (AVFoundation -11800, -19230, an H.264 video in SDR too), so
    /// this is checked on the box itself.
    private static func convertedToSDR(_ asset: AVAsset, framesPerSecond: Float?) async -> (item: AVPlayerItem, how: String)? {
        guard var configuration = try? await AVVideoComposition.Configuration(for: asset) else { return nil }
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let width = max(configuration.renderSize.width, configuration.renderSize.height)
        if width > 1920 { configuration.renderScale = Float(1920 / width) }
        if let framesPerSecond, framesPerSecond > 30 { configuration.frameDuration = CMTime(value: 1, timescale: 30) }
        let playing = AVPlayerItem(asset: asset)
        playing.videoComposition = AVVideoComposition(configuration: configuration)
        let rate = configuration.frameDuration.seconds > 0 ? Int((1 / configuration.frameDuration.seconds).rounded()) : 0
        let how = String(localized: "converted to SDR at \(Int((width * CGFloat(configuration.renderScale)).rounded())) wide, \(rate) fps")
        videoLog.notice("an HLG video plays \(how, privacy: .public)")
        return (playing, how)
    }

    /// Why a video cannot play, as the system says it, with its error's domain and code for a report.
    private static func reason(_ error: Error?) -> String {
        guard let error = error as NSError? else { return String(localized: "The video stopped.") }
        var codes = "\(error.domain) \(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes += ", \(underlying.domain) \(underlying.code)"
        }
        return "\(error.localizedFailureReason ?? error.localizedDescription) (\(codes))"
    }

    /// tvOS's own controls over the video playing, as it plays: the timeline to scrub, audio, subtitles, the info.
    private func showControls() {
        guard item?.isVideo == true, let player, playerItemID == item?.id, video == nil else { return }
        let presentation = TVVideoPresentation(player: player) { video = nil; videoPaused = player.rate == 0 }
        video = presentation
        presentation.present()
    }

    /// Play/pause on a video: paused where it plays, played on where it is paused.
    private func pauseOrPlay() {
        guard let player, playerItemID == item?.id else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        videoPaused = player.rate == 0
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

/// The viewer's button: the screen as it is, without tvOS's lift or highlight, which a whole screen has no use for.
private struct TVPressedAsIs: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.focusEffectDisabled()
    }
}

/// tvOS's own controls over a video the viewer plays: its player, presented full screen as UIKit presents it, with the
/// viewer's own playing player, so the video goes on where it was; it has the remote whole, and Menu, a layer at a time,
/// closes it, the video playing on in the viewer.
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
        // What the remote's tests wait for (VersoTVUITests).
        controller.view.accessibilityIdentifier = "Video Player"
    }

    func present() {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return closed() }
        top.present(controller, animated: true)
    }

    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in closed() }
    }
}

/// One photo of the viewer, which slides in and out whole: its preview at once where the grid read it, then the
/// full-size image; a Live Photo's movie over it while it plays; a video playing over its first picture, with a play sign
/// while it is paused.
private struct TVViewerPage: View {
    let item: TVItem
    let player: AVPlayer?
    /// Its tile's frame on screen while the viewer zooms out of it or back into it; nil full screen.
    let tile: CGRect?
    var paused = false
    var failure: String?
    var pictureCame: (AVPlayer) -> Void = { _ in }
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                // Its ThumbHash where the server has no picture for it yet, as a tile shows it.
                if let picture = image ?? model.images?.cachedThumbnail(item.id, size: .preview)
                    ?? model.images?.cachedTile(item.id, size: .preview, pixels: TVGridTile.pixels)
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
            if tile == nil, let player {
                TVPlayerView(player: player, pictureCame: pictureCame)
                    .accessibilityIdentifier(item.isVideo ? "Playing Video" : "Live Photo Movie")
            }
            if tile == nil, item.isVideo, let failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64))
                    Text("Can't Play This Video").font(.headline)
                    Text(failure).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 900)
                }
                .foregroundStyle(.white)
                .padding(40)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 24))
            } else if tile == nil, item.isVideo, paused {
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
                .accessibilityLabel(Text("Paused"))
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

/// A page's grid, as the viewer asks it (TVPhotoGrid serves it): where a photo's tile is on screen, which the viewer
/// zooms out of and back into (tvOS has no zoom transition of its own for a full-screen cover, which the iPhone's
/// uses); scrolling a stepped-to photo's tile into view under the viewer; and the focus on that tile as it closes.
@MainActor
final class TVTileFrames {
    var locate: ((String) -> CGRect?)?
    var scroll: ((String) -> Void)?
    var focus: ((String) -> Void)?
    /// A month's photos at the top of the grid.
    var scrollToSection: ((String) -> Void)?

    /// A tile's frame on screen, where it is on screen.
    func frame(_ id: String) -> CGRect? {
        guard let frame = locate?(id), frame.intersects(CGRect(x: 0, y: 0, width: 1920, height: 1080)) else { return nil }
        return frame
    }
}

extension EnvironmentValues {
    /// The page's grid, which the viewer finds its tiles in (TVViewerCover).
    @Entry var tvTileFrames: TVTileFrames?
}

/// The viewer over a page's grid, as the iPhone opens a photo: it grows out of its tile, and closes into the tile of the
/// photo shown last, which the grid scrolls to under the viewer and puts the focus on after it. The cover is clear and
/// comes without the system's animation; the viewer draws the zoom itself. The page's photo menus ask their questions
/// here (TVPhotoRequestsHost), as the grid's menu comes from UIKit.
struct TVViewerCover: ViewModifier {
    @Binding var viewing: TVViewing?
    /// The page's grid, where the page scrolls it itself (the Library's Months); else the cover's own.
    var frames: TVTileFrames?
    @State private var ownFrames = TVTileFrames()
    @State private var requests = TVPhotoRequests()

    private var grid: TVTileFrames { frames ?? ownFrames }
    @State private var presented: TVViewing?
    @State private var shownID: String?

    func body(content: Content) -> some View {
        content
            .environment(\.tvTileFrames, grid)
            .environment(\.tvPhotoRequests, requests)
            .modifier(TVPhotoRequestsHost(requests: requests))
            .onChange(of: viewing?.id) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { presented = viewing }
            }
            .fullScreenCover(item: Binding(get: { presented }, set: { presented = $0; if $0 == nil { viewing = nil } }),
                             onDismiss: closed) { viewing in
                TVViewer(viewing: viewing, frames: grid) { id in
                    // The photo it opens at is on screen, its tile what the zoom starts from: only a step scrolls.
                    let stepped = shownID != nil
                    shownID = id
                    if stepped { grid.scroll?(id) }
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
            grid.focus?(id)
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
    /// Told once the player's first frame is drawn.
    var pictureCame: (AVPlayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.pictureCame = pictureCame
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.pictureCame = pictureCame
    }

    /// The player's layer, hidden until it has a frame, so the picture under it shows until the movie takes over.
    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var pictureCame: (AVPlayer) -> Void = { _ in }
        private var readiness: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.opacity = 0
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.playerLayer.opacity = ready ? 1 : 0
                    if ready, let player = self.playerLayer.player { self.pictureCame(player) }
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("not from a storyboard") }
    }
}
