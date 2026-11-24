// Verso's own actions in the share sheet (ShareSheet.swift), for Immich's photos, as the Mac's Create Public Link… and
// Add to Public Link… (mac/Verso/Verso/Views/Sharing/SharingActions.swift):
// - Create Link…: the link form for the photos (SharedLinkForm): a description, a password, until when it works, what
//   visitors may do; once made, its address in a share sheet to send or copy.
// - Add to Link…: the account's links to chosen photos (not an album's links, which share their album), one picked,
//   the photos added to it, then its address in a share sheet to send or copy.
// Each is a screen the system presents once it is chosen; it tells the system when it is done, which closes it.
// Nothing of the photos downloads for a link.

import SwiftUI
import UIKit

/// Create Link… or Add to Link…, in the share sheet's actions. UIKit asks for it on the main thread, where its screen
/// is made.
final class ShareLinkActivity: UIActivity, @unchecked Sendable {
    enum Kind {
        case create
        case add
    }

    private let kind: Kind
    private let session: LibrarySession
    private let assetIDs: [String]
    /// The screen, made once it is asked for.
    private var screen: UIViewController?

    init(_ kind: Kind, session: LibrarySession, assetIDs: [String]) {
        self.kind = kind
        self.session = session
        self.assetIDs = assetIDs
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType(Self.typePrefix + (kind == .create ? "createLink" : "addToLink"))
    }

    private static let typePrefix = "dev.hviid.Verso."

    /// Whether the sheet's choice is one of Verso's link actions, which take no photo from the sheet.
    static func isOwn(_ type: UIActivity.ActivityType?) -> Bool {
        type?.rawValue.hasPrefix(typePrefix) == true
    }

    override var activityTitle: String? {
        kind == .create ? String(localized: "Create Link…") : String(localized: "Add to Link…")
    }

    override var activityImage: UIImage? {
        UIImage(systemName: kind == .create ? "link.badge.plus" : "link")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override var activityViewController: UIViewController? {
        MainActor.assumeIsolated { madeScreen() }
    }

    @MainActor private func madeScreen() -> UIViewController {
        if let screen { return screen }
        let finish: (Bool) -> Void = { [weak self] done in self?.activityDidFinish(done) }
        let content = switch kind {
        case .create: AnyView(SharedLinkForm(session: session, assetIDs: assetIDs, finish: finish))
        case .add: AnyView(AddToSharedLinkView(session: session, assetIDs: assetIDs, finish: finish))
        }
        let host = UIHostingController(rootView: content)
        screen = host
        return host
    }
}

/// Add to Link…: the account's links to chosen photos, newest first, as Immich lists them; a tap adds the photos to
/// one, and its address follows, in a share sheet at once and here, to copy or share.
private struct AddToSharedLinkView: View {
    let session: LibrarySession
    let assetIDs: [String]
    /// Told when it is done, with whether the photos were added, as the share sheet closes it.
    let finish: (Bool) -> Void
    /// The link the photos are going into.
    @State private var adding: String?
    @State private var loaded = false
    /// The link the photos went into, and its address.
    @State private var added: (link: SharedLink, address: URL)?
    @State private var sharedAddress: SharedLinkAddress?
    @State private var copied = false
    @State private var error: String?

    private var links: [SharedLink] { session.sharing.links.filter { $0.type == "INDIVIDUAL" } }

    var body: some View {
        NavigationStack {
            List {
                if let added {
                    SharedLinkAddressSection(address: added.address, title: "Added to Link",
                                             footer: footer(added.link), copied: $copied)
                } else {
                    Section {
                        ForEach(links) { link in row(link) }
                    } footer: {
                        if links.isEmpty {
                            EmptyView()
                        } else if assetIDs.count == 1 {
                            Text("The photo is added to the link you choose.")
                        } else {
                            Text("The photos are added to the link you choose.")
                        }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Add to Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert("Couldn't Add to the Link", isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .sensoryFeedback(.success, trigger: copied)
            // Sent or copied, Add to Link… is done; closed, the address shows here still.
            .shareSheet(address: $sharedAddress) { completed in if completed { finish(true) } }
        }
        // It closes only through Cancel or Done, which tell the share sheet.
        .interactiveDismissDisabled()
        .task {
            await session.sharing.reload()
            await SharedLinkAddresses.shared.read(session.client)
            loaded = true
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if added != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { finish(true) }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { finish(false) }
                    .disabled(adding != nil)
            }
        }
    }

    private func row(_ link: SharedLink) -> some View {
        Button {
            Task { await add(to: link) }
        } label: {
            HStack(spacing: 12) {
                AlbumsThumbnail(pipeline: session.pipeline, assetID: link.assets.first?.id,
                                placeholderSystemImage: "link")
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(SharedLinkWords.title(link))
                        .foregroundStyle(Color.primary)
                    Text(SharedLinkWords.expiry(link))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                if adding == link.id {
                    ProgressView()
                } else {
                    AlbumsShareReachIcon(reach: .link(link))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .disabled(adding != nil)
    }

    /// Who can open the link the photos went into.
    private func footer(_ link: SharedLink) -> String {
        link.hasPassword ? String(localized: "Anyone with the link and its password can see these photos.")
            : String(localized: "Anyone with the link can see these photos.")
    }

    @ViewBuilder private var emptyState: some View {
        if added == nil, loaded, links.isEmpty {
            ContentUnavailableView {
                Label("No Links", systemImage: "link")
            } description: {
                Text("Links to chosen photos show here. Make one with Create Link… in the share sheet.")
            }
        } else if added == nil, !loaded, links.isEmpty {
            ProgressView()
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    /// Adds the photos, as the link's own page adds them, then shares the link's address.
    private func add(to link: SharedLink) async {
        adding = link.id
        defer { adding = nil }
        do {
            try await session.client.changeSharedLinkAssets(link.id, assetIDs: assetIDs, adding: true)
            // The link's card and page read it again when next shown.
            session.services.linkPreviews.forget(link.id)
            session.gridModel(for: .sharedLink(link.id)).markStale()
            await session.sharing.reload()
            let address = try await SharedLinkAddresses.shared.address(link, client: session.client)
            added = (link, address)
            sharedAddress = SharedLinkAddress(url: address)
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}
