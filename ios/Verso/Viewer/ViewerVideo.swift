// Video in the viewer on iOS, as Photos has it: the video page plays it in its zooming picture (ViewerVideoPage), and
// the viewer's chrome holds its controls: a glass bar where the filmstrip is, above the bottom bar, in the bar's own
// white: Play and Pause, a strip of the video's frames with a white playhead that a finger takes anywhere on it (the
// time over the playhead while it does), Mute, and the system's route button, for AirPlay and Bluetooth headphones. One
// tap shows or hides it with the rest of the chrome, so no two sets of controls ever lie over each other. Play fades
// the chrome a moment after; the end of the video brings it back. ViewerVideoPlayback is the one video playing, which
// its page hands over (ViewerVideoPage), with its frames, read from its stream once, keyframes only. It puts the video
// in Now Playing, with the remote commands that play, pause and move it (MPNowPlayingSession), as a video app's player
// does, named as the viewer's title capsule names it and pictured by its poster, as Photos shows a video there.

import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI

/// The video the viewer plays: its player, handed over by its page while it is the page shown, and what the bar
/// shows of it.
@MainActor @Observable
final class ViewerVideoPlayback {
    /// The photo whose video plays.
    private(set) var itemID: String?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var isMuted = false
    /// While the scrubber is held, the time it points at.
    private(set) var scrubbing: Double?
    /// The strip's frames, evenly through the video, once read.
    private(set) var frames: [CGImage] = []
    /// How many frames the strip holds.
    static let frameCount = 10
    /// The video played to its end: the chrome comes back (ViewerState).
    @ObservationIgnored var ended: () -> Void = {}

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var framesTask: Task<Void, Never>?
    /// The frames read lately, by photo, so sliding back to a video shows its strip at once.
    @ObservationIgnored private var framesKept: [String: [CGImage]] = [:]
    /// The video in Now Playing (the Lock Screen, Control Center, the route button's sheet), published from the player
    /// as it plays, pauses and moves, and the remote commands that play, pause and move it.
    @ObservationIgnored private var nowPlaying: MPNowPlayingSession?
    /// The video's title and poster for Now Playing, by photo, kept until its player is handed over.
    @ObservationIgnored private var nowPlayingTitle: (itemID: String, title: String)?
    @ObservationIgnored private var nowPlayingPoster: (itemID: String, image: CGImage)?

