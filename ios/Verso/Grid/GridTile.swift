// One square of a photo grid on iOS, as Photos draws it: the thumbnail filling the square edge to edge, or whole inside
// it in the aspect ratio grid (View Options), its ThumbHash until the thumbnail comes, a favorite's heart at the bottom
// left and a video's length at the bottom right on a soft shade, and the selection's check mark. A photo that just
// arrived from the phone's backup shows the phone's picture until Immich's thumbnail comes (`standIn`), as Immich may
// not have made it yet. Nothing fades in as it loads.

import SwiftUI

struct GridTile: View {
    let asset: AssetItem?
    let pipeline: ImagePipeline
    let side: CGFloat
    let isSelected: Bool
    let isSelecting: Bool
    /// The aspect ratio grid: the whole photo inside its square, as Photos' View Options offer it.
    var fitsWhole = false
    /// Changes as edits change pictures (MetadataState.imageRevision), so a photo cropped or turned loads again.
    var revision = 0
    /// The phone's photo this one arrived from, whose picture shows until the thumbnail comes.
    var standIn: String? = nil
    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    /// The photo `image` and `placeholder` belong to: a tile given another photo starts empty.
    @State private var shownID: String?

    /// The thumbnail's size: Immich's small one serves the dense levels, its preview the large tiles of a wide grid.
    private var size: ImmichClient.ThumbnailSize { side > 180 ? .preview : .thumbnail }

    /// The photo's thumbnail already in memory, and its ThumbHash already decoded, shown from the tile's first frame
    /// rather than once its loading starts: a tile coming into view, as many do at once when a pinch zooms out, is not
    /// an empty square meanwhile.
    private var thumbnailAtHand: CGImage? {
        guard let asset else { return nil }
        return pipeline.cachedThumbnail(asset.id, size: size)
            ?? (size == .preview ? pipeline.cachedThumbnail(asset.id, size: .thumbnail) : nil)
    }

    private var hashAtHand: CGImage? {
        asset?.thumbhash.flatMap { ThumbHash.cachedImage(base64: $0) }
    }

    /// The setting of the aspect ratio grid, kept on this device for every grid.
    static let aspectRatioKey = "grid.aspectRatio"

    var body: some View {
        let contentMode: ContentMode = fitsWhole ? .fit : .fill
        // What the tile loaded is its photo's only: a tile given another photo (its cell reused for another place in
        // the grid) shows what is already at hand for the new one, never the old one, until it has loaded.
        let isCurrent = shownID == asset?.id
        let loaded = isCurrent ? image : nil
        let thumbnail = loaded ?? thumbnailAtHand
        let hashed = thumbnail == nil ? (isCurrent ? placeholder : nil) ?? hashAtHand : nil
        // A whole photo leaves the rest of its square empty, as in Photos, once it has something to show.
        let showsSquare = !fitsWhole || (thumbnail == nil && hashed == nil)
        Rectangle()
            .fill(showsSquare ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .frame(width: side, height: side)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if let standIn, let picture = PhoneImages.cached(standIn) {
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if let hashed {
                    Image(decorative: hashed, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .overlay(alignment: .bottom) {
                if let asset, side >= 44 { badges(asset) }
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
            .task(id: TaskKey(id: asset?.id, size: size, revision: revision)) { await load() }
    }

    private struct TaskKey: Equatable {
        let id: String?
        let size: ImmichClient.ThumbnailSize
        let revision: Int
    }

    /// A favorite's heart at the foot's left and a video's length at its right, white over a shade that keeps them
    /// readable on snow and sky. A selected tile's check mark takes the corner a video's length would have.
    @ViewBuilder
    private func badges(_ asset: AssetItem) -> some View {
        let showsVideo = asset.isVideo && !(isSelecting && isSelected)
        if asset.isFavorite || showsVideo {
            HStack(spacing: 3) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
                Spacer(minLength: 0)
                if showsVideo {
                    if let duration = asset.durationMS, side >= 64 {
                        Text(Duration.formatMilliseconds(duration))
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
        guard let asset else {
            image = nil
            placeholder = nil
            shownID = nil
            return
        }
        if shownID != asset.id {
            image = nil
            placeholder = nil
            shownID = asset.id
        }
        if let cached = pipeline.cachedThumbnail(asset.id, size: size) {
            image = cached
            placeholder = nil
            return
        }
        // A smaller thumbnail already at hand stands in while the larger one loads.
        if image == nil, size == .preview, let smaller = pipeline.cachedThumbnail(asset.id, size: .thumbnail) {
            image = smaller
        }
        if image == nil, let hash = asset.thumbhash {
            placeholder = ThumbHash.cachedImage(base64: hash)
            if placeholder == nil {
                let decoded = await ThumbHash.placeholder(base64: hash)
                guard !Task.isCancelled else { return }
                placeholder = decoded
            }
        }
        let loaded = await pipeline.gridThumbnail(asset.id, size: size)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
        placeholder = nil
    }
}

/// A photo by its ID alone, filling the frame it is given: an album's cover, a card in Years and Months, the long
/// press's preview. The smaller thumbnail already loaded stands in until the one asked for comes.
struct GridThumbnailImage: View {
    let pipeline: ImagePipeline
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: assetID) { await load() }
    }

    private func load() async {
        guard let assetID else {
            image = nil
            shownID = nil
            return
        }
        if shownID != assetID {
            image = nil
            shownID = assetID
        }
        if let cached = pipeline.cachedThumbnail(assetID, size: size) {
            image = cached
            return
        }
        if image == nil {
            image = pipeline.cachedThumbnail(assetID, size: .thumbnail) ?? pipeline.cachedThumbnail(assetID, size: .preview)
        }
        let loaded = size == .thumbnail
            ? await pipeline.gridThumbnail(assetID, size: size)
            : await pipeline.thumbnail(assetID, size: size)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
    }
}

/// The long press's preview of a photo: the whole photo in its own shape, as Photos lifts it out of the grid.
struct GridTilePreview: View {
    let asset: AssetItem
    let pipeline: ImagePipeline

    var body: some View {
        let ratio = max(0.4, min(2.5, asset.ratio))
        let width = ratio >= 1 ? 340.0 : 340.0 * ratio
        GridThumbnailImage(pipeline: pipeline, assetID: asset.id, size: .preview)
            .frame(width: width, height: width / ratio)
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo, let duration = asset.durationMS {
                    Text(Duration.formatMilliseconds(duration))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .padding(8)
                }
            }
    }
}
