// An Apple Live Photo pair from a video, as the Camera writes one, for the lab and the Simulator: three seconds of the
// video as the motion (a QuickTime movie), the frame at the key photo's moment as the still (a JPEG), one identifier in
// both (the JPEG's Apple maker note 17, the movie's com.apple.quicktime.content.identifier), and the key photo's moment
// marked in the movie (com.apple.quicktime.still-image-time).
//   swiftc -O make-pair.swift -o make-pair && ./make-pair <video> <start s> <key photo s within the three> <name> <folder>
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let source = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
let start = Double(arguments[2])!
let key = Double(arguments[3])!
let name = arguments[4]
let folder = URL(fileURLWithPath: arguments[5])
let identifier = UUID().uuidString
let cut = folder.appendingPathComponent("\(name)-cut.mp4")
let still = folder.appendingPathComponent("\(name).JPG")
let movie = folder.appendingPathComponent("\(name).MOV")
for file in [cut, still, movie] { try? FileManager.default.removeItem(at: file) }

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        // The three seconds.
        let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPreset1280x720)!
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: 3, preferredTimescale: 600))
        try await export.export(to: cut, as: .mp4)
        let asset = AVURLAsset(url: cut)

        // The still: the frame at the key photo's moment, with the identifier.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await generator.image(at: CMTime(seconds: key, preferredTimescale: 600))
        let destination = CGImageDestinationCreateWithURL(still as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)

        // The movie: the video as it is, with the identifier and the key photo's moment.
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let content = AVMutableMetadataItem()
        content.key = "com.apple.quicktime.content.identifier" as NSString
        content.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        content.value = identifier as NSString
        content.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [content]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: try await track.load(.formatDescriptions).first)
        writer.add(videoInput)
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
        ]
        var metadataFormat: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &metadataFormat)
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataFormat)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        writer.add(metadataInput)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let marker = AVMutableMetadataItem()
        marker.key = "com.apple.quicktime.still-image-time" as NSString
        marker.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        marker.value = 0 as NSNumber
        marker.dataType = "com.apple.metadata.datatype.int8"
        adaptor.append(AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: actual, duration: CMTime(value: 1, timescale: 100))))
        metadataInput.markAsFinished()
        while let sample = output.copyNextSampleBuffer() {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            videoInput.append(sample)
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        try? FileManager.default.removeItem(at: cut)
        print("\(name): key photo at \(String(format: "%.3f", actual.seconds)) s of 3 s, identifier \(identifier), writer \(writer.status.rawValue)")
    } catch {
        print("failed: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
