import SwiftUI
import AppKit

@MainActor enum SharingClipboard {
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

struct SharedLinksView: View {
    @Environment(LibrarySession.self) private var session
    @State private var editing: SharedLink?
    @State private var sharingLink: SharedLink?
    @State private var deleting: SharedLink?
    @State private var showCreate = false
    @State private var albumID = ""
    // Shared links: the Immich web app's tabs, as view options.
    @AppStorage("sharedLinks.filter") private var filter = SharedLinksFilter.all
    @AppStorage("sharedLinks.hideExpired") private var hideExpired = false
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var cardZoom = CardZoom()
    /// The link cards at each size.
    private static let cards = CardLayout(widths: [260, 300, 360, 430, 500])

    /// Whether the view options leave some links out.
    private var isFiltered: Bool { filter != .all || hideExpired }

    var body: some View {
        @Bindable var sharing = session.sharing
        let links = filter.links(sharing.links, hideExpired: hideExpired)
        Group {
            if !sharing.linksAvailable {
                ContentUnavailableView("Shared Links Unavailable", systemImage: "link", description: Text("Shared links are disabled or unavailable on this server."))
            } else if links.isEmpty && !sharing.links.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Links", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No links match the selected view options.")
                } actions: {
                    Button("Show All Links") { filter = .all; hideExpired = false }
                }
            } else if sharing.links.isEmpty {
                ContentUnavailableView("No Shared Links", systemImage: "link",
                                       description: Text("Select photos or choose an album to share with a public link."))
            } else {
                // The links as cards, as Linux shows them (ARCHITECTURE.md, "Verso on the Mac").
                ScrollView {
                    LazyVGrid(columns: Self.cards.columns(cardSize), spacing: 24) {
                        ForEach(links) { link in
                            SharedLinkCard(link: link, edit: { editing = link }, delete: { deleting = link })
                                .contextMenu {
                                    Button("Copy Link") { Task { await copy(link) } }
                                    Button("Share…") { sharingLink = link }
                                    Button("Edit Link…") { editing = link }
                                    Divider()
                                    Button("Delete Link…", role: .destructive) { deleting = link }
                                }
                                .cardZoomItem(link.id)
                        }
                    }
                    .cardGrid(Self.cards)
                    .padding(20)
                }
                .cardZoom($cardSize, cardZoom)
            }
        }
        .navigationTitle("Shared Links")
        .navigationDestination(for: SharedLinkDestination.self) { destination in
            switch destination {
            case .album(let id): AlbumDetailView(id: id)
            case .link(let id): SharedLinkDetailView(id: id)
            }
        }
        .cardSizeCommands($cardSize, zoom: cardZoom)
        .pageToolbar("sharedLinks") {
            CardSizeToolbarItems(size: $cardSize, zoom: cardZoom)
            ToolbarItem(id: "viewOptions") { viewOptions.disabled(!sharing.linksAvailable) }
            ToolbarItem(id: "shareAlbum") {
                Menu("Share Album", systemImage: "link.badge.plus") {
                    ForEach(session.albums) { album in
                        Button(album.albumName) { albumID = album.id; showCreate = true }
                    }
                }
                .menuIndicator(.hidden)
                .disabled(!sharing.linksAvailable || session.albums.isEmpty)
            }
            ToolbarItem(id: "refresh") { Button("Refresh", systemImage: "arrow.clockwise") { Task { await sharing.reload() } } }
        }
        .sheet(item: $sharingLink) { SharedLinkURLSheet(link: $0) }
        .sheet(item: $editing) { SharedLinkEditor(link: $0) }
        .sheet(isPresented: $showCreate) { SharedLinkEditor(albumID: albumID) }
        .confirmationDialog("Delete public link?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) {
                if let link = deleting { Task { await sharing.perform { try await session.client.deleteSharedLink(link.id) } } }
            }
        } message: { Text("Anyone with this link will lose access. The photos remain in your library.") }
        .sharingError()
        .task { await sharing.reload() }
    }

    private var viewOptions: some View {
        Menu {
            Picker("Show", selection: $filter.animation(.smooth(duration: 0.35))) {
                ForEach(SharedLinksFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Hide Expired Links", isOn: $hideExpired.animation(.smooth(duration: 0.35)))
        } label: {
            Label("View Options", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }

    private func copy(_ link: SharedLink) async {
        do { SharingClipboard.copy(try await session.client.sharingPublicURL(link)) }
        catch { session.sharing.error = error.localizedDescription }
    }
}

private struct SharingErrorModifier: ViewModifier {
    @Environment(LibrarySession.self) private var session
    func body(content: Content) -> some View {
        content.alert("Sharing Failed", isPresented: Binding(get: { session.sharing.error != nil }, set: { if !$0 { session.sharing.error = nil } })) {
            Button("OK") { session.sharing.error = nil }
        } message: { Text(session.sharing.error ?? "") }
    }
}
extension View {
    func sharingError() -> some View { modifier(SharingErrorModifier()) }
}

private struct SharedLinkURLSheet: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let link: SharedLink
    @State private var url: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(link.title).font(.title2.bold())
            if let url {
                Text(url.absoluteString).textSelection(.enabled)
                HStack {
                    Button("Copy Link") { SharingClipboard.copy(url) }
                    ShareLink(item: url)
                }
            } else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView("Loading Public URL…") }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 440)
        .task {
            do { url = try await session.client.sharingPublicURL(link) }
            catch { self.error = error.localizedDescription }
        }
    }
}