    /// The page shown hands over its player.
    func attach(_ player: AVPlayer, itemID: String) {
        guard self.player !== player else { return }
        release()
        self.player = player
        self.itemID = itemID
        isMuted = player.isMuted
        elapsed = player.currentTime().seconds.finiteOrZero
        duration = player.currentItem?.duration.seconds.finiteOrZero ?? 0
        isPlaying = player.timeControlStatus != .paused
        // Called as time goes, and also whenever playback starts or stops, or the time jumps: what the bar says comes
        // from the player each time, so its button never says Play while the video plays.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time.seconds.finiteOrZero) }
        }
        frames = framesKept[itemID] ?? []
        if frames.isEmpty, let asset = player.currentItem?.asset { readFrames(asset, itemID: itemID) }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus != .paused
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        })
        if let item = player.currentItem {
            observations.append(item.observe(\.duration, options: [.new]) { [weak self] _, change in
                let seconds = change.newValue?.seconds.finiteOrZero ?? 0
                Task { @MainActor [weak self] in self?.duration = seconds }
            })
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPlaying = false
                    self?.ended()
                }
            }
        }
        describeForNowPlaying()
        startNowPlaying(player)
    }

    /// The video's title, as the viewer's capsule names it: its place, else its day.
    func nameForNowPlaying(_ title: String, itemID: String) {
        nowPlayingTitle = (itemID, title)
        describeForNowPlaying()
    }

    /// The video's poster, Now Playing's artwork.
    func pictureForNowPlaying(_ poster: CGImage, itemID: String) {
        nowPlayingPoster = (itemID, poster)
        describeForNowPlaying()
    }

    /// The playing item's title and artwork, which the session publishes with it: without them, the route button's
    /// sheet shows the app's name beside a blank square.
    private func describeForNowPlaying() {
        guard let itemID, let playerItem = player?.currentItem else { return }
        var info: [String: Any] = [:]
        if let named = nowPlayingTitle, named.itemID == itemID, !named.title.isEmpty {
            info[MPMediaItemPropertyTitle] = named.title
        }
        if let poster = nowPlayingPoster, poster.itemID == itemID {
            info[MPMediaItemPropertyArtwork] = Self.artwork(poster.image)
        }
        playerItem.nowPlayingInfo = info.isEmpty ? nil : info
    }

    /// The poster as Now Playing's artwork, made outside the main actor: the system asks for its picture on a thread
    /// of its own.
    nonisolated private static func artwork(_ poster: CGImage) -> MPMediaItemArtwork {
        let picture = UIImage(cgImage: poster)
        return MPMediaItemArtwork(boundsSize: picture.size) { _ in picture }
    }

    /// The page lets its player go, slid away from.
    func detach(itemID: String) {
        guard self.itemID == itemID else { return }
        release()
    }

    /// The viewer has closed: nothing plays, and Now Playing lets the video go.
    func end() {
        release()
    }

    /// The video in Now Playing, as a video app's is, with the commands the Lock Screen, Control Center and headphones
    /// send.
    private func startNowPlaying(_ player: AVPlayer) {
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        let commands = session.remoteCommandCenter
        commands.playCommand.addTarget(handler: Self.remoteCommand { [weak self] _ in
            if self?.player?.timeControlStatus == .paused { self?.togglePlay() }
        })
        commands.pauseCommand.addTarget(handler: Self.remoteCommand { [weak self] _ in self?.player?.pause() })
        commands.togglePlayPauseCommand.addTarget(handler: Self.remoteCommand { [weak self] _ in self?.togglePlay() })
        commands.changePlaybackPositionCommand.addTarget(handler: Self.remoteCommand { [weak self] position in
            guard let position else { return }
            self?.player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
                               toleranceAfter: .zero)
        })
        session.becomeActiveIfPossible(completion: nil)
        nowPlaying = session
    }

    /// A remote command's handler, made outside the main actor as MediaPlayer may call it on another thread: it does
    /// `action` on the main actor, with the place a scrub asks for.
    nonisolated private static func remoteCommand(
        _ action: @escaping @Sendable @MainActor (_ position: Double?) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            Task { @MainActor in action(position) }
            return .success
        }
    }

    /// The strip's frames: keyframes near evenly spaced times, small, read from the stream the player plays.
    private func readFrames(_ asset: AVAsset, itemID: String) {
        framesTask?.cancel()
        framesTask = Task { [weak self] in
            guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            let spacing = CMTime(seconds: seconds / Double(Self.frameCount), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = spacing
            generator.requestedTimeToleranceAfter = spacing
            let times = (0..<Self.frameCount).map { index in
                CMTime(seconds: seconds * (Double(index) + 0.5) / Double(Self.frameCount), preferredTimescale: 600)
            }
            var read: [CGImage] = []
            for await result in generator.images(for: times) {
                guard !Task.isCancelled else { return }
                if let image = try? result.image { read.append(image) }
            }
            guard let self, !Task.isCancelled, read.count == Self.frameCount else { return }
            framesKept[itemID] = read
            if framesKept.count > 8, let other = framesKept.keys.first(where: { $0 != itemID }) { framesKept[other] = nil }
            if self.itemID == itemID { frames = read }
        }
    }

    private func release() {
        // The player taken out of its session, which stops publishing it. Switching the publishing off first took the
        // session's observers of the player away already, and taking the player out then threw.
        if let nowPlaying {
            for player in nowPlaying.players { nowPlaying.removePlayer(player) }
        }
        nowPlaying = nil
        framesTask?.cancel()
        framesTask = nil
        frames = []
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        observations = []
        player = nil
        itemID = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        scrubbing = nil
    }

    private func timeChanged(_ seconds: Double) {
        if let player { isPlaying = player.timeControlStatus != .paused }
        guard scrubbing == nil else { return }
        elapsed = seconds
    }

    /// Play or pause; at the end, play from the start again.
    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, elapsed >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.timeControlStatus != .paused || player.rate != 0
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        isMuted = player.isMuted
    }

    /// The scrubber held: the video holds still under it, and plays on when it is let go if it was playing.
    func beginScrub() {
        guard let player else { return }
        resumeAfterScrub = player.timeControlStatus != .paused
        player.pause()
        scrubbing = elapsed
    }

    func scrub(to seconds: Double) {
        guard let player else { return }
        scrubbing = seconds
        let tolerance = CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrub() {
        guard let player, let seconds = scrubbing else { return }
        elapsed = seconds
        scrubbing = nil
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if resumeAfterScrub { player.play() }
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }

    func clamped(_ lower: Double, _ upper: Double) -> Double { Swift.min(upper, Swift.max(lower, self)) }
}

