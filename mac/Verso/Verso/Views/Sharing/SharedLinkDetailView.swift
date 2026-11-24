import SwiftUI

/// A link to chosen photos, as an album's page is, as on Linux (ARCHITECTURE.md, "Verso on the Mac"): its photos in
/// the grid, newest first, to look at, select and take out of it (Remove from Link; ⌫ takes them out, as in an
/// album, and never deletes them, as they are the library's). Above them its title, what it is (until when, what
/// visitors may do), how far it reaches, and its actions where the eye already is for the link: using it (Copy Link,
/// Open Link) apart from changing it (Add Photos, Edit). Delete Link is in the Link menu, and closes the page.
struct SharedLinkDetailView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: String
    @State private var link: SharedLink?
    @State private var error: String?
    @State private var editing = false
    @State private var adding = false
    @State private var deleting = false
    @State private var deleted = false

    private var model: AssetGridModel { session.gridModel(for: .sharedLink(id)) }

    var body: some View {
        Group {
            if deleted {
                ContentUnavailableView("Link Deleted", systemImage: "link")
            } else if let link {
                AssetGridContainer(source: .sharedLink(id), title: Text(verbatim: link.title), headerScrolls: true) {
                    header(link)
                }
                .environment(\.gridEmptyAddPhotos, GridAddPhotos(id: id) { adding = true })
                .environment(\.gridPageControls, GridPageControls(key: link.id, view: AnyView(linkMenu(link))))
            } else if let error {
                ContentUnavailableView { Label("Couldn't Load Link", systemImage: "link") }
                description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
                .pageToolbar("sharedLinkError")
            } else {
                ProgressView().pageToolbar("sharedLinkLoading")
            }
        }
        .task(id: id) { await load() }
        // A photo taken out in the grid (Remove from Link, ⌫): the header's count and the picker's photos follow.
        .onChange(of: model.totalCount) { Task { await load() } }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let link { SharedLinkEditor(link: link) }
        }
        .sheet(isPresented: $adding) {
            PhotoPicker(title: String(localized: "Add Photos to “\(link?.title ?? "")”"), present: Set(link?.assets.map(\.id) ?? [])) { ids in
                try await session.client.changeSharedLinkAssets(id, assetIDs: ids, adding: true)
                session.services.linkPreviews.forget(id)
                await load()
                await model.reload()
                await session.sharing.reload()
            }
        }
        .confirmationDialog("Delete Link?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) { deleteLink() }
        } message: { Text("Anyone with the link loses access to its photos. They stay in your library.") }
        .alert("Link Error", isPresented: Binding(get: { link != nil && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func header(_ link: SharedLink) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(link.title).font(.largeTitle.bold()).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(link.assets.count == 1 ? String(localized: "1 photo") : String(localized: "\(link.assets.count) photos"))
                    Text(verbatim: "·")
                    if link.isExpired {
                        Text("Expired").foregroundStyle(.red)
                    } else if let date = link.expiresAt.flatMap(ImmichDate.parse) {
                        Text("Works until \(date.formatted(date: .long, time: .omitted))")
                    } else {
                        Text("Never expires")
                    }
                }
                Text(visitorsMay(link))
                // A row of the link's status and actions under its details, as an album's (DESIGN.md, "The apps'
                // interfaces"): how far it reaches, named, opens its settings; then using it, apart from changing it.
                HStack(spacing: 4) {
                    Button { editing = true } label: { SharingReachLabel(reach: .link(link)) }
                        .help("Edit Link…")
                    Divider().frame(height: 18).padding(.horizontal, 8)
                    Button { Task { await copy(link) } } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                    Button { Task { await open(link) } } label: { Label("Open Link", systemImage: "safari") }
                        .help("Open the link's web page")
                    Divider().frame(height: 18).padding(.horizontal, 8)
                    Button { adding = true } label: { Label("Add Photos", systemImage: "photo.badge.plus") }
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                }
                .buttonStyle(.headerStatus)
                .padding(.leading, -8)
                .padding(.top, 4)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    /// What matters less on this page, in the top bar's Link menu (DESIGN.md, "The toolbar's places").
    private func linkMenu(_ link: SharedLink) -> some View {
        Menu {
            Button("Delete Link…", role: .destructive) { deleting = true }
        } label: { Label("Link", systemImage: "link") }
        .menuIndicator(.hidden)
        .help("Link")
    }

    /// What visitors may do besides looking, in one line.
    private func visitorsMay(_ link: SharedLink) -> String {
        var abilities: [String] = []
        if link.showMetadata { abilities.append(String(localized: "see each photo's details")) }
        if link.allowDownload { abilities.append(String(localized: "download")) }
        if link.allowUpload { abilities.append(String(localized: "add photos")) }
        guard !abilities.isEmpty else { return String(localized: "Visitors may only look") }
        return String(localized: "Visitors may \(abilities.formatted(.list(type: .and)))")
    }

    private func load() async {
        do {
            link = try await session.client.sharedLink(id)
            error = nil
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func copy(_ link: SharedLink) async {
        do { SharingClipboard.copy(try await session.client.sharingPublicURL(link)) }
        catch { self.error = error.localizedDescription }
    }

    private func open(_ link: SharedLink) async {
        do { openURL(try await session.client.sharingPublicURL(link)) }
        catch { self.error = error.localizedDescription }
    }

    private func deleteLink() {
        Task {
            do {
                try await session.client.deleteSharedLink(id)
                deleted = true
                await session.sharing.reload()
                dismiss()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}
