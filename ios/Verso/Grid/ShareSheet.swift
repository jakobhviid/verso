// Share on iOS, as Photos shares: the system's share sheet opens at once over the photos chosen, with their count and
// the first one's thumbnail in its header, and every photo in it is a promise of its original. An original downloads
// only once the app chosen in the sheet asks for it (Messages, Mail, AirDrop, Save to Files, Save Image or Save Video,
// Copy, another app's extension), into a folder of its own in the temporary directory, each under its own name in a
// folder of its own so two of one name never meet, and the app is handed that file, as a shared file is; the folder
// goes when the sheet closes. Photos on their way to Immich are promised from the phone instead, as Photos shows them
// now (PhoneImages.export).
//
// Beside the apps, the sheet has Verso's own Create Link… and Add to Link… (ShareLinkActivity) where Immich can make
// the photos a shared link: the account's own photos, links on for it, outside the Locked Folder and Recently Deleted,
// and none on its way from the phone, as the Mac offers its Create Public Link… and Add to Public Link…. The sheet
// hands them no photo, so nothing downloads for a link. A link's address is shared through the same sheet, plain.
//
// The sheet is UIKit's, presented from a view's background (`shareSheet`) over whatever the window shows, so the apps
// and Verso's actions present their own screens as the system arranges them.

import LinkPresentation
import os
import SwiftUI
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// What one Share shares.
@MainActor struct ShareContent {
    /// The window's account, for Immich's originals and links; none where only photos on the phone are shared.
    let session: LibrarySession?
    /// Immich's photos.
    var originals: [ShareOriginal] = []
    /// Photos on their way to Immich, by their local identifiers, shared from the phone.
    var phoneIDs: [String] = []
    /// Whether Create Link… and Add to Link… are offered.
    var offersLinks = false
}

/// An Immich photo in the share sheet, as far as it is known before its original downloads.
struct ShareOriginal: Sendable {
    let id: String
    let isVideo: Bool
    /// The original's file name, where the photo's details have loaded (the viewer's photo); else the download says it.
    var name: String? = nil
    /// The original's own format, where its name says one; else it is offered as a photo or a video.
    var type: UTType? = nil
}

extension PhotoActionsRules {
    /// What Share shares of these photos here: their originals, and the link actions where Immich can make them a
    /// link, as the Mac decides it (its grid's `allowPublicLinks`).
    func shareContent(_ ids: [String]) -> ShareContent {
        let (immich, phone) = split(ids)
        let originals = immich.map { ShareOriginal(id: $0, isVideo: model.item($0)?.isVideo ?? false) }
        let offersLinks = phone.isEmpty && session.sharing.linksAvailable && model.canMutate(immich)
            && source != .locked && source != .trash && session.lockedFolder == nil
        return ShareContent(session: session, originals: originals, phoneIDs: phone, offersLinks: offersLinks)
    }
}

/// A link's address to share, as a share sheet's request.
struct SharedLinkAddress: Identifiable {
    let id = UUID()
    let url: URL
}

extension View {
    /// The share sheet for `request`'s photos once it is set; `onClose` once the sheet has closed, whatever was done. On
    /// an iPad it points at Share where it is: at the bottom's leading end, or at the top's (`fromTop`), beside Back.
    func shareSheet<Request: Identifiable>(item request: Binding<Request?>, fromTop: Bool = false,
                                           content: @escaping (Request) -> ShareContent,
                                           onClose: @escaping () -> Void = {}) -> some View {
        background(ShareSheetPresenter(request: request, fromTop: fromTop,
                                       makeSheet: { ShareSheetController.photos(content($0)) },
                                       onClose: { _ in onClose() }))
    }

    /// The share sheet for a link's address once it is set; `onClose` once the sheet has closed, with whether the
    /// address was sent or copied.
    func shareSheet(address: Binding<SharedLinkAddress?>, onClose: @escaping (Bool) -> Void = { _ in }) -> some View {
        background(ShareSheetPresenter(request: address, makeSheet: { ShareSheetController.address($0.url) },
                                       onClose: onClose))
    }
}

