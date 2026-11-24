// A photo filling a tile, for the cards and pins of People, Places and Memories: the shared ImagePipeline's
// thumbnail, cropped to the tile, over its ThumbHash until it comes and over an empty tile before either. Nothing fades
// in as it loads, as the grid's tiles.

import SwiftUI

struct ExploreThumbnail: View {
    let pipeline: ImagePipeline
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    /// The photo's ThumbHash, shown until the thumbnail comes, where the caller has it.
    var thumbhash: String? = nil
    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    /// The photo `image` belongs to: a tile given another photo starts empty.
    @State private var shownID: String?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if let placeholder {
                    Image(decorative: placeholder, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if assetID == nil {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: assetID) { await load() }
    }

    private func load() async {
        if shownID != assetID {
            image = nil
            placeholder = nil
            shownID = assetID
        }
        guard let assetID else { return }
        if let cached = pipeline.cachedThumbnail(assetID, size: size) {
            image = cached
            return
        }
        if size == .preview, let smaller = pipeline.cachedThumbnail(assetID, size: .thumbnail) {
            image = smaller
        } else if let thumbhash {
            placeholder = ThumbHash.cachedImage(base64: thumbhash)
            if placeholder == nil {
                let decoded = await ThumbHash.placeholder(base64: thumbhash)
                guard !Task.isCancelled else { return }
                placeholder = decoded
            }
        }
        let loaded = await pipeline.gridThumbnail(assetID, size: size)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
        placeholder = nil
    }
}
