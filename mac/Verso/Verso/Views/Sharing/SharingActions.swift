// Share on the Mac, as the iPhone's (ARCHITECTURE.md, "Verso on the Mac" and "Sharing from the iPhone"; SPEC.md,
// "Sharing from the Mac"): the system's share picker opens at once over the photos chosen, at the toolbar's Share or,
// from a right-click menu, at the pointer, as Finder's Share… opens it. Every photo in it is a promise of its original,
// downloaded only once the service chosen asks for it (Mail, Messages, AirDrop, Notes, another app's extension), into a
// folder of its own in the temporary directory under its own name, and the service is handed that file; the folder goes
// once the service says it is done. Beside the services, Verso's own Create Link… and Add to Link… make the photos an
// Immich link, or add them to one, in a sheet; nothing downloads for a link.

import AppKit
import os
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// Share, for the photos `assetIDs`: the system's share picker at once, with Create Link… and Add to Link… beside the
/// services where `allowPublicLinks` and the server has links. A button, though the grid's page builds it by this name.
struct SharingMenu: View {
    @Environment(LibrarySession.self) private var session
    let assetIDs: [String]
    var allowPublicLinks = true
    @State private var anchor = SharePickerAnchor()

    var body: some View {
        Button {
            SharePicker.show(session: session, assetIDs: assetIDs,
                             offersLinks: allowPublicLinks && session.sharing.linksAvailable, from: anchor.view)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .background(SharePickerAnchor.Marker(anchor: anchor))
        // With nothing to share, the button is dimmed.
        .disabled(assetIDs.isEmpty)
    }
}

/// Share… in the right-click menu of photos the account may not link: the share picker at the pointer.
struct SharingMenuItems: View {
    @Environment(LibrarySession.self) private var session
    let assetIDs: [String]
    var allowPublicLinks = true

    var body: some View {
        Button("Share…") {
            SharePicker.show(session: session, assetIDs: assetIDs,
                             offersLinks: allowPublicLinks && session.sharing.linksAvailable, from: nil)
        }
        .disabled(assetIDs.isEmpty)
    }
}

/// The view Share's picker opens from: the toolbar's button, where it is drawn. In a menu nothing is drawn, and the
/// picker opens at the pointer.
@MainActor final class SharePickerAnchor {
    weak var view: NSView?

    struct Marker: NSViewRepresentable {
        let anchor: SharePickerAnchor

        func makeNSView(context: Context) -> NSView {
            let view = PassingView()
            anchor.view = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }

    private final class PassingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One Share: the picker, its promises and the files they downloaded, kept until the service chosen is done.
@MainActor final class SharePicker: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    /// The shares under way: the picker holds its delegate weakly.
    private static var open: Set<SharePicker> = []

    private let session: LibrarySession
    private let assetIDs: [String]
    private let offersLinks: Bool
    private let downloads: ShareDownloads
    /// Verso's own link actions, so choosing one ends the share at once: it takes nothing from the picker.
    private var linkServices: [NSSharingService] = []

    private init(session: LibrarySession, assetIDs: [String], offersLinks: Bool) {
        self.session = session
        self.assetIDs = assetIDs
        self.offersLinks = offersLinks
        downloads = ShareDownloads(client: session.client) { [weak session] error in session?.handle(error) }
    }

