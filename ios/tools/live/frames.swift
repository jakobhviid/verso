// Writes the frames of a recording nearest the given times as JPEGs.  swift frames.swift <recording> <folder> <time>...
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
let times = CommandLine.arguments.dropFirst(3).map { Double($0)! }
let semaphore = DispatchSemaphore(value: 0)
Task {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 440, height: 956)
    for time in times {
        let (image, _) = try! await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let file = folder.appendingPathComponent(String(format: "frame-%.2f.jpg", time)) as CFURL
        let destination = CGImageDestinationCreateWithURL(file, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    semaphore.signal()
}
semaphore.wait()
