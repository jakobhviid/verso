// The picker's grids (MessagesPicker): photos as square tiles edge to edge, four across on an iPhone and more on a
// wider screen, read a page more as the person scrolls to the end; and albums as Photos shows them, a square cover
// above the name and the count. A tile's thumbnail is decoded at the tile's size only while it shows, its ThumbHash
// standing in until then; a tile being fetched to send dims under a spinner, and the one in the message field keeps a
// check mark.

import SwiftUI

struct PhotoGrid: View {
    let feed: PhotoFeed
    let model: PickerModel
    let thumbnails: PickerThumbnails
    let emptyText: LocalizedStringResource
    @Environment(\.displayScale) private var displayScale

    private static let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let columns = max(4, Int(geometry.size.width / 110))
            let side = ((geometry.size.width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            ScrollView {
                LazyVStack(spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Self.spacing), count: columns),
                              spacing: Self.spacing) {
                        ForEach(feed.photos) { photo in
                            PhotoTile(photo: photo, side: side, pixels: Int(side * displayScale),
                                      thumbnails: thumbnails, model: model)
                        }
                    }
                    footer
                        .task(id: feed.photos.count) { await feed.loadMore() }
                }
            }
        }
        .overlay {
            if feed.photos.isEmpty, feed.reachedEnd, feed.problem == nil {
                ContentUnavailableView(String(localized: emptyText), systemImage: "photo.on.rectangle")
            }
        }
    }

    /// Beneath the photos: a spinner while a page is read, or why it could not be, with Try Again.
    private var footer: some View {
        VStack(spacing: 8) {
            if feed.isLoading {
                ProgressView()
            } else if let problem = feed.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await feed.loadMore() } }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}

/// One photo: a tap puts a preview-sized copy into the message field, or the original with Original on.
private struct PhotoTile: View {
    let photo: PickerPhoto
    let side: CGFloat
    let pixels: Int
    let thumbnails: PickerThumbnails
    let model: PickerModel
    @State private var image: UIImage?
    @State private var placeholder: CGImage?

    var body: some View {
        Button { send(original: model.sendsOriginals) } label: {
            Rectangle()
                .fill(.quaternary)
                .frame(width: side, height: side)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if let placeholder {
                        Image(decorative: placeholder, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .overlay {
                    if model.sending.contains(photo.id) {
                        Color.black.opacity(0.35)
                        ProgressView()
                            .tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.inField == photo.id {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo"))
        .accessibilityIdentifier("picker.photo")
        .task(id: photo.id) { await load() }
    }

    private func send(original: Bool) {
        model.send(photo, original: original)
    }

    private func load() async {
        if let cached = thumbnails.cached(photo.id, pixels: pixels) {
            image = cached
            return
        }
        if placeholder == nil, let hash = photo.thumbhash {
            placeholder = ThumbHash.cachedImage(base64: hash)
            if placeholder == nil {
                let decoded = await ThumbHash.placeholder(base64: hash)
                guard !Task.isCancelled else { return }
                placeholder = decoded
            }
        }
        let loaded = await thumbnails.thumbnail(photo.id, pixels: pixels)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
        placeholder = nil
    }
}

/// The albums, two or more across, each opening its photos.
struct AlbumsGrid: View {
    let library: PickerLibrary
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let margin: CGFloat = 16
            let gap: CGFloat = 12
            let columns = max(2, Int((geometry.size.width - margin * 2) / 170))
            let side = ((geometry.size.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap, alignment: .top), count: columns),
                          spacing: 16) {
                    ForEach(library.albums ?? []) { album in
                        NavigationLink(value: album) {
                            AlbumCover(album: album, side: side, pixels: Int(side * displayScale),
                                       thumbnails: library.thumbnails)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("picker.album")
                    }
                }
                .padding(margin)
            }
        }
        .overlay {
            if let problem = library.albumsProblem {
                ContentUnavailableView {
                    Label("Can't Show the Albums", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                }
            } else if library.albums?.isEmpty == true {
                ContentUnavailableView("No Albums", systemImage: "rectangle.stack")
            } else if library.albums == nil {
                ProgressView()
            }
        }
        .task { await library.loadAlbums() }
    }
}

/// An album as Photos shows one: its cover, rounded, above its name and how many photos and videos it holds.
private struct AlbumCover: View {
    let album: Album
    let side: CGFloat
    let pixels: Int
    let thumbnails: PickerThumbnails
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: side, height: side)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 4)
            Text(album.albumName)
                .font(.subheadline)
                .lineLimit(1)
            Text(album.assetCount, format: .number)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: album.albumThumbnailAssetId) {
            guard let cover = album.albumThumbnailAssetId else { return }
            if let cached = thumbnails.cached(cover, pixels: pixels) {
                image = cached
                return
            }
            image = await thumbnails.thumbnail(cover, pixels: pixels)
        }
    }
}
