// A Live Photo's motion as the viewers play it, on the iPhone and the Mac alike (AVFoundation alone, so both apps
// compile it): the movie Immich keeps as the photo's motion, its original (the Camera's own, with its marks, which a
// transcoded copy may lose), downloaded once into the caches folder, the 40 last used kept, so it plays at once and its
// mark of the key photo's moment can be read (ARCHITECTURE.md, "Live Photos"): com.apple.quicktime.still-image-time. A
// mark at the movie's very start is taken as none (trimmed movies keep it there, as an iPhone 15's do), and a
// motion without one, a Google motion photo's, whose moment Immich does not pass on, is matched against the photo
// instead: the moment that looks most like it (`keyPhoto(matching:)`). Signing out empties the folder.
//
// The Camera's movie keeps the whole frame it recorded, the photo's field, and marks a stabilised crop of it, its clean
// aperture (1744 by 1308 of 1920 by 1440 in an iPhone's Live Photos), which players show by default. Photos
// plays the whole frame over the photo, and so do the viewers (`videoApertureMode = .encodedPixels`), so the motion
// meets the photo where it lies; the matching compares the whole frame too.

import AVFoundation
import CoreGraphics

actor LiveMotions {
    static let shared = LiveMotions()

    struct Motion: Sendable {
        let file: URL
        /// The key photo's moment in the motion, where the movie marks it.
        let keyPhoto: CMTime?
    }

    /// Photos' glimpse on the iPhone: the 0.6 s of motion up to the key photo, at its own speed and, for its last
    /// 0.17 s, at 0.7 of it, then a 0.25 s fade into the photo. A whole play is back at the still in 0.3 s.
    enum Timing {
        static let glimpseLead: Double = 0.6
        static let glimpseEase: Double = 0.17
        static let glimpseEaseRate: Float = 0.7
        static let glimpseSettle: Double = 0.25
        static let settle: Double = 0.3
    }

    /// The key photo's moment in a motion of `duration`: as its movie marks it or as matching found it, else its middle,
    /// as a Live Photo is about as long before its photo as after.
    nonisolated static func keyPhoto(_ found: CMTime?, duration: CMTime) -> CMTime {
        if let found, found.isNumeric, found.seconds > 0, found < duration { return found }
        return CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
    }

    /// Where a glimpse starts: its lead before the key photo, or the motion's start.
    nonisolated static func glimpseStart(_ found: CMTime?, duration: CMTime) -> CMTime {
        CMTime(seconds: max(0, keyPhoto(found, duration: duration).seconds - Timing.glimpseLead), preferredTimescale: 600)
    }

    private static let kept = 40
    private static let stillImageTime = "mdta/com.apple.quicktime.still-image-time"
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveMotions", isDirectory: true)
    private var loading: [String: Task<Motion, any Error>] = [:]
    /// The key photos found by matching, by motion.
    private var matched: [URL: CMTime] = [:]

    /// The motion `videoID`, from the cache or downloaded with `request` (the original's, with the account's
    /// credential); one download for callers asking at once.
    func motion(_ videoID: String, request: URLRequest) async throws -> Motion {
        if let task = loading[videoID] { return try await task.value }
        let task = Task { try await load(videoID, request: request) }
        loading[videoID] = task
        do {
            let motion = try await task.value
            loading[videoID] = nil
            return motion
        } catch {
            loading[videoID] = nil
            throw error
        }
    }

    private func load(_ videoID: String, request: URLRequest) async throws -> Motion {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(videoID + ".mov")
        if manager.fileExists(atPath: file.path) {
            try? manager.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        } else {
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                try? manager.removeItem(at: downloaded)
                throw URLError(.badServerResponse)
            }
            try? manager.removeItem(at: file)
            try manager.moveItem(at: downloaded, to: file)
            trim()
        }
        return await Self.marks(in: file)
    }

    /// The movie's mark of the key photo's moment.
    private static func marks(in file: URL) async -> Motion {
        let asset = AVURLAsset(url: file)
        var keyPhoto: CMTime?
        for track in (try? await asset.loadTracks(withMediaType: .metadata)) ?? [] {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let identifiers = formats.flatMap { (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String]) ?? [] }
            guard identifiers.contains(stillImageTime), let reader = try? AVAssetReader(asset: asset) else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                // At the very start the mark says nothing: a trimmed movie keeps it there.
                if group.items.contains(where: { $0.identifier?.rawValue == stillImageTime }),
                   group.timeRange.start.seconds > 0.02 {
                    keyPhoto = group.timeRange.start
                }
            }
        }
        return Motion(file: file, keyPhoto: keyPhoto)
    }

    /// The key photo of a motion that does not mark it: the moment whose whole frame looks most like `photo`, compared
    /// small.
    func keyPhoto(matching photo: CGImage, in motion: Motion) async -> CMTime? {
        if let found = matched[motion.file] { return found }
        let asset = AVURLAsset(url: motion.file)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let width = 48, height = max(1, Int((48 * Double(photo.height) / Double(photo.width)).rounded()))
        let target = Self.gray(photo, width, height)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .encodedPixels
        generator.maximumSize = CGSize(width: width * 2, height: height * 2)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var best: (time: CMTime, difference: Float)?
        var seconds = 0.0
        while seconds < duration.seconds {
            if let (image, actual) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                let frame = Self.gray(image, width, height)
                var total: Float = 0
                for index in 0..<frame.count { total += abs(frame[index] - target[index]) }
                if best == nil || total < best!.difference { best = (actual, total) }
            }
            seconds += 1.0 / 30
        }
        if let time = best?.time { matched[motion.file] = time }
        return best?.time
    }

    /// An image's brightness at a small size, for comparing.
    private static func gray(_ image: CGImage, _ width: Int, _ height: Int) -> [Float] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<(width * height)).map {
            (Float(pixels[$0 * 4]) + 2 * Float(pixels[$0 * 4 + 1]) + Float(pixels[$0 * 4 + 2])) / 4
        }
    }

    /// Every motion goes, as the account signs out: they are its photos.
    func removeAll() {
        for task in loading.values { task.cancel() }
        loading = [:]
        matched = [:]
        try? FileManager.default.removeItem(at: folder)
    }

    /// The 40 last used motions stay; older ones go.
    private func trim() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let byAge = files.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for file in byAge.dropFirst(Self.kept) { try? manager.removeItem(at: file) }
    }
}
