import SwiftUI

/// A shared link as a card, as Linux shows it (ARCHITECTURE.md, "Verso on the Mac"): some of what it shares (an
/// album's cover and two more of its photos, or the link's chosen photos), which open the album or the link's page;
/// on them what it is and who may see it; in the corners until when it works (Expired in red), what visitors may do
/// and how far it reaches; along the foot Copy Link, Open Link, Edit and Delete.
struct SharedLinkCard: View {
    @Environment(LibrarySession.self) private var session
    let link: SharedLink
    let edit: () -> Void
    let delete: () -> Void

    /// The album as the account's list has it, with its count and changes; the link's own copy has neither.
    private var album: Album? {
        guard let id = link.album?.id else { return nil }
        return session.albums.first { $0.id == id } ?? link.album
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: destination) {
                photos
                    .aspectRatio(1.3, contentMode: .fit)
                    .overlay(alignment: .bottom) { foot }
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(alignment: .topLeading) { expiry.padding(8) }
                    .overlay(alignment: .topTrailing) { corner.padding(8) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(link.type == "ALBUM" ? "Open the album" : "Open the link's photos")
            HStack(spacing: 4) {
                Button { Task { await copy() } } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                Button { Task { await open() } } label: { Label("Open Link", systemImage: "safari") }
                    .help("Open the link's web page")
                Spacer(minLength: 0)
                Button(action: edit) { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.large)
        }
        .task(id: link.id) {
            if let album { await session.services.albumPreviews.read(album, client: session.client) }
            await session.services.linkPreviews.read(link, client: session.client)
        }
    }

    private var destination: SharedLinkDestination {
        if let id = link.album?.id { .album(id) } else { .link(link.id) }
    }

    /// One across, or one large beside two small.
    @ViewBuilder private var photos: some View {
        let ids = photoIDs
        if ids.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: ids[0], size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        RemoteThumbnail(pipeline: session.pipeline, assetID: ids[1])
                        RemoteThumbnail(pipeline: session.pipeline, assetID: ids[2])
                    }
                }
            }
        } else {
            RemoteThumbnail(pipeline: session.pipeline, assetID: ids.first, size: .preview)
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
            Text(link.title).font(.headline).lineLimit(1)
            Text(what).font(.caption).opacity(0.9).lineLimit(1)
            Text(link.hasPassword ? String(localized: "Anyone with the link and its password") : String(localized: "Anyone with the link"))
                .font(.caption).opacity(0.8).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// An album and its count, or how many photos.
    private var what: String {
        if let album {
            let count = album.assetCount == 1 ? String(localized: "1 item") : String(localized: "\(album.assetCount) items")
            return String(localized: "Album · \(count)")
        }
        guard let count = session.services.linkPreviews.count(of: link) else { return String(localized: "Chosen photos") }
        return count == 1 ? String(localized: "1 photo") : String(localized: "\(count) photos")
    }

    @ViewBuilder private var expiry: some View {
        if link.isExpired {
            chip(Text("Expired").foregroundStyle(.white), background: .red)
        } else if let date = link.expiresAt.flatMap(ImmichDate.parse) {
            chip(Text("Until \(date.formatted(.dateTime.day().month(.abbreviated)))").foregroundStyle(.white), background: .black.opacity(0.45))
        }
    }

    /// What visitors may do, and how far it reaches.
    private var corner: some View {
        HStack(spacing: 4) {
            if link.allowDownload {
                chip(Image(systemName: "arrow.down.circle").foregroundStyle(.white), background: .black.opacity(0.45))
                    .help("Visitors may download")
            }
            if link.allowUpload {
                chip(Image(systemName: "arrow.up.circle").foregroundStyle(.white), background: .black.opacity(0.45))
                    .help("Visitors may add photos")
            }
            chip(SharingReachIcon(reach: .link(link)).foregroundStyle(.white), background: .black.opacity(0.45))
                .help(SharingReach.link(link).title)
        }
    }

    private func chip(_ content: some View, background: some ShapeStyle) -> some View {
        content
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private func copy() async {
        do { SharingClipboard.copy(try await session.client.sharingPublicURL(link)) }
        catch { session.sharing.error = error.localizedDescription }
    }

    private func open() async {
        do { NSWorkspace.shared.open(try await session.client.sharingPublicURL(link)) }
        catch { session.sharing.error = error.localizedDescription }
    }
}

/// Where a link's card opens: its album, or the link's own page.
enum SharedLinkDestination: Hashable {
    case album(String)
    case link(String)
}