/// Presents a share sheet from UIKit when the request is set, over what the window shows, and clears the request once
/// the sheet has closed for good.
private struct ShareSheetPresenter<Request: Identifiable>: UIViewControllerRepresentable {
    @Binding var request: Request?
    /// Share is at the top's leading end, beside Back, as the viewer has it on an iPad.
    var fromTop = false
    let makeSheet: (Request) -> ShareSheetController
    let onClose: (Bool) -> Void

    final class Coordinator {
        /// The request shown, so an update does not present it twice.
        var shownID: AnyHashable?
        /// The sheet shown, kept until it has closed and the apps have finished with its files.
        var sheet: ShareSheetController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let request else {
            coordinator.shownID = nil
            return
        }
        guard coordinator.shownID != AnyHashable(request.id) else { return }
        coordinator.shownID = AnyHashable(request.id)
        let binding = $request
        let requestID = AnyHashable(request.id)
        let sheet = makeSheet(request)
        let onClose = onClose
        sheet.onClose = { [weak coordinator] completed in
            if coordinator?.sheet === sheet { coordinator?.sheet = nil }
            if let current = binding.wrappedValue, AnyHashable(current.id) == requestID { binding.wrappedValue = nil }
            onClose(completed)
        }
        coordinator.sheet = sheet
        // Presented once this update is over, from the top of what the window shows.
        Task { @MainActor in
            var presenter = controller
            while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
            if let popover = sheet.popoverPresentationController {
                // On iPad, from where Share is in the bars: the bottom's leading end, or the top's beside Back.
                let view = controller.view!
                popover.sourceView = view
                popover.sourceRect = fromTop
                    ? CGRect(x: view.bounds.minX + 98, y: view.safeAreaInsets.top + 22, width: 1, height: 1)
                    : CGRect(x: view.bounds.minX + 40, y: view.bounds.maxY - 40, width: 1, height: 1)
            }
            presenter.present(sheet, animated: true)
        }
    }
}

/// The system's share sheet, which says once when it has closed for good, and keeps the originals it downloaded until
/// then. It closes for good when it was closed without a choice or what was chosen was done; an app's screen cancelled
/// leaves the sheet showing (its files go, and download again if asked), until it is closed.
final class ShareSheetController: UIActivityViewController {
    /// Told once, when the sheet has closed for good, with whether what was chosen was done.
    var onClose: ((Bool) -> Void)?
    fileprivate var downloads: ShareDownloads?
    /// An app's screen was cancelled, the sheet showing still, so its going is the end.
    private var activityCancelled = false
    private var closed = false

    /// The photos' sheet: each a promise of its original, the header, and the link actions where they apply.
    static func photos(_ content: ShareContent) -> ShareSheetController {
        ShareDownloads.sweepOldFolders()
        let session = content.session
        let downloads = ShareDownloads(client: session?.client) { error in session?.handle(error) }
        let providers = content.phoneIDs.map(downloads.phoneProvider) + content.originals.map(downloads.provider)
        // The header's words and picture go with the first photo, which the sheet reads them from.
        let metadata = headerMetadata(content)
        let sources = providers.enumerated().map { index, provider in
            ShareItemSource(provider: provider, metadata: index == 0 ? metadata : nil)
        }
        var activities: [UIActivity] = []
        if content.offersLinks, let session {
            let ids = content.originals.map(\.id)
            activities = [ShareLinkActivity(.create, session: session, assetIDs: ids),
                          ShareLinkActivity(.add, session: session, assetIDs: ids)]
        }
        let sheet = ShareSheetController(activityItems: sources, applicationActivities: activities)
        sheet.downloads = downloads
        sheet.watchCompletion()
        return sheet
    }

    /// A link's address, plain, to send or copy.
    static func address(_ url: URL) -> ShareSheetController {
        let sheet = ShareSheetController(activityItems: [url], applicationActivities: nil)
        sheet.watchCompletion()
        return sheet
    }

