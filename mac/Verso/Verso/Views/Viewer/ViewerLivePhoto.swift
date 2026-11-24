// A Live Photo in the Mac's viewer, as the iPhone's moves (ARCHITECTURE.md, "Live Photos", and "Verso on the Mac"):
// stepped to (a key, an arrow, a swipe), it plays the 0.6 s of its motion up to the key photo, without sound, the last
// 0.17 s slower, and fades into the photo in 0.25 s, starting as the step does, on the step's sliding picture too;
// opened from the grid, nothing moves. The motions of the photos beside the one shown are loaded and cued ahead, so a
// step finds its motion ready; one not ready as the step begins, or within a moment of it, stays still. ⌥Space, and
// the toolbar's Live, play it whole with the video's sound settings, back at the still in 0.3 s. Its motion is the
// original movie Immich keeps for it, cached (LiveMotions, which the iPhone's viewer shares), its whole coded frame
// drawn over the photo, so it zooms and pans with it. The LIVE badge under Back is one switch for every Live Photo,
// kept on this Mac: off, or with Reduce Motion on, they stay still as a step brings them, and still play whole when
// asked.

import AVFoundation
import os
import SwiftUI

private let liveLog = Logger(subsystem: "dev.hviid.Verso", category: "live")

/// The LIVE badge's switch; which photo each viewer shows, so a photo knows whether a step brought it; and the motions
/// each viewer has made: the photo it shows and those beside it, loaded ahead, so a step's glimpse starts with the step.
@MainActor enum LivePhotos {
    /// Set while Live Photos stay still; the same key as the iPhone's.
    static let stillKey = "viewer.livePhotosStill"

    /// The photo each place shows (the window's viewer or the full-screen one, of a grid) and the viewer showing it.
    private static var shown: [String: (photo: String, viewer: UUID)] = [:]
    /// The motions each place has made, by photo.
    private static var motions: [String: [String: LivePhotoMotion]] = [:]

    /// The place of a grid's viewer: its window's (`presentation` false) or its full-screen one.
    static func place(_ model: AnyObject, presentation: Bool) -> String {
        "\(ObjectIdentifier(model))-\(presentation)"
    }

    /// Live Photos move as a step brings them: the LIVE badge says so, and Reduce Motion does not say otherwise.
    static func glimpsesPlay(reduceMotion: Bool) -> Bool {
        !UserDefaults.standard.bool(forKey: stillKey) && !reduceMotion
    }

    /// Records `photo` as the one `place` shows, and says whether a step brought it: another photo was shown there.
    static func arrive(_ photo: String, viewer: UUID, place: String) -> Bool {
        let previous = shown[place]
        shown[place] = (photo, viewer)
        return previous.map { $0.photo != photo } ?? false
    }

    /// A viewer goes: while a step replaces it, the place keeps its photo and its motions; as the viewer closes, it
    /// forgets them.
    static func leave(viewer: UUID, place: String, stepping: Bool) {
        guard !stepping, shown[place]?.viewer == viewer else { return }
        shown[place] = nil
        motions[place]?.values.forEach { $0.release() }
        motions[place] = nil
    }

    /// The place's motion of `item`, a Live Photo, made where it has none yet.
    static func motion(for item: AssetItem, place: String, session: LibrarySession) -> LivePhotoMotion? {
        guard let videoID = item.livePhotoVideoID, !item.isVideo else { return nil }
        if let motion = motions[place]?[item.id] { return motion }
        let pipeline = session.pipeline
        let motion = LivePhotoMotion(videoID: videoID, request: session.client.originalRequest(videoID)) { [id = item.id] in
            await pipeline.thumbnail(id, size: .preview)
        }
        motions[place, default: [:]][item.id] = motion
        return motion
    }

    /// The place's motion of `photo`, where it has made one.
    static func existingMotion(of photo: String, place: String) -> LivePhotoMotion? {
        motions[place]?[photo]
    }

    /// The place keeps the motions of `photos` (the one it shows and those beside it) and lets the others go.
    static func keep(_ photos: Set<String>, place: String) {
        guard let made = motions[place] else { return }
        var kept = photos
        if let photo = shown[place]?.photo { kept.insert(photo) }
        for (photo, motion) in made where !kept.contains(photo) {
            motion.release()
            motions[place]?[photo] = nil
        }
    }
}

