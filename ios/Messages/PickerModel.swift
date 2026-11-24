// The picker's state (ios/Messages): the account the app keeps, read from the Keychain group the app shares with its
// extensions (AccountVault), so there is no second sign-in; for that account the library (PickerLibrary); the size
// Messages shows the picker at, and the section the expanded picker is on; and sending a photo, a preview-sized copy
// or the original, which goes into the conversation's message field for the person to send.

import Foundation
import Observation
import os
#if DEBUG
import Photos
#endif

/// What the view controller does for the picker (MessagesViewController).
@MainActor
protocol PickerHost: AnyObject {
    /// Put a file into the conversation's message field, under the given name, in place of what the picker put there.
    func insert(_ file: URL, named name: String) async throws
    /// Ask Messages for the compact or the expanded picker.
    func askForSize(expanded: Bool)
    func openVerso()
}

enum PickerProblem: LocalizedError {
    case noConversation
    case download(Int)

    var errorDescription: String? {
        switch self {
        case .noConversation: String(localized: "Messages has no conversation open.")
        case .download(let status): String(localized: "Immich did not send the photo (\(status)).")
        }
    }
}

/// The expanded picker's sections. On This iPhone, the phone's own newest photos, comes beside them with backing up
/// (ROADMAP.md, M10): a section of its own, from PhotoKit, which needs the photo library's permission.
enum PickerSection: String, CaseIterable, Identifiable {
    case recents, favorites, albums
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .albums: "Albums"
        }
    }
}

@MainActor @Observable
final class PickerModel {
    enum Phase {
        /// Before the account is read: nothing shows, so nothing changes as it is.
        case reading
        /// Nobody is signed in to Verso, or the account's sign-in has ended on the server.
        case signedOut(sessionEnded: Bool)
        case signedIn(PickerLibrary)
    }

    private(set) var phase: Phase = .reading
    /// Messages shows the picker expanded over the conversation, rather than compact beneath it.
    var isExpanded = false
    var section: PickerSection = .recents
    /// A tap puts the original into the message field, with its metadata, rather than a copy sized for Messages: the
    /// Original toggle at the picker's top, kept for the next time.
    var sendsOriginals = UserDefaults.standard.bool(forKey: PickerModel.originalsKey) {
        didSet { UserDefaults.standard.set(sendsOriginals, forKey: Self.originalsKey) }
    }
    nonisolated static let originalsKey = "messages.sendsOriginals"
    /// The expanded picker opens with its search field active (the compact picker's Search).
    var searchRequested = false
    /// The photos being fetched, for the message field or to send.
    private(set) var sending: Set<String> = []
    /// The photo in the message field: Messages keeps one item from an app there, so the next tap replaces it.
    private(set) var inField: String?
    /// The last photo put into the field, which the next waits for, so of quick taps the last one's photo stays.
    @ObservationIgnored private var lastInsert: Task<Void, Never>?
    var problem: String?
    @ObservationIgnored weak var host: (any PickerHost)?

    private let log = Logger(subsystem: "dev.hviid.Verso", category: "messages")

    /// Messages opened the picker, or brought it back: the app's account, read again, as Verso may have signed in,
    /// out or to another account since.
    func becameActive() {
        let entry: AccountVault.Entry?
        do {
            entry = try AccountVault.load()
        } catch {
            log.error("the app's account could not be read: \(String(describing: error), privacy: .public)")
            entry = nil
        }
        #if DEBUG
        // Whether the extension shares the app's photo library permission, for On This iPhone: read, never asked for.
        log.info("photo library permission: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue, privacy: .public)")
        #endif
        guard let entry else {
            phase = .signedOut(sessionEnded: false)
            return
        }
        if case .signedIn(let library) = phase, library.belongs(to: entry) { return }
        let library = PickerLibrary(entry: entry)
        library.onSignInEnded = { [weak self] in self?.phase = .signedOut(sessionEnded: true) }
        phase = .signedIn(library)
        inField = nil
        PickerFiles.sweep()
    }

    func expand(searching: Bool) {
        searchRequested = searching
        host?.askForSize(expanded: true)
    }

    func openVerso() {
        host?.openVerso()
    }

    /// Put a photo into the message field: Immich's preview, about 1440 pixels on its long side and without the
    /// original's metadata, or the original as it was taken. Messages gives an app one item in the field, so this
    /// photo takes the place of the one put there before; of quick taps the photos go in in order, and the last stays.
    /// In the expanded picker, Messages then shows the compact one, so the field and the photo in it show.
    /// (Messages offers apps no way to put several there, and sends from an app one at a time, taking the app out of
    /// the conversation after each, so the picker does not send; several photos go to Messages from Verso's own
    /// Share.)
    func send(_ photo: PickerPhoto, original: Bool) {
        guard !sending.contains(photo.id), case .signedIn(let library) = phase, let host else { return }
        sending.insert(photo.id)
        let fetch = Task { try await library.copy(of: photo, original: original) }
        let previous = lastInsert
        lastInsert = Task { @MainActor in
            defer { sending.remove(photo.id) }
            do {
                let file = try await fetch.value
                await previous?.value
                try await host.insert(file.url, named: file.name)
                inField = photo.id
                log.info("put \(original ? "an original" : "a preview", privacy: .public) into the message field")
                if isExpanded { host.askForSize(expanded: false) }
            } catch {
                await previous?.value
                failed(error, library: library)
            }
        }
    }

    private func failed(_ error: Error, library: PickerLibrary) {
        guard !error.isCancellation else { return }
        if error.isUnauthorized {
            library.onSignInEnded?()
            return
        }
        log.error("sending failed: \(String(describing: error), privacy: .public)")
        problem = error.problemText
    }
}

extension Error {
    /// A task or download given up, which no one needs to hear about.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    /// The server refused the account: its session ended, or its key was taken away.
    var isUnauthorized: Bool {
        if case .unauthorized? = self as? ImmichError { true } else { false }
    }

    /// A failure as the picker says it: a certificate refused (not the one trusted for the server, ServerTrust) sends
    /// the person to the app, which asks about it.
    var problemText: String {
        ServerTrust.isRefusal(self)
            ? String(localized: "Immich's certificate is not trusted, so Verso does not connect to it. Open Verso to check it.")
            : localizedDescription
    }
}
