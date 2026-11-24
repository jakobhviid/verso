// What the albums and sharing screens on iOS draw alike: a photo's thumbnail, an account's circle, how far an album or
// a link reaches, and a link's address with Copy.

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VersoCore

/// A photo's thumbnail, square and cropped, for album covers, link rows and the photo picker: from the pipeline's
/// cache at once, or read when it first shows. Nothing fades in as it arrives.
struct AlbumsThumbnail: View {
    let pipeline: ImagePipeline
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    /// Shown when there is no photo to show, such as an empty album's cover.
    var placeholderSystemImage = "photo.on.rectangle"
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if assetID == nil {
                    Image(systemName: placeholderSystemImage)
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let assetID else {
                    image = nil
                    return
                }
                if let cached = pipeline.cachedThumbnail(assetID, size: size) {
                    image = cached
                    return
                }
                image = nil
                let loaded = await pipeline.thumbnail(assetID, size: size)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// An account as a circle (DESIGN.md: an account is a circle, a person in the photos a rounded square): its profile
/// picture, or its initials on the colour Immich gives it.
struct AlbumsMemberAvatar: View {
    let user: User
    let client: ImmichClient
    var size: CGFloat = 28
    @State private var picture: UIImage?

    @MainActor private static let pictures = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(color)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel(Text(user.name))
        .task(id: user.profileImagePath) { await loadPicture() }
    }

    private func loadPicture() async {
        guard let path = user.profileImagePath, !path.isEmpty else {
            picture = nil
            return
        }
        let key = "\(client.serverURL.absoluteString)|\(user.id)|\(path)" as NSString
        if let cached = Self.pictures.object(forKey: key) {
            picture = cached
            return
        }
        guard let request = try? client.request("users/\(user.id)/profile-image"),
              let data = try? await client.data(for: request),
              let image = UIImage(data: data), !Task.isCancelled else { return }
        Self.pictures.setObject(image, forKey: key)
        picture = image
    }

    private var initials: String {
        let words = user.name.split(separator: " ")
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? String(user.email.first ?? "?").uppercased() : String(letters).uppercased()
    }

    private var color: Color {
        switch user.avatarColor {
        case "pink": .pink
        case "red": .red
        case "yellow": .yellow
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "orange": .orange
        case "gray": .gray
        case "amber": Color(red: 1, green: 0.75, blue: 0)
        default: .accentColor
        }
    }
}

/// How far an album or a link reaches, as on the Mac and Linux: the widest of its people and its links that still
/// work. Each reach has one icon, the same on a cover, in a header and in the sharing sheet.
enum AlbumsShareReach: Equatable {
    /// Only its owner.
    case personal
    /// Shared with this many people besides its owner.
    case people(Int)
    /// A working link, each with a password.
    case passwordLink
    /// A working link anyone may open.
    case publicLink

    /// An album's reach: the people it is shared with besides its owner, and its links that still work.
    static func album(people: Int, links: [SharedLink]) -> AlbumsShareReach {
        let working = links.filter { !$0.isExpired }
        if working.contains(where: { !$0.hasPassword }) { return .publicLink }
        if !working.isEmpty { return .passwordLink }
        return people > 0 ? .people(people) : .personal
    }

    /// An album's reach from the account's list, whose members may be left out for an album that is not shared.
    static func album(_ album: Album, links: [SharedLink]) -> AlbumsShareReach {
        let people = album.albumUsers.map { members in members.filter { $0.role != "owner" }.count } ?? (album.shared ? 1 : 0)
        return .album(people: people, links: links)
    }

    /// A link's own reach.
    static func link(_ link: SharedLink) -> AlbumsShareReach { link.hasPassword ? .passwordLink : .publicLink }

    var title: String {
        switch self {
        case .personal: "Private"
        case .people(let count): count == 1 ? "Shared with 1 person" : "Shared with \(count) people"
        case .passwordLink: "Shared with a password"
        case .publicLink: "Shared publicly"
        }
    }

    /// Whether it reaches past the owner, which a cover shows; a private album, the usual case, shows nothing.
    var isShared: Bool { self != .personal }
}

/// A reach's icon: a padlock for private, two people, the globe, and the globe with a padlock for a link with a
/// password.
struct AlbumsShareReachIcon: View {
    let reach: AlbumsShareReach

