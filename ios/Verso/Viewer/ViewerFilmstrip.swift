// The viewer's filmstrip on iOS, as Photos has it above the bottom bar: the photos beside the shown one as narrow
// thumbnails, the shown one wider in its own shape, the strip following the paging, and a tap on a photo going
// straight to it. It holds the photos the grid's model has loaded (ViewerState.photos), which the pager loads ahead,
// and takes a photo's thumbnail again once an edit has changed its picture.

import SwiftUI

struct ViewerFilmstrip: View {
    let state: ViewerState
    /// The photo the strip's photos are taken around, moved on only as the shown one nears an end of them, so the
    /// strip keeps its photos while it follows the paging.
    @State private var anchorID: String?
    /// The photo in the strip's middle.
    @State private var position: String?

    /// Photos on each side of the anchor.
    private static let radius = 60
    /// How near an end of the strip's photos the shown one may come before they are taken around it again.
    private static let margin = 15
    static let height: CGFloat = 30

    var body: some View {
        let photos = state.photos(around: anchorID ?? state.currentID, radius: Self.radius)
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 2) {
                    ForEach(photos) { item in
                        let current = item.id == state.currentID
                        Button { state.jump(to: item) } label: {
                            ViewerFilmstripTile(item: item, pipeline: state.session.pipeline, current: current,
                                                imageRevision: state.session.metadata.imageRevision)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, current ? 6 : 0)
                        .accessibilityLabel(Text(item.date.map { ImmichDate.long($0) } ?? String(localized: "Photo")))
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .center)
            // Room for the first and last photos to come to the middle.
            .contentMargins(.horizontal, proxy.size.width / 2, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .frame(height: Self.height)
        .onAppear {
            anchorID = state.currentID
            position = state.currentID
        }
        .onChange(of: state.currentID) { _, id in follow(id) }
    }

    /// The strip comes along to the photo shown, taking its photos around it again near their ends.
    private func follow(_ id: String) {
        let photos = state.photos(around: anchorID ?? id, radius: Self.radius)
        let index = photos.firstIndex { $0.id == id }
        if index.map({ $0 < Self.margin || $0 >= photos.count - Self.margin }) ?? true { anchorID = id }
        withAnimation(.easeOut(duration: 0.25)) { position = id }
    }
}

/// A photo in the filmstrip: narrow and cropped, or, for the one shown, in its own shape within limits.
private struct ViewerFilmstripTile: View {
    let item: AssetItem
    let pipeline: ImagePipeline
    let current: Bool
    /// Changes as edits change pictures, which evicts theirs from the pipeline.
    let imageRevision: Int
    @State private var image: CGImage?

    var body: some View {
        let height = ViewerFilmstrip.height
        let width = current ? min(max(CGFloat(item.ratio) * height, 22), height * 1.8) : 20
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 2))
            .contentShape(.rect)
            .animation(.easeInOut(duration: 0.2), value: current)
            .task(id: "\(item.id)|\(imageRevision)") { await load() }
    }

    /// The grid's thumbnail, at once when the grid showed it; until it comes, its ThumbHash, or the picture before
    /// an edit.
    private func load() async {
        if let cached = pipeline.cachedThumbnail(item.id, size: .thumbnail) {
            image = cached
            return
        }
        if image == nil, let hash = item.thumbhash, let placeholder = ThumbHash.cachedImage(base64: hash) {
            image = placeholder
        }
        if let thumbnail = await pipeline.gridThumbnail(item.id, size: .thumbnail) { image = thumbnail }
    }
}
