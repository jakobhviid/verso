// A photo on its way to Immich as a square tile (ROADMAP.md, M10, "Backing the iPhone up"), in the Library's timeline
// among Immich's photos and in On Its Way on the Backup page: the phone's own picture (PhotoKit), so it shows at once,
// drawn as Immich's tiles are (GridTile), with a favourite's heart and a video's length at its foot, and its state as a
// small mark in its top trailing corner (BackupTileMarkView): a ring filling while it uploads, a cloud with an upward
// arrow while it waits, a clock while the connection keeps it back, and an exclamation mark when it needs a look.
// Nothing fades in as it loads.

import AVFoundation
import Photos
import SwiftUI
import UIKit

struct BackupPhoneTile: View {
    let photo: BackupWaitingPhoto
    /// Its state's mark; none once it arrived and waits for Immich's photo to take its place.
    let mark: BackupTileMark?
    let side: CGFloat
    var isSelected = false
    var isSelecting = false
    /// The aspect ratio grid: the whole photo inside its square.
    var fitsWhole = false
    @State private var image: UIImage?
    @State private var duration: TimeInterval?
    @State private var shownID: String?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let contentMode: ContentMode = fitsWhole ? .fit : .fill
        Rectangle()
            .fill(!fitsWhole || image == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .frame(width: side, height: side)
            .overlay {
                // Drawn again, a tile shows the picture it had at once.
                if let picture = image ?? PhoneImages.cached(photo.localID) {
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .overlay(alignment: .bottom) {
                if side >= 44 { badges }
            }
            .overlay(alignment: .topTrailing) {
                if let mark, side >= 30 {
                    BackupTileMarkView(mark: mark, size: min(15, max(11, side / 7)))
                        .padding(max(3, min(6, side / 18)))
                }
            }
            .overlay {
                if isSelecting && isSelected {
                    Color.white.opacity(0.18)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: min(22, side / 4)))
                        .background(Circle().fill(.white).padding(2))
                        .padding(4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: "\(photo.localID)|\(Int(side))") { await load() }
    }

    /// A favourite's heart at the foot's left and a video's length at its right, as Immich's tiles have them.
    @ViewBuilder
    private var badges: some View {
        let showsVideo = photo.isVideo && !(isSelecting && isSelected)
        if photo.favorite || showsVideo {
            HStack(spacing: 3) {
                if photo.favorite { Image(systemName: "heart.fill") }
                Spacer(minLength: 0)
                if showsVideo {
                    if let duration, side >= 64 {
                        Text(Duration.formatMilliseconds(Int(duration * 1000)))
                            .monospacedDigit()
                    } else {
                        Image(systemName: "video.fill")
                    }
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
    }

    private func load() async {
        if shownID != photo.localID {
            image = nil
            duration = nil
            shownID = photo.localID
        }
        if photo.isVideo { duration = BackupLibrary.asset(photo.localID)?.duration }
        let pixels = CGSize(width: side * displayScale, height: side * displayScale)
        for await picture in PhoneImages.pictures(photo.localID, size: pixels, mode: .aspectFill) {
            image = picture
        }
    }
}

/// A photo on its way's mark: white, with the badges' soft shadow, so it reads on any photo.
struct BackupTileMarkView: View {
    let mark: BackupTileMark
    let size: CGFloat

    var body: some View {
        Group {
            switch mark {
            case .uploading(let fraction):
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.4), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: max(0.04, min(1, fraction ?? 0)))
                        .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)
            case .waiting:
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white)
            case .waitingForConnection:
                Image(systemName: "clock")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white)
            case .needsLook:
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .font(.system(size: size + 1, weight: .semibold))
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 1.5)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(2, size / 6) }
}

/// The phone's pictures of its photos, from PhotoKit: a quick one first where the better one takes longer, and the
/// better one after, from iCloud where the photo is only there. The largest of each photo's is kept a while, so a tile
/// drawn again, and Immich's tile that takes a photo's place once it arrived, show it at once.
enum PhoneImages {
    private nonisolated(unsafe) static let kept: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// The largest picture of a photo loaded lately, if any.
    static func cached(_ localID: String) -> UIImage? {
        kept.object(forKey: localID as NSString)
    }

    private static func keep(_ image: UIImage, for localID: String) {
        if let old = cached(localID), old.size.width * old.scale >= image.size.width * image.scale { return }
        kept.setObject(image, forKey: localID as NSString)
    }

    static func pictures(_ localID: String, size: CGSize, mode: PHImageContentMode) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            guard let asset = BackupLibrary.asset(localID) else {
                continuation.finish()
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            let request = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: mode,
                                                                options: options) { image, info in
                if let image {
                    keep(image, for: localID)
                    continuation.yield(image)
                }
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if !degraded || info?[PHImageErrorKey] != nil || info?[PHImageCancelledKey] as? Bool == true {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in PHImageManager.default().cancelImageRequest(request) }
        }
    }

    /// A video's player item, from iCloud where it is only there; PhotoKit answers on a queue of its own.
    static func playerItem(_ localID: String) async -> AVPlayerItem? {
        guard let asset = BackupLibrary.asset(localID) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    /// The phone's copy of a photo as Photos shows it now (an edit's rendering where it was edited), written into
    /// `folder` under its own name, for sharing.
    static func export(_ localID: String, into folder: URL) async throws -> URL {
        guard let asset = BackupLibrary.asset(localID) else { throw BackupError.gone }
        let resources = PHAssetResource.assetResources(for: asset)
        let edited = resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
        let original = resources.first { [.photo, .video].contains($0.type) }
        guard let resource = edited ?? original else { throw BackupError.changed }
        let stem = ((original?.originalFilename ?? resource.originalFilename) as NSString).deletingPathExtension
        let name = stem + "." + (resource.originalFilename as NSString).pathExtension
        let file = folder.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? localID.replacingOccurrences(of: "/", with: "-") : name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
    }
}
