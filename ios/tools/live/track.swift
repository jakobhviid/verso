// Which moment of a Live Photo's motion a screen recording shows, frame by frame, also while the photo slides in: for
// each recorded frame in a window, where the photo's left edge is (found by matching the still across the screen),
// then the motion frame that best matches what is visible of it (its whole frame, as Photos plays it), at what scale
// about the photo's centre (with `scale`, from 0.84 to 1.16), and how close the still is.
//   swiftc -O track.swift -o track && ./track <recording> <motion.MOV> <still> <rest time> <from> <to> [scale]
import AVFoundation
import CoreGraphics
import ImageIO

let arguments = CommandLine.arguments
let recordingURL = URL(fileURLWithPath: arguments[1])
let motionURL = URL(fileURLWithPath: arguments[2])
let stillURL = URL(fileURLWithPath: arguments[3])
let restTime = Double(arguments[4])!
let from = Double(arguments[5])!
let to = Double(arguments[6])!
let scales: [Float] = arguments.count > 7 ? stride(from: Float(0.84), through: 1.16, by: 0.02).map { $0 } : [1]
let screenWidth = 440, screenHeight = 956

struct Gray { let width: Int; let height: Int; var values: [Float] }

func gray(_ image: CGImage, width: Int, height: Int) -> Gray {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var values = [Float](repeating: 0, count: width * height)
    for index in 0..<(width * height) {
        values[index] = (Float(pixels[index * 4]) + Float(pixels[index * 4 + 1]) * 2 + Float(pixels[index * 4 + 2])) / 4
    }
    return Gray(width: width, height: height, values: values)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    // The recording's frames, in screen points.
    let recording = AVURLAsset(url: recordingURL)
    let reader = try! AVAssetReader(asset: recording)
    let track = try! await recording.loadTracks(withMediaType: .video).first!
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: screenWidth, kCVPixelBufferHeightKey as String: screenHeight])
    reader.add(output)
    reader.startReading()
    var frames: [(Double, Gray)] = []
    while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        // The screen at rest: the last frame shown by then (a recording keeps frames only as the screen changes).
        guard (time >= from && time <= to) || time <= restTime else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var values = [Float](repeating: 0, count: screenWidth * screenHeight)
        for y in 0..<screenHeight {
            for x in 0..<screenWidth {
                let pixel = base + y * row + x * 4
                values[y * screenWidth + x] = (Float(pixel[0]) + Float(pixel[1]) * 2 + Float(pixel[2])) / 4
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        frames.append((time, Gray(width: screenWidth, height: screenHeight, values: values)))
    }
    // The photo's place at rest: the rows it fills from edge to edge (the bars over it do not).
    let rest = frames.last { $0.0 <= restTime }!.1
    frames.removeAll { $0.0 < from }
    var photoRows: [Int] = []
    for y in 0..<screenHeight {
        var lit = 0
        for x in 0..<screenWidth where rest.values[y * screenWidth + x] > 25 { lit += 1 }
        if Double(lit) > Double(screenWidth) * 0.85 { photoRows.append(y) }
    }
    let stillImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(stillURL as CFURL, nil)!, 0, nil)!
    let photoWidth = screenWidth
    let photoHeight = Int((Double(photoWidth) * Double(stillImage.height) / Double(stillImage.width)).rounded())
    // Where the photo sits at rest: the still slid up and down over the resting screen, the best fit taken.
    let restStill = gray(stillImage, width: photoWidth, height: photoHeight)
    var photoTop = screenHeight / 2 - photoHeight / 2
    var bestFit = Float.infinity
    for top in max(0, photoTop - 200)...min(screenHeight - photoHeight, photoTop + 200) {
        var total: Float = 0
        for row in stride(from: 0, to: photoHeight, by: 3) {
            for x in stride(from: 0, to: photoWidth, by: 3) {
                total += abs(rest.values[(top + row) * screenWidth + x] - restStill.values[row * photoWidth + x])
            }
        }
        if total < bestFit { bestFit = total; photoTop = top }
    }
    print("photo at rest: \(photoWidth)x\(photoHeight) at y \(photoTop) (rows lit across: \(photoRows.first ?? -1)-\(photoRows.last ?? -1))")
    let still = gray(stillImage, width: photoWidth, height: photoHeight)
    // The motion's frames, every 1/60 s.
    let motion = AVURLAsset(url: motionURL)
    let duration = try! await motion.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: motion)
    // The whole frame, as Photos and Verso play it, not the stabilised crop.
    generator.apertureMode = .encodedPixels
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var motionFrames: [(Double, Gray)] = []
    var time = 0.0
    while time < duration {
        if let (image, actual) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
           motionFrames.last.map({ abs($0.0 - actual.seconds) > 0.001 }) ?? true {
            motionFrames.append((actual.seconds, gray(image, width: photoWidth, height: photoHeight)))
        }
        time += 1.0 / 60
    }
    // Rows of the photo used for matching: its middle half, clear of any bars over it.
    let rows = (photoHeight / 4)..<(photoHeight * 3 / 4)
    func difference(_ screen: Gray, _ photo: Gray, edge: Int, scale: Float = 1) -> Float {
        let first = max(0, edge), last = min(screenWidth, edge + photoWidth)
        guard last - first >= 40 else { return .infinity }
        var total: Float = 0, count = 0
        let centreX = Float(photoWidth) / 2, centreY = Float(photoHeight) / 2
        for row in stride(from: rows.lowerBound, to: rows.upperBound, by: scale == 1 ? 1 : 2) {
            let screenRow = (photoTop + row) * screenWidth
            let sourceRow = Int((Float(row) - centreY) / scale + centreY)
            guard sourceRow >= 0, sourceRow < photoHeight else { continue }
            for x in stride(from: first, to: last, by: 2) {
                let sourceX = Int((Float(x - edge) - centreX) / scale + centreX)
                guard sourceX >= 0, sourceX < photoWidth else { continue }
                total += abs(screen.values[screenRow + x] - photo.values[sourceRow * photoWidth + sourceX]); count += 1
            }
        }
        return total / Float(max(count, 1))
    }
    print("time    edge   motion  match   still")
    for (time, frame) in frames where time >= from && time <= to {
        var bestEdge = 0, bestEdgeDifference = Float.infinity
        for edge in -photoWidth / 2...screenWidth - 40 {
            let value = difference(frame, still, edge: edge)
            if value < bestEdgeDifference { bestEdgeDifference = value; bestEdge = edge }
        }
        var bestTime = 0.0, bestDifference = Float.infinity, bestScale: Float = 1
        for scale in scales {
            for (motionTime, motionFrame) in motionFrames {
                let value = difference(frame, motionFrame, edge: bestEdge, scale: scale)
                if value < bestDifference { bestDifference = value; bestTime = motionTime; bestScale = scale }
            }
        }
        print(String(format: "%6.3f  %4d  %6.3f  %6.2f  %6.2f  scale %.2f", time, bestEdge, bestTime, bestDifference,
                     difference(frame, still, edge: bestEdge), bestScale))
    }
    semaphore.signal()
}
semaphore.wait()
