// A photo's page in the viewer on iOS, zooming and pinched closed as a video's page is (ViewerZoomPage). It shows the
// best image already at hand (the preview, the grid's thumbnail, its ThumbHash) and then the preview from the shared
// ImagePipeline, swapped in without a fade; zoomed in, the original comes, decoded to a size the phone can hold. Once
// an edit has turned or cropped it, its new preview takes the old picture's place.
//
// A Live Photo moves as Photos' do (ARCHITECTURE.md, "Live Photos"): swiped toward, once it is 65% across, it plays the
// 0.6 s of its motion up to the key photo, without sound, at the motion's own speed and for the last 0.17 s at 0.7 of
// it, then fades into the photo in 0.25 s, about as it lands; not as the viewer opens, nor with Live Photos switched
// off (the LIVE badge, one switch for all) or where Reduce Motion or Auto-Play Video Previews says no. A press plays it
// whole, with its sound, also switched off, back at the still in 0.3 s. Its motion is the movie Immich keeps for it,
// cached (LiveMotions), its whole frame over the photo, as Photos plays it: the Camera's stabilised crop of it, which
// players show by default, is a little smaller than the photo's field.

import AVFoundation
import os
import UIKit

private let liveLog = Logger(subsystem: "dev.hviid.Verso", category: "live")

final class ViewerPhotoPage: ViewerZoomPage {
    /// Zoomed in past this, the original loads.
    private static let originalZoom: CGFloat = 1.3

    /// What the shown image is, from nothing to the original.
    private enum Quality: Int, Comparable {
        case none, placeholder, thumbnail, preview, original
        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var failureView: UIContentUnavailableView?
    private var shownQuality = Quality.none
    private var originalTask: Task<Void, Never>?
    /// A Live Photo's motion (LiveMotions), loaded as the page comes into view, over the picture while it plays.
    private var liveMotion: LiveMotions.Motion?
    private var liveLoad: Task<Void, Never>?
    private var livePlayer: AVPlayer?
    private var liveLayer: AVPlayerLayer?
    private var liveEnd: NSObjectProtocol?
    private var liveStatus: NSKeyValueObservation?
    private var liveMarks: Any?
    /// What plays once the motion has loaded.
    private var livePending: LivePlay?
    /// The motion waits at the glimpse's start, so the glimpse begins without a seek.
    private var glimpseCued = false
    /// The glimpse has played for this swipe.
    private var glimpsed = false
    /// The key photo found by matching the motion against the photo, where the movie does not mark it.
    private var matchedKey: CMTime?
    /// How many times the motion has started, so a fade's end knows whether it started again meanwhile.
    private var liveStarts = 0

    private enum LivePlay {
        /// The motion up to the key photo, without sound, easing into it, as a swipe brings the photo.
        case glimpse
        /// The whole motion, with its sound.
        case whole
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pictureView.accessibilityLabel = item.date.map { ImmichDate.long($0) } ?? String(localized: "Photo")
        // For UI tests, which pinch the photo.
        pictureView.accessibilityIdentifier = "Viewer Photo"

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        if item.livePhotoVideoID != nil {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.3
            press.delegate = self
            scrollView.addGestureRecognizer(press)
        }

        showCached()
        Task { [weak self] in await self?.loadPreview() }
    }

    /// A Live Photo's motion takes the picture's new size.
    override func pictureFitted() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer?.frame = pictureView.bounds
        CATransaction.commit()
    }

