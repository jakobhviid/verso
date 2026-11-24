// An album as the card pages draw it, as on the Mac (mac/Verso/Verso/Views/Albums/AlbumCard.swift) and Linux: at the
// smallest card size Photos' cover, a square with the name and the count under it (also Collections' row of albums),
// and from the next size up the card, its cover large beside two more of its photos, on a fade at its foot its name,
// how many and the years they span, and whom it is shared with as faces; in the corner of either how far it reaches.
// The card's other photos come from the shared AlbumPreviews, read as the card first shows.

import SwiftUI

/// An album as Photos shows one: its cover, rounded, with how far it reaches in the corner when it is shared, and
/// under it the title and the count, with the owner's name for an album shared with the account.
struct AlbumCoverCard: View {
    let session: LibrarySession
    let album: Album

    var body: some View {
        let reach = AlbumsShareReach.album(album, links: session.sharing.links.filter { $0.album?.id == album.id })
        VStack(alignment: .leading, spacing: 6) {
            AlbumsThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId, size: .preview,
                            placeholderSystemImage: "rectangle.stack")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) { AlbumReachChip(reach: reach).padding(6) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: album.albumName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let count = album.assetCount.formatted()
        let isOwner = album.albumOwner.map { $0.id == session.user?.id } ?? true
        guard !isOwner, let owner = album.albumOwner?.name else { return count }
        return "\(count) · \(owner)"
    }
}

/// An album as a card, from the second size up: its cover large beside two more of its photos, or the cover alone; on
/// a fade at its foot its name, how many and the years they span, and whom it is shared with (its owner first when it
/// is another's, never yourself; four, then +N); in the corner how far it reaches.
struct AlbumCard: View {
    let session: LibrarySession
    let album: Album

    var body: some View {
        let others = session.services.albumPreviews.photos(of: album) ?? []
        let reach = AlbumsShareReach.album(album, links: session.sharing.links.filter { $0.album?.id == album.id })
        photos(others)
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) { AlbumReachChip(reach: reach).padding(8) }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: album.albumName))
            .accessibilityValue(Text(accessibilityValue(reach)))
            .task(id: album.id + (album.lastModifiedAssetTimestamp ?? "")) {
                await session.services.albumPreviews.read(album, client: session.client)
            }
    }

    /// The cover large beside two more, or the cover alone.
    @ViewBuilder private func photos(_ others: [String]) -> some View {
        if others.count >= 2 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    AlbumsThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId, size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        AlbumsThumbnail(pipeline: session.pipeline, assetID: others[0])
                        AlbumsThumbnail(pipeline: session.pipeline, assetID: others[1])
                    }
                }
            }
        } else {
            AlbumsThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId, size: .preview,
                            placeholderSystemImage: "rectangle.stack")
        }
    }

    private var foot: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: album.albumName)
                    .font(.headline)
                    .lineLimit(1)
                Text(facts)
                    .font(.caption)
                    .opacity(0.85)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            SharedWithFaces(users: sharedWith, client: session.client)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// How many, and the years they span.
    private var facts: String {
        let count = album.assetCount == 1 ? String(localized: "1 item")
            : String(localized: "\(album.assetCount.formatted()) items")
        guard let years = AlbumsDateRange.years(start: album.startDate, end: album.endDate) else { return count }
        return "\(count) · \(years)"
    }

    /// Whom it is shared with: its owner first when it is another's, never yourself.
    private var sharedWith: [User] {
        let me = session.user?.id
        let members = album.albumUsers ?? []
        let owner = members.first { $0.role == "owner" }.map(\.user)
        let rest = members.filter { $0.role != "owner" }.map(\.user)
        return ([owner].compactMap { $0 } + rest).filter { $0.id != me }
    }

    private func accessibilityValue(_ reach: AlbumsShareReach) -> String {
        var parts = [facts]
        if reach.isShared { parts.append(reach.title) }
        if !sharedWith.isEmpty { parts.append(sharedWith.map(\.name).formatted(.list(type: .and))) }
        return parts.joined(separator: ", ")
    }
}

/// Whom an album is shared with, as circles (an account is a circle; DESIGN.md) overlapping on a card's fade: four,
/// then +N.
struct SharedWithFaces: View {
    let users: [User]
    let client: ImmichClient
    var size: CGFloat = 22

    var body: some View {
        if !users.isEmpty {
            HStack(spacing: -6) {
                ForEach(users.prefix(4)) { user in
                    AlbumsMemberAvatar(user: user, client: client, size: size)
                        .overlay { Circle().stroke(.white.opacity(0.8), lineWidth: 1) }
                }
                if users.count > 4 {
                    Text(verbatim: "+\(users.count - 4)")
                        .font(.caption2.weight(.semibold))
                        .frame(width: size, height: size)
                        .background(.black.opacity(0.45), in: .circle)
                }
            }
        }
    }
}

/// How far an album reaches, in a cover's or a card's corner, as its header names it; nothing for a private album,
/// the usual case.
struct AlbumReachChip: View {
    let reach: AlbumsShareReach

    var body: some View {
        if reach.isShared {
            AlbumsShareReachIcon(reach: reach)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: .circle)
                .accessibilityLabel(Text(reach.title))
        }
    }
}