/// The video's bar, in the filmstrip's place above the bottom bar: Play and Pause, the frames' strip with its playhead,
/// Mute and the route button, in one glass capsule, in the viewer's white.
struct ViewerVideoBar: View {
    let video: ViewerVideoPlayback
    /// Play was pressed: the chrome fades a moment after, as in Photos.
    let played: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(video.isPlaying ? "Pause" : "Play", systemImage: video.isPlaying ? "pause.fill" : "play.fill") {
                let starting = !video.isPlaying
                video.togglePlay()
                if starting { played() }
            }
            .contentTransition(.symbolEffect(.replace))
            .modifier(ViewerBarItem(width: 44, height: 48))
            ViewerVideoStrip(video: video)
                .padding(.vertical, 8)
            Button(video.isMuted ? "Unmute" : "Mute", systemImage: video.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                video.toggleMute()
            }
            .contentTransition(.symbolEffect(.replace))
            .modifier(ViewerBarItem(width: 44, height: 48))
            ViewerRoutePicker()
                .frame(width: 40, height: 48)
                .accessibilityLabel("AirPlay and Audio Output")
        }
        .padding(.horizontal, 4)
        .disabled(video.itemID == nil)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Video Bar")
    }

    /// "0:42", or "1:02:05" past an hour.
    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600, minutes = (whole % 3600) / 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The video's frames side by side, a white playhead where it plays, and a finger on the strip, anywhere, scrubbing:
/// the time shows over the playhead while it does. Until the frames are read, a quiet track.
private struct ViewerVideoStrip: View {
    let video: ViewerVideoPlayback

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shown = video.scrubbing ?? video.elapsed
            let progress = video.duration > 0 ? min(1, max(0, shown / video.duration)) : 0
            let height = proxy.size.height
            let playheadX = min(max(2, width * progress), width - 2)
            // The frames and the playhead placed at the strip's middle by position: a GeometryReader puts what it
            // holds at its top, so the playhead, taller than the frames, pushed them down and its own foot past the
            // bar's edge.
            ZStack {
                HStack(spacing: 0) {
                    if video.frames.isEmpty {
                        Rectangle().fill(.white.opacity(0.15))
                    } else {
                        // Each frame drawn as it is held, never by its place in the list: as the viewer closes,
                        // the list empties while the bar still fades, and a place read then would be past its end.
                        let frames = video.frames
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                            Image(decorative: frame, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(frames.count), height: height)
                                .clipped()
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: 6))
                .position(x: width / 2, y: height / 2)
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: height + 8)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .position(x: playheadX, y: height / 2)
                if let scrubbing = video.scrubbing {
                    Text(ViewerVideoBar.time(scrubbing))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .position(x: playheadX, y: height / 2 - 34)
                }
            }
            .frame(width: width, height: height)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if video.scrubbing == nil { video.beginScrub() }
                        let fraction = min(1, max(0, value.location.x / max(width, 1)))
                        video.scrub(to: fraction * video.duration)
                    }
                    .onEnded { _ in video.endScrub() }
            )
        }
        .padding(.horizontal, 6)
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue(ViewerVideoBar.time(video.scrubbing ?? video.elapsed))
        .accessibilityAdjustableAction { direction in
            let step = max(1, video.duration / 20)
            let target = (video.elapsed + (direction == .increment ? step : -step)).clamped(0, video.duration)
            video.beginScrub()
            video.scrub(to: target)
            video.endScrub()
        }
    }
}

/// The system's route button: AirPlay, and Bluetooth headphones and speakers, in the bar's white.
private struct ViewerRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        // White whether or not it plays elsewhere: the accent made it blue with AirPods in, against the video's dark,
        // and the system shows the connection itself.
        picker.tintColor = .label
        picker.activeTintColor = .label
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