/// One Live Photo's motion while its viewer shows it or is beside it: loaded from LiveMotions into a player, drawn on
/// `layer` over the photo and on `slideLayer` over its picture on a step's slide while it plays, cued at the glimpse's
/// start between plays.
@MainActor @Observable
final class LivePhotoMotion {
    enum Play {
        /// The motion up to the key photo, without sound, easing into it, as a step brings the photo.
        case glimpse
        /// The whole motion, with sound.
        case whole
    }

    /// How long after a step began its glimpse may still start, where the motion was not ready then: by then the step's
    /// slide has brought the photo three quarters of the way in, about where the iPhone's glimpse starts (65% across).
    /// Later, it would start as the photo lands or after, content moving as it loads, so it does not play.
    static let glimpseGrace: TimeInterval = 0.1

    /// The motion's picture, over the photo while it plays, and see-through otherwise.
    let layer = AVPlayerLayer()
    /// The same, over the photo's picture on the slide (`ViewerSlider`), which covers the viewer while a step brings the
    /// photo in or takes it away.
    let slideLayer = AVPlayerLayer()
    /// A whole play waits for the motion to download: the badge shows it.
    private(set) var waiting = false
    /// The motion could not be read.
    private(set) var unavailable = false
    /// A whole play has ended, or stopped.
    @ObservationIgnored var onWholeEnded: (() -> Void)?
    /// The viewer showing the photo, which stops what plays as it leaves it.
    @ObservationIgnored var viewer: UUID?

    private let videoID: String
    private let request: URLRequest
    /// The photo's preview, to find the key photo of a motion whose movie does not mark it.
    private let picture: @MainActor () async -> CGImage?
    @ObservationIgnored private var motion: LiveMotions.Motion?
    @ObservationIgnored private var matchedKey: CMTime?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var status: NSKeyValueObservation?
    @ObservationIgnored private var end: NSObjectProtocol?
    @ObservationIgnored private var marks: Any?
    @ObservationIgnored private var playing: Play?
    /// What plays once the motion has loaded.
    @ObservationIgnored private var pending: Play?
    /// A glimpse waiting for the motion plays only until then (`glimpseGrace`).
    @ObservationIgnored private var glimpseDeadline = Date.distantPast
    /// The glimpse has begun for this step: one a swipe began as it brought the photo does not begin again as the
    /// step lands.
    @ObservationIgnored private var glimpsed = false
    /// The motion waits at the glimpse's start, so a glimpse begins without a seek.
    @ObservationIgnored private var cued = false
    /// How many times it has started, so a fade's end knows whether it started again meanwhile.
    @ObservationIgnored private var starts = 0
    @ObservationIgnored private var released = false

    init(videoID: String, request: URLRequest, picture: @escaping @MainActor () async -> CGImage?) {
        self.videoID = videoID
        self.request = request
        self.picture = picture
        for shown in [layer, slideLayer] {
            shown.videoGravity = .resize
            shown.opacity = 0
        }
    }

    /// The motion from the cache, or downloaded into it, then a player for it, cued at the glimpse's start.
    func load() {
        guard player == nil, loading == nil, !unavailable, !released else { return }
        let videoID = videoID, request = request
        loading = Task { [weak self] in
            do {
                let motion = try await LiveMotions.shared.motion(videoID, request: request)
                self?.attach(motion)
            } catch {
                guard !error.isCancellation else { return }
                liveLog.error("a Live Photo's motion could not be read: \(String(describing: error), privacy: .public)")
                self?.failed()
            }
        }
    }

    /// The glimpse, as a step brings the photo, once for the step: at once where the motion is ready, or within
    /// `glimpseGrace`, else not.
    func glimpse() {
        guard !glimpsed else { return }
        glimpsed = true
        glimpseDeadline = .now.addingTimeInterval(Self.glimpseGrace)
        play(.glimpse)
    }

    /// A swipe that began the glimpse as it brought the photo went back: it stops at once, and may begin again.
    func withdrawGlimpse() {
        guard glimpsed else { return }
        glimpsed = false
        if playing == .glimpse || pending == .glimpse { stop(settling: 0) }
    }

    /// The viewer `viewer` leaves the photo: what plays stops, and the next step to it glimpses again. A viewer that
    /// shows the photo since keeps it as it is.
    func leave(viewer: UUID) {
        guard self.viewer == viewer else { return }
        self.viewer = nil
        onWholeEnded = nil
        glimpsed = false
        if playing != nil || pending != nil { stop() }
    }

