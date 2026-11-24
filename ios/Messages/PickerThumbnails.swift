// The picker's thumbnails (PickerLibrary), small because an extension has a fraction of an app's memory: Immich's
// small thumbnail (about 250 pixels), through the picker's session, whose cache is on disk; decoded straight to the
// tile's pixels off the main thread (ImageIO's thumbnail, which never holds a larger image), only as a tile shows;
// and kept in a cache of about two screens of tiles, which the system empties when memory runs short.

import Foundation
import ImageIO
import UIKit

final class PickerThumbnails: Sendable {
    private let client: ImmichClient
    // NSCache is thread-safe.
    nonisolated(unsafe) private let cache: NSCache<NSString, UIImage>

    init(client: ImmichClient) {
        self.client = client
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 << 20
        self.cache = cache
    }

    func cached(_ id: String, pixels: Int) -> UIImage? {
        cache.object(forKey: Self.key(id, pixels))
    }

    /// The photo's thumbnail at most `pixels` on its long side; nil when it cannot be had, or the tile went first.
    func thumbnail(_ id: String, pixels: Int) async -> UIImage? {
        if let cached = cached(id, pixels: pixels) { return cached }
        guard let (data, response) = try? await client.session.data(for: client.thumbnailRequest(id, size: .thumbnail)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !Task.isCancelled,
              let image = await Self.decode(data, pixels: pixels) else { return nil }
        cache.setObject(image, forKey: Self.key(id, pixels), cost: Int(image.size.width * image.size.height) * 4)
        return image
    }

    private static func key(_ id: String, _ pixels: Int) -> NSString { "\(id)-\(pixels)" as NSString }

    @concurrent private static func decode(_ data: Data, pixels: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