    /// Coming into view, as the viewer opens or a swipe brings it: a Live Photo's motion loads, so it is ready for the
    /// glimpse or a press.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if item.livePhotoVideoID != nil, state?.glimpsesPlay == true { loadLive() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releaseLive()
    }

    override func beginGlimpse() {
        guard !glimpsed, item.livePhotoVideoID != nil, state?.glimpsesPlay == true else { return }
        glimpsed = true
        play(.glimpse)
    }

    override func withdrawGlimpse() {
        glimpsed = false
        stopLive(settling: 0)
    }

    override func setCurrent(_ current: Bool) {
        super.setCurrent(current)
        guard !current else { return }
        glimpsed = false
        stopLive()
        originalTask?.cancel()
        originalTask = nil
    }

    override func playLivePhoto() {
        play(.whole)
    }

    override func stopLivePhoto() {
        stopLive()
    }

    override func loadLivePhoto() {
        loadLive()
    }

    /// A Live Photo playing stops, so its picture flies home.
    override func closingZoom(_ closing: Bool) {
        if closing { stopLive() }
    }

    /// The edited preview, fitted anew, in place of the picture shown, which stays until it comes.
    override func reloadPicture() {
        originalTask?.cancel()
        originalTask = nil
        resetZoom()
        guard let pipeline = state?.session.pipeline else { return }
        let id = item.id
        Task { [weak self] in
            guard let preview = await pipeline.thumbnail(id, size: .preview), let self else { return }
            shownQuality = .none
            show(preview, quality: .preview)
        }
    }

    // MARK: Images

    /// The best image the pipeline already holds, at once, so the page never starts empty when the grid showed it.
    private func showCached() {
        guard let pipeline = state?.session.pipeline else { return }
        if let preview = pipeline.cachedThumbnail(item.id, size: .preview) {
            show(preview, quality: .preview)
        } else if let thumbnail = pipeline.cachedThumbnail(item.id, size: .thumbnail) {
            show(thumbnail, quality: .thumbnail)
        } else if let hash = item.thumbhash, let placeholder = ThumbHash.cachedImage(base64: hash) {
            show(placeholder, quality: .placeholder)
        }
        updateSpinner()
    }

    private func loadPreview() async {
        guard let pipeline = state?.session.pipeline else { return }
        let id = item.id
        if shownQuality < .placeholder, let hash = item.thumbhash, let placeholder = await ThumbHash.placeholder(base64: hash) {
            show(placeholder, quality: .placeholder)
        }
        guard shownQuality < .preview else { return }
        if let preview = await pipeline.thumbnail(id, size: .preview) {
            show(preview, quality: .preview)
        } else if shownQuality < .thumbnail {
            showFailure()
        }
        updateSpinner()
    }

    /// The original, once zoomed in, decoded to about twice the screen's longer side in pixels.
    private func loadOriginalIfNeeded() {
        guard shownQuality < .original, originalTask == nil, let pipeline = state?.session.pipeline else { return }
        let id = item.id
        let screen = view.window?.windowScene?.screen.nativeBounds.size ?? CGSize(width: 2048, height: 2048)
        let pixels = min(6144, max(4096, Int(max(screen.width, screen.height) * 2)))
        originalTask = Task { [weak self] in
            let original = await pipeline.original(id, maxPixelSize: pixels, edited: true)
            guard let self, !Task.isCancelled else { return }
            if let original { show(original, quality: .original) }
            originalTask = nil
        }
    }

    private func show(_ image: CGImage, quality: Quality) {
        guard quality > shownQuality else { return }
        shownQuality = quality
        // The placeholder's shape is only near the photo's; a real image's is its own.
        showPicture(image, ownShape: quality >= .thumbnail)
        failureView?.removeFromSuperview()
        failureView = nil
        updateSpinner()
    }

    /// Spins while only the ThumbHash, or nothing, shows.
    private func updateSpinner() {
        if shownQuality < .thumbnail && failureView == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func showFailure() {
        guard failureView == nil else { return }
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "exclamationmark.triangle")
        configuration.text = String(localized: "Can't Load This Photo")
        let failure = UIContentUnavailableView(configuration: configuration)
        failure.frame = view.bounds
        failure.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        failure.isUserInteractionEnabled = false
        view.addSubview(failure)
        failureView = failure
        updateSpinner()
    }

    // MARK: Zoom

    /// Zoomed in far enough, the original loads.
    override func scrollViewDidZoom(_ scrollView: UIScrollView) {
        super.scrollViewDidZoom(scrollView)
        if scrollView.zoomScale > Self.originalZoom { loadOriginalIfNeeded() }
    }

    // MARK: Live Photo

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        // Asked for, so also with Live Photos switched off.
        case .began: play(.whole)
        case .ended, .cancelled, .failed: stopLive()
        default: break
        }
    }

    /// Plays the motion once it has loaded, loading it first where it has not; the badge waits for a whole play the
    /// person asked for.
    private func play(_ kind: LivePlay) {
        liveLog.debug("play \(String(describing: kind), privacy: .public) loaded \(self.livePlayer?.currentItem?.status == .readyToPlay, privacy: .public)")
        guard item.livePhotoVideoID != nil, state?.liveUnavailable.contains(item.id) != true else { return }
        loadLive()
        guard let player = livePlayer, player.currentItem?.status == .readyToPlay else {
            livePending = kind
            if kind == .whole { state?.liveLoading = item.id }
            return
        }
        start(kind, player)
    }

    /// The motion from the cache, or downloaded into it, then a player for it under the picture until it plays.
    private func loadLive() {
        guard livePlayer == nil, liveLoad == nil, let videoID = item.livePhotoVideoID,
              let client = state?.session.client else { return }
        let request = client.originalRequest(videoID)
        liveLoad = Task { [weak self] in
            do {
                let motion = try await LiveMotions.shared.motion(videoID, request: request)
                self?.attachLive(motion)
            } catch {
                guard !error.isCancellation else { return }
                liveLog.error("a Live Photo's motion could not be read: \(String(describing: error), privacy: .public)")
                self?.liveFailed()
            }
        }
    }

    private func attachLive(_ motion: LiveMotions.Motion) {
        liveLoad = nil
        guard livePlayer == nil, view.window != nil || isCurrent else { return }
        liveMotion = motion
        if motion.keyPhoto == nil, let picture = pictureView.image?.cgImage {
            Task { [weak self] in
                let key = await LiveMotions.shared.keyPhoto(matching: picture, in: motion)
                guard let self, self.liveMotion?.file == motion.file else { return }
                self.matchedKey = key
                self.cueGlimpse()
            }
        }
        let playerItem = AVPlayerItem(url: motion.file)
        playerItem.videoApertureMode = .encodedPixels
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resize
        layer.frame = pictureView.bounds
        layer.opacity = 0
        pictureView.layer.addSublayer(layer)
        liveStatus = playerItem.observe(\.status) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor in self?.liveLoaded(status) }
        }
        liveEnd = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                         object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopLive() }
        }
        livePlayer = player
        liveLayer = layer
    }

    private func liveFailed() {
        liveLoad = nil
        livePending = nil
        if state?.liveLoading == item.id { state?.liveLoading = nil }
        state?.liveUnavailable.insert(item.id)
    }

    private func liveLoaded(_ status: AVPlayerItem.Status) {
        liveLog.debug("loaded \(status.rawValue, privacy: .public) pending \(String(describing: self.livePending), privacy: .public)")
        switch status {
        case .readyToPlay:
            if state?.liveLoading == item.id { state?.liveLoading = nil }
            guard let kind = livePending, let player = livePlayer else {
                cueGlimpse()
                return
            }
            livePending = nil
            start(kind, player)
        case .failed:
            releaseLive()
            liveFailed()
        default:
            break
        }
    }

    /// The key photo's moment in the motion, as its movie marks it or as matching found it (LiveMotions.keyPhoto).
    private func keyPhoto(_ duration: CMTime) -> CMTime {
        LiveMotions.keyPhoto(liveMotion?.keyPhoto ?? matchedKey, duration: duration)
    }

    private func glimpseStart(_ duration: CMTime) -> CMTime {
        LiveMotions.glimpseStart(liveMotion?.keyPhoto ?? matchedKey, duration: duration)
    }

    /// The motion at the glimpse's start, ahead of the swipe, so nothing waits for a seek then.
    private func cueGlimpse() {
        guard let player = livePlayer, let duration = player.currentItem?.duration, duration.isNumeric,
              duration.seconds > 0 else { return }
        glimpseCued = false
        player.seek(to: glimpseStart(duration), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in if finished, self?.livePlayer === player { self?.glimpseCued = true } }
        }
    }

    private func start(_ kind: LivePlay, _ player: AVPlayer) {
        liveLog.debug("start \(String(describing: kind), privacy: .public)")
        liveStarts += 1
        if let liveMarks { player.removeTimeObserver(liveMarks) }
        liveMarks = nil
        let from: CMTime
        switch kind {
        case .glimpse:
            guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
            let key = keyPhoto(duration)
            let easing = CMTime(seconds: max(0, key.seconds - LiveMotions.Timing.glimpseEase), preferredTimescale: 600)
            player.isMuted = true
            // Slower for its last moment, then still on the key photo.
            liveMarks = player.addBoundaryTimeObserver(forTimes: [NSValue(time: easing), NSValue(time: key)],
                                                       queue: .main) { [weak self, weak player] in
                MainActor.assumeIsolated {
                    guard let self, let player else { return }
                    if player.currentTime().seconds >= key.seconds - 0.02 {
                        self.stopLive(settling: LiveMotions.Timing.glimpseSettle)
                    } else {
                        player.rate = LiveMotions.Timing.glimpseEaseRate
                    }
                }
            }
            if glimpseCued {
                glimpseCued = false
                showLive(true)
                player.play()
                return
            }
            from = glimpseStart(duration)
        case .whole:
            from = .zero
            player.isMuted = false
            // As a Live Photo comes alive in Photos.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.livePlayer === player else { return }
                self.showLive(true)
                player.play()
            }
        }
    }

    /// The motion over the picture, or the picture again, in a short fade so the still does not jump, then `faded`. It
    /// takes the picture's size as it shows: loaded as the viewer opens, it was made before the picture had one.
    private func showLive(_ shown: Bool, settling: Double = LiveMotions.Timing.settle, faded: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        if let faded { CATransaction.setCompletionBlock { MainActor.assumeIsolated { faded() } } }
        if shown {
            CATransaction.setDisableActions(true)
            liveLayer?.frame = pictureView.bounds
        } else {
            CATransaction.setAnimationDuration(settling)
        }
        liveLayer?.opacity = shown ? 1 : 0
        CATransaction.commit()
    }

    /// The motion stops, and the picture shows again; it stays loaded while the page is in view, cued for the next
    /// glimpse once it has faded: cued at once, the fade would show the glimpse's start rather than where it stopped.
    private func stopLive(settling: Double = LiveMotions.Timing.settle) {
        livePlayer?.pause()
        if let liveMarks { livePlayer?.removeTimeObserver(liveMarks) }
        liveMarks = nil
        livePending = nil
        let starts = liveStarts
        showLive(false, settling: settling) { [weak self] in
            // Unless it started again meanwhile.
            guard let self, self.liveStarts == starts else { return }
            self.cueGlimpse()
        }
    }

    /// The motion goes, as the page leaves the view.
    private func releaseLive() {
        liveLog.debug("release, had a player \(self.livePlayer != nil, privacy: .public)")
        liveLoad?.cancel()
        liveLoad = nil
        glimpseCued = false
        stopLive()
        if state?.liveLoading == item.id { state?.liveLoading = nil }
        if let liveEnd { NotificationCenter.default.removeObserver(liveEnd) }
        liveEnd = nil
        liveStatus = nil
        livePlayer = nil
        liveMotion = nil
        matchedKey = nil
        liveLayer?.removeFromSuperlayer()
        liveLayer = nil
    }
}