    /// Plays the motion, loading it first where it has not loaded.
    func play(_ kind: Play) {
        guard !unavailable, !released else {
            if kind == .whole { onWholeEnded?() }
            return
        }
        load()
        guard let player, player.currentItem?.status == .readyToPlay else {
            pending = kind
            if kind == .whole { waiting = true }
            return
        }
        start(kind, player)
    }

    /// A whole play stops, as the toolbar's Live is switched off.
    func stopWhole() {
        if playing == .whole || pending == .whole { stop() }
    }

    /// The motion stops, and the photo shows again, in a short fade; it stays loaded, cued for the next glimpse once it
    /// has faded: cued at once, the fade would show the glimpse's start rather than where it stopped.
    func stop(settling: Double = LiveMotions.Timing.settle) {
        let wasWhole = playing == .whole || pending == .whole
        playing = nil
        pending = nil
        waiting = false
        player?.pause()
        if let marks { player?.removeTimeObserver(marks) }
        marks = nil
        let started = starts
        CATransaction.begin()
        CATransaction.setAnimationDuration(settling)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.starts == started else { return }
                self.cueGlimpse()
            }
        }
        for shown in [layer, slideLayer] { shown.opacity = 0 }
        CATransaction.commit()
        if wasWhole { onWholeEnded?() }
    }

    /// The motion goes, as its viewer and the photos beside it do.
    func release() {
        onWholeEnded = nil
        released = true
        loading?.cancel()
        loading = nil
        tearDown()
    }

    /// The player goes, and the photo shows alone.
    private func tearDown() {
        playing = nil
        pending = nil
        waiting = false
        cued = false
        if let marks { player?.removeTimeObserver(marks) }
        marks = nil
        player?.pause()
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
        status = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shown in [layer, slideLayer] {
            shown.opacity = 0
            shown.player = nil
        }
        CATransaction.commit()
        player = nil
        motion = nil
        matchedKey = nil
    }

    private func attach(_ motion: LiveMotions.Motion) {
        loading = nil
        guard player == nil, !released else { return }
        self.motion = motion
        if motion.keyPhoto == nil {
            Task { [weak self, picture] in
                guard let photo = await picture() else { return }
                let key = await LiveMotions.shared.keyPhoto(matching: photo, in: motion)
                guard let self, self.motion?.file == motion.file else { return }
                self.matchedKey = key
                // Not while it plays: the seek would jump.
                if self.playing == nil { self.cueGlimpse() }
            }
        }
        let item = AVPlayerItem(url: motion.file)
        item.videoApertureMode = .encodedPixels
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        status = item.observe(\.status) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor in self?.loaded(status) }
        }
        end = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        layer.player = player
        slideLayer.player = player
        self.player = player
    }

    /// The motion cannot be read: the photo stays still, and a whole play waiting for it ends.
    private func failed() {
        loading = nil
        let wasWhole = pending == .whole || playing == .whole
        tearDown()
        unavailable = true
        if wasWhole { onWholeEnded?() }
    }

    private func loaded(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            waiting = false
            if pending == .glimpse, Date.now > glimpseDeadline { pending = nil }
            guard let kind = pending, let player else {
                cueGlimpse()
                return
            }
            pending = nil
            start(kind, player)
        case .failed:
            failed()
        default:
            break
        }
    }

    /// The key photo's moment, as the movie marks it or as matching found it.
    private var foundKey: CMTime? { motion?.keyPhoto ?? matchedKey }

    /// The motion at the glimpse's start, ahead of the glimpse, so nothing waits for a seek then.
    private func cueGlimpse() {
        guard let player, let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else {
            return
        }
        cued = false
        player.seek(to: LiveMotions.glimpseStart(foundKey, duration: duration), toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in if finished, self?.player === player { self?.cued = true } }
        }
    }

    private func start(_ kind: Play, _ player: AVPlayer) {
        starts += 1
        if let marks { player.removeTimeObserver(marks) }
        marks = nil
        playing = kind
        let from: CMTime
        switch kind {
        case .glimpse:
            guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else {
                playing = nil
                return
            }
            let key = LiveMotions.keyPhoto(foundKey, duration: duration)
            let easing = CMTime(seconds: max(0, key.seconds - LiveMotions.Timing.glimpseEase), preferredTimescale: 600)
            player.isMuted = true
            // Slower for its last moment, then still on the key photo.
            marks = player.addBoundaryTimeObserver(forTimes: [NSValue(time: easing), NSValue(time: key)],
                                                   queue: .main) { [weak self, weak player] in
                MainActor.assumeIsolated {
                    guard let self, let player else { return }
                    if player.currentTime().seconds >= key.seconds - 0.02 {
                        self.stop(settling: LiveMotions.Timing.glimpseSettle)
                    } else {
                        player.rate = LiveMotions.Timing.glimpseEaseRate
                    }
                }
            }
            if cued {
                cued = false
                show()
                player.play()
                return
            }
            from = LiveMotions.glimpseStart(foundKey, duration: duration)
        case .whole:
            from = .zero
            // As the viewer's videos sound.
            player.isMuted = UserDefaults.standard.bool(forKey: "viewer.videoMuted")
            player.volume = UserDefaults.standard.object(forKey: "viewer.videoVolume") as? Float ?? 1
        }
        cued = false
        player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.player === player, self.playing == kind else { return }
                self.show()
                player.play()
            }
        }
    }

    /// The motion over the photo, at once: it starts where the photo is.
    private func show() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shown in [layer, slideLayer] { shown.opacity = 1 }
        CATransaction.commit()
    }
}