    /// Opens the picker over the photos, at `view`, or at the pointer in the window in front when there is none.
    static func show(session: LibrarySession, assetIDs: [String], offersLinks: Bool, from view: NSView?) {
        guard !assetIDs.isEmpty else { return }
        SharingTemporaryFiles.sweep()
        let share = SharePicker(session: session, assetIDs: assetIDs, offersLinks: offersLinks)
        let picker = NSSharingServicePicker(items: share.items())
        picker.delegate = share
        if let view, view.window != nil {
            open.insert(share)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let window = session.macWindow ?? NSApp.keyWindow,
                  let frame = window.contentView?.superview ?? window.contentView {
            // The window's frame, toolbar and all, where the pointer may be.
            open.insert(share)
            let pointer = frame.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            picker.show(relativeTo: NSRect(x: pointer.x, y: pointer.y, width: 1, height: 1), of: frame,
                        preferredEdge: .minY)
        }
    }

    /// Each photo as the promise of its original, with a header the picker draws from the thumbnails already shown:
    /// how many, and the first one's picture, so opening it downloads nothing.
    private func items() -> [Any] {
        let videos = assetIDs.filter { session.loadedItem($0)?.isVideo == true }.count
        let count = assetIDs.count
        let title = videos == 0 ? (count == 1 ? String(localized: "1 Photo") : String(localized: "\(count) Photos"))
            : videos == count ? (count == 1 ? String(localized: "1 Video") : String(localized: "\(count) Videos"))
            : String(localized: "\(count) Items")
        return assetIDs.enumerated().map { position, id in
            let type: UTType = switch session.loadedItem(id)?.isVideo {
            case true?: .movie
            case false?: .image
            case nil: .data
            }
            let picture = session.pipeline.cachedThumbnail(id, size: .thumbnail).map { NSImage(cgImage: $0, size: .zero) }
            return NSPreviewRepresentingActivityItem(item: downloads.provider(id, type: type),
                                                     title: position == 0 ? title : nil, image: picture, icon: nil)
        }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        guard offersLinks else { return proposedServices }
        let (session, assetIDs) = (session, assetIDs)
        let create = NSSharingService(title: String(localized: "Create Link…"), image: Self.symbol("link.badge.plus"),
                                      alternateImage: nil) {
            session.sharing.presentation = .init(kind: .create, assetIDs: assetIDs)
        }
        let add = NSSharingService(title: String(localized: "Add to Link…"), image: Self.symbol("link"),
                                   alternateImage: nil) {
            session.sharing.presentation = .init(kind: .add, assetIDs: assetIDs)
        }
        linkServices = [create, add]
        return proposedServices + linkServices
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        ShareDownloads.log.info("share picker: \(service?.title ?? "nothing", privacy: .public) chosen")
        // Closed without a choice, or a link action, which downloads nothing: the share is over.
        if let service, !linkServices.contains(service) { return }
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finish()
    }

    /// Downloads still going stop, and the files go.
    private func finish() {
        downloads.close()
        Self.open.remove(self)
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

/// The originals the chosen service asked for, downloaded into one folder of the temporary directory (the Locked
/// Folder's own for its photos), which goes when the share is over; a download still going then stops, and one that ends
/// after is not kept.
private final class ShareDownloads: Sendable {
    static let log = Logger(subsystem: "dev.hviid.Verso", category: "share")

    private struct State {
        var folder: URL?
        var closed = false
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    private let client: ImmichClient
    private let base: URL
    /// Hands a failed download's error to the window's account, which signs out on a refused key, as the grid does.
    private let report: @MainActor @Sendable (any Error) -> Void

    init(client: ImmichClient, report: @escaping @MainActor @Sendable (any Error) -> Void) {
        self.client = client
        self.report = report
        base = client.transferRoot ?? FileManager.default.temporaryDirectory
    }

    deinit {
        if let folder = state.withLock({ $0.folder }) { try? FileManager.default.removeItem(at: folder) }
    }

    /// A promise of the original of `id`, answered with the downloaded file's own address once a service asks, as a
    /// shared file is handed over: the service takes it from the share's folder, which stays until the share is over.
    /// (On the iPhone a file representation was handed over as a copy of its own, gone again before Save to Files read
    /// it.)
    func provider(_ id: String, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: type.identifier) { [self] completion, _, _ in
            guard let completion else { return }
            load(id) { file, error in completion(file as NSURL?, error) }
        }
        return provider
    }

    /// Runs a download for the service that asked; the share's end stops it.
    private func load(_ id: String, _ completion: @escaping @Sendable (URL?, (any Error)?) -> Void) {
        let key = UUID()
        Self.log.info("share picker: an original asked for")
        state.withLock { current in
            guard !current.closed else {
                completion(nil, CancellationError())
                return
            }
            current.tasks[key] = Task { [self] in
                do {
                    completion(try await download(id), nil)
                } catch {
                    completion(nil, error)
                    if !error.isCancellation { await report(error) }
                }
                state.withLock { _ = $0.tasks.removeValue(forKey: key) }
            }
        }
    }

    /// An original from Immich, under the name its download gives it, in a folder of its own so two of one name never
    /// meet.
    private func download(_ id: String) async throws -> URL {
        let (temporary, response) = try await client.session.download(for: client.originalRequest(id))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else {
            throw ImmichError.http(400, String(localized: "Couldn't download an original."))
        }
        if response.statusCode == 401 { throw ImmichError.unauthorized(nil) }
        guard (200..<300).contains(response.statusCode) else {
            throw ImmichError.http(response.statusCode, String(localized: "Couldn't download an original."))
        }
        try Task.checkCancellation()
        let name = URL(fileURLWithPath: response.suggestedFilename ?? id).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? id : name
        return try state.withLock { current in
            guard !current.closed else { throw CancellationError() }
            let folder = current.folder ?? base.appendingPathComponent("ImmichShare-\(UUID().uuidString)", isDirectory: true)
            current.folder = folder
            let itemFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
            let file = itemFolder.appendingPathComponent(safeName)
            try FileManager.default.moveItem(at: temporary, to: file)
            return file
        }
    }

    /// The share is over: downloads still going stop, and the folder goes.
    func close() {
        state.withLock { current in
            current.closed = true
            for task in current.tasks.values { task.cancel() }
            if let folder = current.folder { try? FileManager.default.removeItem(at: folder) }
            current.folder = nil
        }
    }
}

private struct SharingPresentationModifier: ViewModifier {
    @Environment(LibrarySession.self) private var session
    func body(content: Content) -> some View {
        @Bindable var sharing = session.sharing
        content.sheet(item: $sharing.presentation) { presentation in
            switch presentation.kind {
            case .create: SharedLinkEditor(albumID: presentation.albumID, assetIDs: presentation.assetIDs)
            case .add: AddToSharedLinkView(assetIDs: presentation.assetIDs)
            }
        }
    }
}
extension View {
    func sharingPresentation() -> some View { modifier(SharingPresentationModifier()) }
}

/// Add to Link…: the account's links to chosen photos (not an album's, which share their album); a click adds the
/// photos to one, and its address follows, to copy or share, as after Create Link….
private struct AddToSharedLinkView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    @State private var added: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Link").font(.title2.bold())
            if let added {
                Text(added.absoluteString).textSelection(.enabled)
                HStack {
                    Button("Copy Link") { SharingClipboard.copy(added) }
                    ShareLink(item: added)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("The photos become visible to anyone who can open the link.")
                List(session.sharing.links.filter { $0.type == "INDIVIDUAL" }) { link in
                    Button(link.title) { Task { await add(to: link) } }
                        .disabled(session.sharing.busy)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 440, height: added == nil ? 360 : nil).sharingError()
        .task { await session.sharing.reload() }
    }

    private func add(to link: SharedLink) async {
        guard await session.sharing.perform({
            try await session.client.changeSharedLinkAssets(link.id, assetIDs: assetIDs, adding: true)
        }) else { return }
        // The link's page and card read it again when next shown.
        session.services.linkPreviews.forget(link.id)
        session.gridModel(for: .sharedLink(link.id)).markStale()
        do {
            added = try await session.client.sharingPublicURL(link)
        } catch {
            session.handle(error)
            dismiss()
        }
    }
}

/// Folders an earlier share left behind, when the app ended or a service never said it was done; an hour old, so
/// another window's share in progress keeps its own.
enum SharingTemporaryFiles {
    static func sweep() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("ImmichShare-") {
            guard let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                  values.isDirectory == true, let created = values.creationDate,
                  created < Date().addingTimeInterval(-3600) else { continue }
            try? manager.removeItem(at: folder)
        }
    }
}
