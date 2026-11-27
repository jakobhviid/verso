import DeviceDiscoveryUI
import Network
import SwiftUI
import UIKit

// Manage Photos on the Apple TV (ROADMAP.md, "Verso on the Apple TV"), off until Settings turns it on through the
// iPhone: a press and hold on a photo, in a grid or the viewer, opens its menu in the iPhone's order (PhotoActionsMenu):
// Favorite, Add to Album (the albums as Albums orders them, TVAlbumPicker), Archive (Move to Library in the Archive),
// Move to Locked Folder, and Delete at the foot; in the Locked
// Folder, Move Out of the Locked Folder and Delete. Moving to the Locked Folder and deleting ask first. The actions go
// through the TV's second key, which may change and delete photos alone, and in the Locked Folder through its session,
// which the iPhone unlocked; without Manage Photos there is no menu.

/// What a photo's menu does.
enum TVPhotoAction: Hashable {
    case favorite(Bool)
    case addToAlbum(String)
    case archive, unarchive, lock, unlock, delete

    /// Asked first: what takes the photo out of the TV's reach, or towards being gone.
    var asks: Bool { self == .lock || self == .delete }

    var addsToAlbum: Bool {
        if case .addToAlbum = self { true } else { false }
    }
}

/// What a page, and the viewer over it, do once a photo's menu changed it.
enum TVPhotoChange {
    case favorite(String, Bool)
    case removed(String)

    var id: String {
        switch self {
        case .favorite(let id, _), .removed(let id): id
        }
    }
}

/// Where the photos of a page are, which decides their menu.
enum TVPhotoPlace {
    case library, archive, lockedFolder
}

/// A page's photos, which a photo's menu tells of its change: a timeline or a list of results.
@MainActor
protocol TVPhotoPage: AnyObject {
    func apply(_ change: TVPhotoChange)
}

extension EnvironmentValues {
    @Entry var tvPhotoPlace = TVPhotoPlace.library
    /// The page whose photos a menu changes.
    @Entry var tvPhotoPage: (any TVPhotoPage)?
}

/// The change requests, through the second key, or the Locked Folder's session there.
@MainActor
enum TVPhotoActions {
    private struct Update: Encodable {
        let ids: [String]
        var isFavorite: Bool?
        var visibility: String?
    }

    private struct Removal: Encodable {
        let ids: [String]
        let force = false
    }

    /// The change a page and the viewer take, or nil where the photo stays as it was (added to an album).
    static func perform(_ action: TVPhotoAction, on id: String, model: TVModel, place: TVPhotoPlace) async throws -> TVPhotoChange? {
        let client = place == .lockedFolder ? model.client : model.root.changes
        guard let client else { throw ImmichError.http(403, String(localized: "Manage Photos is off on this Apple TV.")) }
        switch action {
        case .favorite(let on):
            try await client.send("PUT", "assets", body: Update(ids: [id], isFavorite: on))
            return .favorite(id, on)
        case .addToAlbum(let album):
            try await client.changeAlbumAssets(album, ids: [id])
            return nil
        case .archive: try await client.send("PUT", "assets", body: Update(ids: [id], visibility: "archive"))
        case .unarchive, .unlock: try await client.send("PUT", "assets", body: Update(ids: [id], visibility: "timeline"))
        case .lock: try await client.send("PUT", "assets", body: Update(ids: [id], visibility: "locked"))
        case .delete: try await client.send("DELETE", "assets", body: Removal(ids: [id]))
        }
        return .removed(id)
    }
}