    var body: some View {
        switch reach {
        case .personal: Image(systemName: "lock")
        case .people: Image(systemName: "person.2")
        case .publicLink: Image(systemName: "globe")
        case .passwordLink:
            Image(systemName: "globe")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .imageScale(.small)
                        .offset(x: 4, y: 3)
                }
        }
    }
}

/// A shared link's address as Immich's web app gives it out, on the server's external domain when it has one: read
/// once per server, so a row can offer Share at once.
@MainActor @Observable
final class SharedLinkAddresses {
    static let shared = SharedLinkAddresses()

    /// Each server's external domain, empty when it has none; absent until read.
    private var externalDomains: [URL: String] = [:]
    @ObservationIgnored private var reading: Set<URL> = []

    func read(_ client: ImmichClient) async {
        let server = client.serverURL
        guard externalDomains[server] == nil, !reading.contains(server) else { return }
        reading.insert(server)
        defer { reading.remove(server) }
        struct Config: Decodable { var externalDomain: String? }
        let config: Config? = try? await client.get("server/config")
        externalDomains[server] = config?.externalDomain ?? ""
    }

    /// The link's address; nil until the server's external domain is read.
    func url(_ link: SharedLink, client: ImmichClient) -> URL? {
        guard let domain = externalDomains[client.serverURL] else { return nil }
        return try? ImmichClient.sharingURL(link, externalDomain: domain, serverURL: client.serverURL)
    }

    /// The link's address, reading the server's external domain first when it has not been.
    func address(_ link: SharedLink, client: ImmichClient) async throws -> URL {
        await read(client)
        if let url = url(link, client: client) { return url }
        return try await client.sharingPublicURL(link)
    }

    /// Puts the address on the clipboard, as a link and as text.
    static func copy(_ url: URL) {
        UIPasteboard.general.setItems([[UTType.url.identifier: url, UTType.utf8PlainText.identifier: url.absoluteString]])
    }
}

extension SharedLink {
    /// Past its last day, so it no longer opens: the shared core tells (`sharedLinkExpired`), as on Linux. The Mac
    /// asks SharingReach's, in Swift (ROADMAP, M9, step 8).
    var isExpired: Bool { sharedLinkExpired(expiresAt: expiresAt.flatMap(ImmichDate.parse)) }
}

/// What a link shows, how long it works and what visitors may do, in words, for its row and its page.
enum SharedLinkWords {
    /// Until when it works, or that it has stopped.
    static func expiry(_ link: SharedLink) -> String {
        if link.isExpired { return "Expired" }
        guard let date = link.expiresAt.flatMap(ImmichDate.parse) else { return "Never expires" }
        return "Works until \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// What visitors may do besides looking, in one line.
    static func visitorsMay(_ link: SharedLink) -> String {
        var abilities: [String] = []
        if link.showMetadata { abilities.append("see each photo's details") }
        if link.allowDownload { abilities.append("download") }
        if link.allowUpload { abilities.append("add photos") }
        guard !abilities.isEmpty else { return "Visitors may only look" }
        return "Visitors may \(abilities.formatted(.list(type: .and)))"
    }

    /// The name of a link without a description: the album's, or what kind of link it is.
    static func title(_ link: SharedLink) -> String {
        if let description = link.description, !description.isEmpty { return description }
        if let album = link.album { return album.albumName }
        return link.hasPassword ? "Link with a password" : "Shared Photos"
    }
}

/// An album's photos' first and last days: the photos' own wall-clock dates, which the server sends at UTC
/// midnight, so they are read in UTC and do not shift.
enum AlbumsDateRange {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    static func text(start: String?, end: String?) -> String? {
        guard let first = start.flatMap(ImmichDate.parse) else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc)
        let firstDay = first.formatted(style)
        guard let last = end.flatMap(ImmichDate.parse) else { return firstDay }
        let lastDay = last.formatted(style)
        return firstDay == lastDay ? firstDay : "\(firstDay) – \(lastDay)"
    }

    static func years(start: String?, end: String?) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let years = [start, end].compactMap { $0.flatMap(ImmichDate.parse) }.map { calendar.component(.year, from: $0) }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(String(first))–\(String(last))"
    }
}
