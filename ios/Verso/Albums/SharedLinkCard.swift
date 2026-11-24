// A shared link as a card on the Shared Links page, as the Mac draws it (mac/Verso/Verso/Views/Sharing/SharedLinkCard.swift)
// and Linux: some of what it shares (an album's cover beside two more of its photos, or the link's chosen photos), on a
// fade at its foot what it is called, what it shares and who may see it; in its corners until when it works (Expired in
// red), what visitors may do and how far it reaches; and in the fade's corner Share, the one action at hand, as the
// Mac's row of buttons under a card suits a pointer, not a finger. A tap opens the album or the link's page; Copy Link,
// Share Link, Edit and Delete are its long press (SharedLinksView). The card's other photos come from the shared
// previews, read as it first shows.

import SwiftUI

struct SharedLinkCard: View {
    let session: LibrarySession
    let link: SharedLink
    let open: () -> Void

    /// The album as the account's list has it, with its count and changes; the link's own copy has neither.
    private var album: Album? {
        guard let id = link.album?.id else { return nil }
        return session.albums.first { $0.id == id } ?? link.album
    }

    var body: some View {
        photos
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) { expiry.padding(8) }
            .overlay(alignment: .topTrailing) { corner.padding(8) }
            // One element for VoiceOver, then opened by a tap, so the element is the button that opens it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(SharedLinkWords.title(link)))
            .accessibilityValue(Text(accessibilityValue))
            .cardOpens(open)
            // Over the card, so its tap is its own and VoiceOver finds it beside the card.
            .overlay(alignment: .bottomTrailing) { share.padding(6) }
            .task(id: link.id) {
                if let album { await session.services.albumPreviews.read(album, client: session.client) }
                await session.services.linkPreviews.read(link, client: session.client)
            }
    }

    /// One across, or one large beside two small.
    @ViewBuilder private var photos: some View {
        let ids = photoIDs
        if ids.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    AlbumsThumbnail(pipeline: session.pipeline, assetID: ids[0], size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        AlbumsThumbnail(pipeline: session.pipeline, assetID: ids[1])
                        AlbumsThumbnail(pipeline: session.pipeline, assetID: ids[2])
                    }
                }
            }
        } else {
            AlbumsThumbnail(pipeline: session.pipeline, assetID: ids.first, size: .preview,
                            placeholderSystemImage: album == nil ? "photo.on.rectangle" : "rectangle.stack")
        }
    }

    private var photoIDs: [String] {
        if let album {
            return [album.albumThumbnailAssetId].compactMap { $0 } + (session.services.albumPreviews.photos(of: album) ?? [])
        }
        return session.services.linkPreviews.photos(of: link) ?? link.assets.prefix(1).map(\.id)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SharedLinkWords.title(link))
                .font(.headline)
            Text(what)
                .font(.caption)
                .opacity(0.9)
            Text(whoMaySee)
                .font(.caption)
                .opacity(0.8)
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.leading, 12)
        // Room for Share in the corner.
        .padding(.trailing, 52)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// An album and its count, or how many photos.
    private var what: String {
        if let album {
            let count = album.assetCount == 1 ? String(localized: "1 item")
                : String(localized: "\(album.assetCount.formatted()) items")
            return String(localized: "Album · \(count)")
        }
        guard let count = session.services.linkPreviews.count(of: link) else { return String(localized: "Chosen photos") }
        return count == 1 ? String(localized: "1 photo") : String(localized: "\(count.formatted()) photos")
    }

    private var whoMaySee: String {
        link.hasPassword ? String(localized: "Anyone with the link and its password")
            : String(localized: "Anyone with the link")
    }

    /// Until when it works, or Expired in red; nothing for a link that never expires.
    @ViewBuilder private var expiry: some View {
        if link.isExpired {
            chip(Text("Expired"), background: .red)
        } else if let date = link.expiresAt.flatMap(ImmichDate.parse) {
            chip(Text("Until \(date.formatted(.dateTime.day().month(.abbreviated)))"), background: .black.opacity(0.45))
        }
    }

    /// What visitors may do besides looking, and how far it reaches.
    private var corner: some View {
        HStack(spacing: 4) {
            if link.allowDownload {
                chip(Image(systemName: "arrow.down.circle"), background: .black.opacity(0.45))
            }
            if link.allowUpload {
                chip(Image(systemName: "arrow.up.circle"), background: .black.opacity(0.45))
            }
            chip(AlbumsShareReachIcon(reach: .link(link)), background: .black.opacity(0.45))
        }
        .accessibilityHidden(true)
    }

    private func chip(_ content: some View, background: some ShapeStyle) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background, in: .capsule)
    }

    /// Share Link, the system's share sheet with the link's address (Copy is in it), in a glass circle a finger's size.
    @ViewBuilder private var share: some View {
        if let address = SharedLinkAddresses.shared.url(link, client: session.client) {
            ShareLink(item: address) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .accessibilityLabel(Text("Share Link"))
        }
    }

    private var accessibilityValue: String {
        [what, SharedLinkWords.expiry(link), SharedLinkWords.visitorsMay(link), SharingReach.link(link).title]
            .joined(separator: ", ")
    }
}
