// A video's page in the viewer on iOS: its poster until it is the page shown, then the video playing its stream,
// fetched with the account's credential as the Mac's player fetches it, drawn by a player layer over the poster inside
// the page's zooming picture, so a pinch zooms it in and, below its fitted size, closes it into its tile, as a photo's
// page does (ViewerZoomPage; ARCHITECTURE.md, "The viewer on the iPhone"). The viewer's video bar is its controls, in
// the chrome a tap shows and hides (ViewerVideo.swift), so the page hands its player over while it is the page shown.
// It plays when slid to and stops when slid away from, as in Photos; a drag down or a pinch that takes it towards its
// tile pauses it, and one let go short plays it on from where it was, if it was playing.

import AVFoundation
import UIKit

final class ViewerVideoPage: ViewerZoomPage {
    private let videoView = ViewerVideoView()
    private var player: AVPlayer?
    /// A drag down or a pinch is taking the video towards its tile, and it was playing as that began.
    private var closing = false
    private var playsAfterClosing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        pictureView.accessibilityLabel = String(localized: "Video")
        // For UI tests, which pinch the video.
        pictureView.accessibilityIdentifier = "Viewer Video"
        videoView.frame = pictureView.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.playerLayer.videoGravity = .resizeAspect
        pictureView.addSubview(videoView)
        showPoster()
    }

    /// A drag down or a pinch towards the tile pauses the video, its frame shrinking with the page, and the viewer
    /// closing pauses it for good, its poster flying into the tile; let go short, it plays on if it was playing.
    override func closingZoom(_ closing: Bool) {
        if closing {
            if !self.closing { playsAfterClosing = player.map { $0.timeControlStatus != .paused } ?? false }
            self.closing = true
            player?.pause()
        } else {
            self.closing = false
            if isCurrent, playsAfterClosing { player?.play() }
            playsAfterClosing = false
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.pause()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isCurrent, !closing, let player {
            state?.video.attach(player, itemID: item.id)
            posterForNowPlaying()
            player.play()
        }
    }

    override func setCurrent(_ current: Bool) {
        super.setCurrent(current)
        if current { startPlayback() } else { stopPlayback() }
    }

    /// The preview frame, from the pipeline's cache at once, else as it loads.
    private func showPoster() {
        guard let pipeline = state?.session.pipeline else { return }
        let id = item.id
        if let cached = pipeline.cachedThumbnail(id, size: .preview) ?? pipeline.cachedThumbnail(id, size: .thumbnail) {
            showPicture(cached, ownShape: true)
        }
        guard pipeline.cachedThumbnail(id, size: .preview) == nil else { return }
        Task { [weak self] in
            guard let preview = await pipeline.thumbnail(id, size: .preview), let self else { return }
            showPicture(preview, ownShape: true)
            posterForNowPlaying()
        }
    }

    /// The poster shown, as the playing video's artwork in Now Playing.
    private func posterForNowPlaying() {
        guard isCurrent, let poster = pictureView.image?.cgImage else { return }
        state?.video.pictureForNowPlaying(poster, itemID: item.id)
    }

    private func startPlayback() {
        if let player {
            state?.video.attach(player, itemID: item.id)
            posterForNowPlaying()
            player.play()
            return
        }
        guard let client = state?.session.client else { return }
        // Played as a video app plays, with its sound, as Photos plays a video.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: client.videoAsset(item.id)))
        videoView.playerLayer.player = player
        self.player = player
        state?.video.attach(player, itemID: item.id)
        posterForNowPlaying()
        player.play()
    }

    /// Stops and lets the stream go; sliding back plays the video from its start.
    private func stopPlayback() {
        state?.video.detach(itemID: item.id)
        closing = false
        playsAfterClosing = false
        guard let player else { return }
        player.pause()
        videoView.playerLayer.player = nil
        self.player = nil
    }
}

/// The video's frames, drawn by a player layer as the view's own layer, so it takes the picture's size and zooms with
/// it.
final class ViewerVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    /// Always the view's layer, which is made of the class above.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}