    /// The header, as Photos': how many photos are chosen, beside the first one's thumbnail, which comes from the
    /// thumbnails already shown, or loads; never from an original.
    private static func headerMetadata(_ content: ShareContent) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        let phoneVideos = content.phoneIDs.filter { BackupLibrary.asset($0)?.mediaType == .video }.count
        let videos = content.originals.filter(\.isVideo).count + phoneVideos
        let count = content.originals.count + content.phoneIDs.count
        if videos == 0 {
            metadata.title = count == 1 ? String(localized: "1 Photo Selected")
                : String(localized: "\(count) Photos Selected")
        } else if videos == count {
            metadata.title = count == 1 ? String(localized: "1 Video Selected")
                : String(localized: "\(count) Videos Selected")
        } else {
            metadata.title = String(localized: "\(count) Items Selected")
        }
        if let localID = content.phoneIDs.first {
            if let picture = PhoneImages.cached(localID) { metadata.iconProvider = NSItemProvider(object: picture) }
        } else if let first = content.originals.first, let pipeline = content.session?.pipeline {
            let provider = NSItemProvider()
            let id = first.id
            provider.registerObject(ofClass: UIImage.self, visibility: .all) { completion in
                Task {
                    let thumbnail = await pipeline.thumbnail(id, size: .thumbnail)
                    completion(thumbnail.map { UIImage(cgImage: $0) }, nil)
                }
                return nil
            }
            metadata.iconProvider = provider
        }
        return metadata
    }

    private func watchCompletion() {
        completionWithItemsHandler = { [weak self] activityType, completed, _, error in
            let chosen = activityType?.rawValue ?? "nothing"
            ShareDownloads.log.info("share sheet: \(chosen, privacy: .public) ended, done: \(completed)")
            guard let self else { return }
            if activityType == nil || completed || self.isGone {
                self.close(completed)
            } else {
                // An app's screen cancelled, back to the sheet: what it downloaded goes.
                self.activityCancelled = true
                self.downloads?.removeFiles()
            }
        }
    }

    private var isGone: Bool { presentingViewController == nil || isBeingDismissed }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Closed after an app's screen was cancelled: the sheet may not say so again.
        if isBeingDismissed, activityCancelled { close(false) }
    }

    private func close(_ completed: Bool) {
        guard !closed else { return }
        closed = true
        downloads?.close()
        onClose?(completed)
        onClose = nil
    }
}

/// The originals the sheet's apps asked for, downloaded into one folder of the temporary directory, which goes when
/// the sheet closes; a download still going then stops, and one that ends after is not kept.
private final class ShareDownloads: Sendable {
    static let log = Logger(subsystem: "dev.hviid.Verso", category: "share")

    private struct State {
        var folder: URL?
        var closed = false
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    private let client: ImmichClient?
    /// Where the sheet's folder goes: the temporary directory, or the Locked Folder's own, which goes when it locks.
    private let base: URL
    /// Hands a failed download's error to the window's account, which signs out on a refused key, as the grid does.
    private let report: @MainActor @Sendable (any Error) -> Void

    init(client: ImmichClient?, report: @escaping @MainActor @Sendable (any Error) -> Void) {
        self.client = client
        self.report = report
        base = client?.transferRoot ?? FileManager.default.temporaryDirectory
    }

    deinit {
        if let folder = state.withLock({ $0.folder }) { try? FileManager.default.removeItem(at: folder) }
    }

    /// An Immich photo as a promise of its original, in its own format where it is known, else as a photo or a video.
    func provider(_ original: ShareOriginal) -> NSItemProvider {
        let id = original.id
        return promise(original.type ?? (original.isVideo ? .movie : .image), name: original.name) { [self] in
            try await download(id)
        }
    }

    /// A photo on its way to Immich as a promise of the phone's copy, as Photos shows it now.
    @MainActor func phoneProvider(_ localID: String) -> NSItemProvider {
        let type: UTType = BackupLibrary.asset(localID)?.mediaType == .video ? .movie : .image
        return promise(type, name: nil) { [self] in try await PhoneImages.export(localID, into: itemFolder()) }
    }

