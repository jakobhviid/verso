// How far each frame of a recording is from one frame at rest, in a band across the middle, within given windows:
// a Live Photo's motion shows as frames that differ from its still.  swift against.swift <recording> <rest time> <from-to>...
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let rest = Double(CommandLine.arguments[2])!
let windows = CommandLine.arguments.dropFirst(3).map { $0.split(separator: "-").map { Double($0)! } }
func band(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var values: [UInt8] = []
    for y in Int(Double(height) * 0.35)..<Int(Double(height) * 0.6) {
        for x in Int(Double(width) * 0.1)..<Int(Double(width) * 0.9) {
            let pixel = base + y * row + x * 4
            values.append(UInt8((Int(pixel[0]) + Int(pixel[1]) * 2 + Int(pixel[2])) / 4))
        }
    }
    return values
}
func change(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total = 0
    for index in 0..<min(a.count, b.count) { total += abs(Int(a[index]) - Int(b[index])) }
    return Double(total) / Double(a.count)
}
let semaphore = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: url)
    let track = try! await asset.loadTracks(withMediaType: .video).first!
    let reader = try! AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 220, kCVPixelBufferHeightKey as String: 478])
    reader.add(output)
    reader.startReading()
    var frames: [(Double, [UInt8])] = []
    while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
        frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, band(buffer)))
    }
    let reference = frames.min { abs($0.0 - rest) < abs($1.0 - rest) }!.1
    for window in windows {
        var line = String(format: "%.2f-%.2f:", window[0], window[1])
        var lastPrinted = -1.0
        for (time, values) in frames where time >= window[0] && time <= window[1] && time - lastPrinted >= 0.05 {
            line += String(format: " %.2f=%.1f", time, change(values, reference))
            lastPrinted = time
        }
        print(line)
    }
    semaphore.signal()
}
semaphore.wait()