/// The motion's layer over the photo, at the photo's size, so it zooms, pans and turns with it.
struct LivePhotoMotionLayer: NSViewRepresentable {
    let motion: LivePhotoMotion

    func makeNSView(context: Context) -> MotionView {
        let view = MotionView()
        view.wantsLayer = true
        view.layer?.addSublayer(motion.layer)
        return view
    }

    func updateNSView(_ view: MotionView, context: Context) {}

    final class MotionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            fitMotion()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fitMotion()
        }

        private func fitMotion() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sublayer in layer?.sublayers ?? [] { sublayer.frame = bounds }
            CATransaction.commit()
        }
    }
}

/// A Live Photo's badge under Back, one switch for every Live Photo: LIVE, on glass tinted yellow as the Camera's Live is
/// yellow when on, and a Live Photo moves briefly as a step brings it; OFF, and it stays still. Switching plays nothing.
/// With Reduce Motion on, it reads OFF and does not switch. It waits with a spinner while a whole play waits for the
/// motion, and says so where the motion cannot be read. (Photos' badge is a menu that turns the one photo still, with
/// Loop, Bounce and Long Exposure, effects saved into the photo, which Immich has none of.)
struct ViewerLiveBadge: View {
    let motion: LivePhotoMotion?
    let toggle: () -> Void
    @AppStorage(LivePhotos.stillKey) private var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = !still && !reduceMotion
        let unavailable = motion?.unavailable == true
        Button(action: toggle) {
            HStack(spacing: 5) {
                if motion?.waiting == true {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: on && !unavailable ? "livephoto" : "livephoto.slash")
                }
                Text(on ? "LIVE" : "OFF")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(on ? AnyShapeStyle(.black) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .modifier(LiveGlass(on: on))
        .disabled(unavailable || reduceMotion)
        .help(unavailable ? Text("This Live Photo can't play")
              : reduceMotion ? Text("Live Photos stay still while Reduce Motion is on")
              : on ? Text("Live Photos move as you step to them. ⌥Space plays one whole.")
              : Text("Live Photos stay still as you step to them. ⌥Space plays one whole."))
    }
}

/// The LIVE badge has just switched every Live Photo on or off.
struct LiveNotice: Equatable {
    let on: Bool
    let id = UUID()
}

/// A moment's notice at the top's middle as the LIVE badge switches, as the Camera shows LIVE and LIVE OFF: the badge
/// is one switch for every Live Photo, which the notice makes plain.
struct ViewerLiveNotice: View {
    let notice: LiveNotice
    let dismiss: (LiveNotice) -> Void

    var body: some View {
        Text(notice.on ? "LIVE" : "LIVE OFF")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(notice.on ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .modifier(LiveGlass(on: notice.on))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(1.5))
                dismiss(notice)
            }
    }
}

/// Glass tinted yellow while Live Photos move, plain glass while they stay still; on macOS 15, yellow or the material.
private struct LiveGlass: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(on ? .regular.tint(.yellow).interactive() : .regular.interactive(), in: .capsule)
        } else {
            content.background(on ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.regularMaterial), in: .capsule)
        }
    }
}