    /// A promise of a file, answered with the file's own address once an app asks, as a shared file is handed over:
    /// the app takes it from the sheet's folder, which stays until the sheet closes. (A file representation is handed
    /// over as a copy of its own, which is gone again before Save to Files reads it.)
    private func promise(_ type: UTType, name: String?,
                         _ work: @escaping @Sendable () async throws -> URL) -> NSItemProvider {
        let provider = NSItemProvider()
        if let name { provider.suggestedName = (name as NSString).deletingPathExtension }
        provider.registerItem(forTypeIdentifier: type.identifier) { [self] completion, _, _ in
            guard let completion else { return }
            load({ file, error in completion(file as NSURL?, error) }, work)
        }
        return provider
    }

    /// Stands in for a photo while the sheet decides what it offers and draws its header, so nothing downloads for
    /// that: the same kind, with nothing to load.
    static func placeholder(for provider: NSItemProvider) -> NSItemProvider {
        let placeholder = NSItemProvider()
        placeholder.suggestedName = provider.suggestedName
        for type in provider.registeredTypeIdentifiers {
            placeholder.registerItem(forTypeIdentifier: type) { completion, _, _ in
                completion?(nil, CocoaError(.featureUnsupported))
            }
        }
        return placeholder
    }

    /// Runs a load for the app that asked; the sheet's closing stops it.
    private func load(_ completion: @escaping @Sendable (URL?, (any Error)?) -> Void,
                      _ work: @escaping @Sendable () async throws -> URL) {
        let key = UUID()
        Self.log.info("share sheet: an original asked for")
        state.withLock { current in
            guard !current.closed else {
                completion(nil, CancellationError())
                return
            }
            current.tasks[key] = Task { [self] in
                do {
                    let file = try await work()
                    completion(file, nil)
                } catch {
                    completion(nil, error)
                    if !error.isCancellation { await report(error) }
                }
                state.withLock { _ = $0.tasks.removeValue(forKey: key) }
            }
        }
    }

    /// An original from Immich, under the name its download gives it.
    private func download(_ id: String) async throws -> URL {
        guard let client else { throw CancellationError() }
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
            let file = try itemFolder(&current).appendingPathComponent(safeName)
            try FileManager.default.moveItem(at: temporary, to: file)
            return file
        }
    }

    /// A folder of its own for one file, in the sheet's folder.
    private func itemFolder() throws -> URL {
        try state.withLock { current in
            guard !current.closed else { throw CancellationError() }
            return try itemFolder(&current)
        }
    }

    private func itemFolder(_ state: inout State) throws -> URL {
        let folder = state.folder ?? base.appendingPathComponent("ImmichShare-\(UUID().uuidString)", isDirectory: true)
        state.folder = folder
        let itemFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        return itemFolder
    }

    /// The files an app's cancelled screen asked for; the sheet shows still, and downloads them again if asked.
    func removeFiles() {
        state.withLock { current in
            if let folder = current.folder { try? FileManager.default.removeItem(at: folder) }
            current.folder = nil
        }
    }

    /// The sheet has closed: downloads still going stop, and the folder goes.
    func close() {
        state.withLock { current in
            current.closed = true
            for task in current.tasks.values { task.cancel() }
            if let folder = current.folder { try? FileManager.default.removeItem(at: folder) }
            current.folder = nil
        }
    }

    /// Folders an earlier share left behind, when the app ended while its sheet was open; an hour old, so another
    /// window's share in progress keeps its own.
    static func sweepOldFolders() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let folders = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: keys)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("ImmichShare-") {
            guard let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let created = values.creationDate, created < Date().addingTimeInterval(-3600) else { continue }
            try? manager.removeItem(at: folder)
        }
    }
}

/// One photo in the sheet: the promise of its original for the apps, and nothing to load for Verso's link actions,
/// which know their photos already. While the sheet decides what it offers and draws its header, a stand-in of the same
/// kind takes its place, as the sheet would load the photo itself for the header where it is the only one.
private final class ShareItemSource: NSObject, UIActivityItemSource {
    let provider: NSItemProvider
    let metadata: LPLinkMetadata?

    init(provider: NSItemProvider, metadata: LPLinkMetadata?) {
        self.provider = provider
        self.metadata = metadata
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        ShareDownloads.placeholder(for: provider)
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        ShareLinkActivity.isOwn(activityType) ? "" : provider
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}
