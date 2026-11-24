import SwiftUI

/// An album as a card at every size, as the iPhone shows it, after Linux's (ARCHITECTURE.md, "Verso on the Mac"): its cover
/// and two more of its photos, on a fade at their foot its name, how many and the years they span, and whom it is
/// shared with (its owner first when it is another's, never yourself; four, then +N); in the corner how far it
/// reaches; its description over the dimmed photos while the pointer is on it.
struct AlbumCard: View {
    @Environment(LibrarySession.self) private var session
    let album: Album
    let links: [SharedLink]

    var body: some View {
        let others = session.services.albumPreviews.photos(of: album) ?? []
        photos(others)
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12))
            .albumDescriptionOnHover(album.description, cornerRadius: 12)
            .overlay(alignment: .topTrailing) { AlbumReachChip(reach: album.reach(links: links), links: links).padding(8) }
            .contentShape(Rectangle())
            .task(id: album.id + (album.lastModifiedAssetTimestamp ?? "")) {
                await session.services.albumPreviews.read(album, client: session.client)
            }
    }

    /// The cover large beside two more, or the cover alone.
    @ViewBuilder private func photos(_ others: [String]) -> some View {
        if others.count >= 2 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId, size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        RemoteThumbnail(pipeline: session.pipeline, assetID: others[0])
                        RemoteThumbnail(pipeline: session.pipeline, assetID: others[1])
                    }
                }
            }
        } else {
            RemoteThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId, size: .preview)
        }
    }

    private var foot: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.albumName).font(.headline).lineLimit(1)
                Text(facts).font(.caption).opacity(0.85).lineLimit(1)
            }
            Spacer(minLength: 0)
            SharedWithAvatars(users: sharedWith)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// How many, and the years they span.
    private var facts: String {
        let count = album.assetCount == 1 ? String(localized: "1 item") : String(localized: "\(album.assetCount) items")
        let years = [album.startDate, album.endDate].compactMap { $0.flatMap(ImmichDate.parse) }
            .map { Calendar.current.component(.year, from: $0) }
        guard let first = years.min(), let last = years.max() else { return count }
        return first == last ? "\(count) · \(String(first))" : "\(count) · \(String(first))–\(String(last))"
    }

    /// Whom it is shared with: its owner first when it is another's, never yourself.
    private var sharedWith: [User] {
        let me = session.user?.id
        let members = album.albumUsers ?? []
        let owner = members.first { $0.role == "owner" }.map(\.user)
        let rest = members.filter { $0.role != "owner" }.map(\.user)
        return ([owner].compactMap { $0 } + rest).filter { $0.id != me }
    }
}

/// Whom something is shared with, as round avatars (an account is a circle; DESIGN.md): four, then +N.
struct SharedWithAvatars: View {
    let users: [User]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -6) {
            ForEach(users.prefix(4)) { user in
                UserAvatar(user: user, size: size)
                    .overlay { Circle().stroke(.white.opacity(0.8), lineWidth: 1) }
                    .help(Text(verbatim: user.name))
            }
            if users.count > 4 {
                Text(verbatim: "+\(users.count - 4)")
                    .font(.caption2.weight(.semibold))
                    .frame(width: size, height: size)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
    }
}

private struct AlbumDescriptionOnHover: ViewModifier {
    let description: String?
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering, let description, !description.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius).fill(.black.opacity(0.58))
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(7)
                            .padding(14)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension View {
    /// An album's description over its dimmed photos while the pointer is on it, never in the way of a click.
    func albumDescriptionOnHover(_ description: String?, cornerRadius: CGFloat) -> some View {
        modifier(AlbumDescriptionOnHover(description: description, cornerRadius: cornerRadius))
    }
}
