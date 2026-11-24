// How a Live Photo's motion meets its photo: the movie's metadata (global and timed), the key photo's moment it marks,
// the motion frame nearest the photo in time and in look, and the scale and offset that line that frame up with the
// photo best, against laying it over the photo as it is (aspect fit).
//   swiftc -O compare-key.swift -o compare-key && ./compare-key <photo.HEIC> <motion.MOV> [<out.png>]
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let photoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let motionURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outURL = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
let width = 400

func gray(_ image: CGImage, _ w: Int, _ h: Int) -> [Float] {
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<(w * h)).map { (Float(pixels[$0 * 4]) + 2 * Float(pixels[$0 * 4 + 1]) + Float(pixels[$0 * 4 + 2])) / 4 }
}

/// The mean difference of `frame` scaled by `scale` about the centre and moved by (dx, dy), over `photo`.
func difference(_ photo: [Float], _ frame: [Float], _ w: Int, _ h: Int, scale: Float, dx: Float, dy: Float) -> Float {
    var total: Float = 0, count = 0
    let cx = Float(w) / 2, cy = Float(h) / 2
    for y in stride(from: h / 8, to: h * 7 / 8, by: 2) {
        for x in stride(from: w / 8, to: w * 7 / 8, by: 2) {
            let sx = Int((Float(x) - cx - dx) / scale + cx), sy = Int((Float(y) - cy - dy) / scale + cy)
            guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
            total += abs(photo[y * w + x] - frame[sy * w + sx]); count += 1
        }
    }
    return total / Float(max(count, 1))
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil)!
    let photoImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary)!
    let height = Int(Double(width) * Double(photoImage.height) / Double(photoImage.width))
    let photo = gray(photoImage, width, height)
    let asset = AVURLAsset(url: motionURL)
    let duration = try! await asset.load(.duration).seconds
    print("photo \(photoImage.width)x\(photoImage.height); motion \(String(format: "%.3f", duration)) s")
    for item in try! await asset.load(.metadata) {
        print("  movie: \(item.identifier?.rawValue ?? "?") = \(String(describing: try? await item.load(.value)).prefix(80))")
    }
    let videoTrack = try! await asset.loadTracks(withMediaType: .video).first!
    let size = try! await videoTrack.load(.naturalSize)
    let transform = try! await videoTrack.load(.preferredTransform)
    print("  video \(Int(size.width))x\(Int(size.height)), transform \(transform)")
    var keyPhoto: Double?
    for track in try! await asset.loadTracks(withMediaType: .metadata) {
        let formats = try! await track.load(.formatDescriptions)
        let identifiers = formats.flatMap { (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String]) ?? [] }
        print("  timed track: \(identifiers)")
        guard let reader = try? AVAssetReader(asset: asset) else { continue }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        reader.add(output)
        reader.startReading()
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items {
                let value = String(describing: try? await item.load(.value)).prefix(60)
                print(String(format: "    at %.3f s: %@ = %@", group.timeRange.start.seconds, item.identifier?.rawValue ?? "?", String(value)))
                if item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" { keyPhoto = group.timeRange.start.seconds }
            }
        }
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    // The frame that looks most like the photo, laid over it as aspect fit does.
    var best = (time: 0.0, difference: Float.infinity)
    var frames: [Double: [Float]] = [:]
    var time = 0.0
    while time < duration {
        if let (image, actual) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
            let frame = gray(image, width, height)
            frames[actual.seconds] = frame
            let value = difference(photo, frame, width, height, scale: 1, dx: 0, dy: 0)
            if value < best.difference { best = (actual.seconds, value) }
        }
        time += 1.0 / 30
    }
    let keyTime = keyPhoto ?? duration / 2
    let keyFrame = frames.min { abs($0.key - keyTime) < abs($1.key - keyTime) }!
    print(String(format: "key photo marked at %@; its frame %.3f s differs %.2f as laid over; the closest-looking frame is %.3f s at %.2f",
                 keyPhoto.map { String(format: "%.3f s", $0) } ?? "nowhere", keyFrame.key,
                 difference(photo, keyFrame.value, width, height, scale: 1, dx: 0, dy: 0), best.time, best.difference))
    // The scale and offset that line the key frame up with the photo best.
    var fit = (scale: Float(1), dx: Float(0), dy: Float(0), difference: Float.infinity)
    for scale in stride(from: Float(0.9), through: 1.2, by: 0.01) {
        for dx in stride(from: Float(-20), through: 20, by: 2) {
            for dy in stride(from: Float(-20), through: 20, by: 2) {
                let value = difference(photo, keyFrame.value, width, height, scale: scale, dx: dx, dy: dy)
                if value < fit.difference { fit = (scale, dx, dy, value) }
            }
        }
    }
    print(String(format: "best fit of the key frame: scale %.2f, offset %.0f, %.0f (of %d wide), difference %.2f",
                 fit.scale, fit.dx, fit.dy, width, fit.difference))
    if let outURL {
        // The photo, the key frame as laid over it, and their difference, side by side.
        let w = width, h = height
        var sheet = [UInt8](repeating: 255, count: w * 3 * h * 4)
        for y in 0..<h { for x in 0..<w {
            let a = photo[y * w + x], b = keyFrame.value[y * w + x], d = min(255, abs(a - b) * 4)
            for (column, value) in [(0, a), (1, b), (2, d)] {
                let index = (y * w * 3 + column * w + x) * 4
                sheet[index] = UInt8(value); sheet[index + 1] = UInt8(value); sheet[index + 2] = UInt8(value)
            }
        } }
        let context = CGContext(data: &sheet, width: w * 3, height: h, bitsPerComponent: 8, bytesPerRow: w * 12,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }
    semaphore.signal()
}
semaphore.wait()