/// A photo's menu, from a press and hold, where Manage Photos is on. `changed` tells the viewer, which keeps its own
/// list of photos; the page is told through the environment.
struct TVPhotoMenu: ViewModifier {
    let item: TVItem?
    var changed: (TVPhotoChange) -> Void = { _ in }
    @Environment(TVModel.self) private var model
    @Environment(\.tvPhotoPlace) private var place
    @Environment(\.tvPhotoPage) private var page
    @State private var asking: TVPhotoAction?
    @State private var failure: String?
    @State private var choosingAlbum = false
    /// The album a photo was just added to, said once.
    @State private var added: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let item, model.root.changes != nil { menu(item) }
            }
            .confirmationDialog(asking == .lock ? String(localized: "Move to the Locked Folder?") : String(localized: "Delete this photo?"),
                                isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { action in
                Button(action == .lock ? String(localized: "Move to Locked Folder") : String(localized: "Delete"),
                       role: .destructive) { run(action) }
            } message: { action in
                Text(action == .lock
                     ? "It leaves this Apple TV, and shows again only in the Locked Folder, opened from your iPhone."
                     : "It goes to Recently Deleted in Immich for 30 days, where your iPhone can restore it.")
            }
            .alert("Could Not Change the Photo", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") {}
            } message: {
                Text(failure ?? "")
            }
            .alert(added.map { String(localized: "Added to \u{201C}\($0)\u{201D}") } ?? "",
                   isPresented: Binding(get: { added != nil }, set: { if !$0 { added = nil } })) {
                Button("OK") {}
            }
            .sheet(isPresented: $choosingAlbum) {
                TVAlbumPicker { album in run(.addToAlbum(album.id), album: album.albumName) }
            }
    }

    @ViewBuilder
    private func menu(_ item: TVItem) -> some View {
        switch place {
        case .lockedFolder:
            Button("Move Out of the Locked Folder", systemImage: "lock.open") { run(.unlock) }
        case .library, .archive:
            Button(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "heart.slash" : "heart") {
                run(.favorite(!item.isFavorite))
            }
            Button("Add to Album…", systemImage: "rectangle.stack.badge.plus") { choosingAlbum = true }
            if place == .archive {
                Button("Move to Library", systemImage: "archivebox") { run(.unarchive) }
            } else {
                Button("Archive", systemImage: "archivebox") { run(.archive) }
            }
            Button("Move to Locked Folder", systemImage: "lock") { asking = .lock }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { asking = .delete }
    }

    private func run(_ action: TVPhotoAction, album: String? = nil) {
        guard let item else { return }
        let model = model, place = place
        Task {
            do {
                if let change = try await TVPhotoActions.perform(action, on: item.id, model: model, place: place) {
                    changed(change)
                    page?.apply(change)
                } else {
                    added = album
                }
            } catch ImmichError.http(403, _) where action.addsToAlbum {
                // A key made before Add to Album may change photos but not albums: turned off and on again, it may.
                failure = String(localized: "This Apple TV may not do that yet. Turn Manage Photos off and on again in Settings to allow it.")
            } catch ImmichError.unauthorized where place != .lockedFolder {
                // The second key was made read-only, or forgotten, on the iPhone: Manage Photos turns itself off. In the
                // Locked Folder a 401 is its session ending, which locks the folder (TVLockedFolderVisit).
                model.root.stopChanges(reason: String(localized: "Manage Photos was turned off on your iPhone."))
                failure = String(localized: "Manage Photos was turned off on your iPhone.")
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A request to the iPhone the person chose in the system's picker: the TV's name, what it asks for and its server, and
/// the iPhone's answer (AppleTVSetup on the iPhone).
@MainActor
enum TVPhone {
    static func ask(_ endpoint: NWEndpoint, purpose: String, server: URL) async -> (fields: [String: String]?, error: String?) {
        let connection = NWConnection(to: endpoint, using: .applicationService)
        connection.start(queue: .main)
        let hello = ["name": UIDevice.current.name, "purpose": purpose, "server": server.absoluteString]
        connection.send(content: (try? JSONEncoder().encode(hello)) ?? Data(), completion: .contentProcessed { _ in })
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                connection.cancel()
                let fields = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                continuation.resume(returning: (fields, error?.localizedDescription))
            }
        }
    }
}

/// Manage Photos in Settings: off, a line on what it allows and Turn On with iPhone, the system's picker; on, how to
/// use it and Turn Off, which asks nothing.
struct TVManagePhotos: View {
    @Environment(TVModel.self) private var tv
    @State private var waiting = false

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: tv.changes == nil ? "hand.tap" : "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(tv.changes == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text("Manage Photos").font(.title2)
            Text(tv.changes == nil
                 ? "Press and hold a photo to favorite, archive or delete it, or move it to the Locked Folder. Your iPhone allows it, with Face ID, and keeps it in Immich until you turn it off."
                 : "On. Press and hold a photo, in a grid or full screen, for its menu.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            if tv.changes == nil {
                DevicePicker(.applicationService(name: "verso-tv-setup")) { endpoint in
                    Task { await turnOn(endpoint) }
                } label: {
                    Label("Turn On with iPhone", systemImage: "iphone")
                } fallback: {
                    Text("This Apple TV cannot look for iPhones.")
                } parameters: {
                    .applicationService
                }
                .disabled(waiting)
                if waiting {
                    ProgressView("Waiting for your iPhone")
                } else if let reason = tv.changesReason {
                    Text(reason).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 1100)
                }
            } else {
                Button("Turn Off", role: .destructive) { tv.stopChanges() }
                Text("Turned off, this Apple TV forgets its key at once. Read Only on your iPhone (Account, Apple TV) deletes it in Immich.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Manage Photos")
    }

    private func turnOn(_ endpoint: NWEndpoint) async {
        guard let server = tv.client?.serverURL else { return }
        waiting = true
        tv.changesReason = nil
        defer { waiting = false }
        let (fields, error) = await TVPhone.ask(endpoint, purpose: "changes", server: server)
        if let key = fields?["changeKey"] {
            tv.allowChanges(key: key)
        } else {
            tv.changesReason = fields?["reason"]
                ?? (fields?["refused"] != nil ? String(localized: "The iPhone did not allow it.")
                    : String(localized: "The iPhone did not answer\(error.map { ": \($0)" } ?? ".")"))
        }
    }
}
