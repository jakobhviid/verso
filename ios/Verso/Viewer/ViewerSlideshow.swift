// The slideshow on iOS, from the viewer's More menu, as the Mac's: the page's photos from the shown one on, full screen
// on black, one after another in the viewer's order, a photo for five seconds and a video to its end (or once it has
// stalled for half a minute), each fading into the next; a tap stops it, and the viewer shows the photo it stopped on.
// It stays on the last photo at the end of the page, and the screen stays on while it plays.

import AVFoundation
import SwiftUI
import UIKit

struct ViewerSlideshow: View {
    let state: ViewerState
    /// Ends the slideshow on the photo it shows.
    let stop: (AssetItem?) -> Void
    @State private var slide: Slide?

    /// What the slideshow shows: a photo's preview, or a video playing over its preview.
    private struct Slide: Identifiable {
        let item: AssetItem
        let image: CGImage?
        let player: AVPlayer?
        var id: String { item.id }
    }

    /// How long a photo shows, the Mac's slideshow's own interval unless changed there.
    private static let photoInterval: Duration = .seconds(5)
    /// A video that has not played for this long moves on, as on the Mac.
    private static let stalledVideoLimit: Duration = .seconds(30)

    var body: some View {
        ZStack {
            Color.black
            if let slide {
                ZStack {
                    if let image = slide.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    }
                    if let player = slide.player {
                        ViewerSlideshowVideo(player: player)
                    }
                }
                .id(slide.id)
                .transition(.opacity)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Slideshow"))
        .accessibilityHint(Text("Double-tap to stop the slideshow."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await play() }
        .onDisappear { slide?.player?.pause() }
    }

    private func finish() {
        slide?.player?.pause()
        stop(slide?.item)
    }

    /// One slide after another until the page ends or the slideshow is stopped.
    private func play() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        var next = state.currentItem
        while let item = next, !Task.isCancelled {
            let prepared = await prepare(item)
            guard !Task.isCancelled else { return }
            if let prepared {
                let previous = slide
                // The first is the photo the viewer showed, there at once; the rest fade in.
                withAnimation(previous == nil ? nil : .easeInOut(duration: 0.6)) { slide = prepared }
                previous?.player?.pause()
                if let player = prepared.player {
                    player.play()
                    await waitForEnd(of: player)
                } else {
                    try? await Task.sleep(for: Self.photoInterval)
                }
            }
            guard !Task.isCancelled else { return }
            next = await state.nextPhoto(after: item.id)
        }
    }

    /// The slide for a photo, or nil for one whose preview does not load, which is passed over.
    private func prepare(_ item: AssetItem) async -> Slide? {
        let pipeline = state.session.pipeline
        var image = pipeline.cachedThumbnail(item.id, size: .preview)
        if image == nil { image = await pipeline.thumbnail(item.id, size: .preview) }
        guard item.isVideo else { return image.map { Slide(item: item, image: $0, player: nil) } }
        let client = state.session.client
        // Played as a video app plays, with its sound, as the viewer plays a video.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let asset = AVURLAsset(url: client.videoURL(item.id),
                               options: ["AVURLAssetHTTPHeaderFieldsKey": client.credential?.headers ?? [:]])
        return Slide(item: item, image: image, player: AVPlayer(playerItem: AVPlayerItem(asset: asset)))
    }

    /// Until the video has played to its end, failed, or stalled too long.
    private func waitForEnd(of player: AVPlayer) async {
        let step = Duration.milliseconds(250)
        var stalled = Duration.zero
        while !Task.isCancelled {
            try? await Task.sleep(for: step)
            guard let playing = player.currentItem, playing.status != .failed else { return }
            let length = playing.duration.seconds
            if length.isFinite, length > 0, player.currentTime().seconds >= length - 0.1 { return }
            stalled = player.timeControlStatus == .playing ? .zero : stalled + step
            if stalled >= Self.stalledVideoLimit { return }
        }
    }
}

/// A video playing in the slideshow, fitted, without controls.
private struct ViewerSlideshowVideo: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer?.player !== player { view.playerLayer?.player = player }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }
}
