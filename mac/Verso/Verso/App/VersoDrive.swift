#if os(macOS)
import AppKit
#else
import UIKit
#endif
import FileProvider
import Observation
import os
import UniformTypeIdentifiers
import VersoCore

/// Verso Drive: the library as a location in Finder on the Mac, and in the Files app on iPhone and iPad, as on Linux
/// (ARCHITECTURE.md, "Verso on the Mac"). It is off until switched on, in Settings on the Mac and in the account's
/// sheet on iOS. On, the app keeps the gallery's account for the drive's extension (mac/FileProvider), adds its
/// location, and wakes the extension every ten seconds while the app runs, so changes on the server reach Finder and
/// Files: the extension has no clock of its own. Signing out takes the location away; the switch stays, so the next
/// sign-in brings it back.
@MainActor @Observable
final class VersoDrive {
    static let shared = VersoDrive()

    /// How often the app wakes the extension to ask the server what changed; Linux polls as often.
    private static let changeSignal: Duration = .seconds(10)
    /// Never changes: the system keys its copy of the library by it.
    private static let identifier = NSFileProviderDomainIdentifier("library")
    /// The account the location shows (`<API address>|<user id>`), so another account's sign-in replaces it.
    private static let keptAccountKey = "verso.drive.account"
    private static var itemFormatFile: URL { DriveCore.container.appendingPathComponent("item-format") }

    private(set) var isOn = DriveCore.isSwitchedOn
    /// Whether the location waits to be switched on in Finder or System Settings, as a new one does on the Mac, or was
    /// switched off in the Files app on iOS.
    private(set) var locationSwitchedOff = false
    private(set) var status = DriveCore.status
    private(set) var busy = false
    var error: String?

    /// The signed-in account, for the drive: the server, its credential, the user and their email.
    @ObservationIgnored private var account: (client: ImmichClient, user: User?)?
    @ObservationIgnored private var changes: Task<Void, Never>?
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    /// The last change to the location asked for (`inTurn`).
    @ObservationIgnored private var lastChange: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.hviid.Verso", category: "drive")

    var name: String { DriveCore.name }
    private var domain: NSFileProviderDomain { NSFileProviderDomain(identifier: Self.identifier, displayName: name) }

    /// The gallery signed in to an account: the drive takes it, and comes up when switched on.
    func start(client: ImmichClient, user: User?) {
        account = (client, user)
        inTurn { await self.bringUp() }
        guard changes == nil else { return }
        #if os(macOS)
        let cameToFront = NSApplication.didBecomeActiveNotification
        #else
        let cameToFront = UIApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: cameToFront, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VersoDrive.shared.signalSoon() }
        }
        changes = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.changeSignal)
                await self?.wake()
            }
        }
    }

    /// Switch the drive on or off, from Settings or the menu bar on the Mac, and the account's sheet on iOS.
    func setOn(_ on: Bool) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try DriveCore.set("mount.enabled", to: on ? "true" : "false")
            isOn = on
        } catch {
            self.error = error.localizedDescription
            return
        }
        await inTurn {
            if on {
                await self.bringUp()
            } else {
                do { try await self.takeDown() } catch { self.error = error.localizedDescription }
            }
        }.value
    }

    /// Sign-out and Remove Account: when the drive shows that account, its location goes with it.
    func accountRemoved(apiURL: URL, userID: String, credential: Credential?) async {
        guard UserDefaults.standard.string(forKey: Self.keptAccountKey) == Self.key(apiURL: apiURL, userID: userID) else { return }
        account = nil
        await inTurn {
            do { try await self.takeDown() } catch { self.error = error.localizedDescription }
        }.value
    }

    /// Bringing the location up and taking it down go one at a time, in the order asked: a switch-off made while a
    /// sign-in brings the location up takes it down after that, never before, so the location never outlives it.
    @discardableResult
    private func inTurn(_ change: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lastChange
        let next = Task { @MainActor in
            await previous?.value
            await change()
        }
        lastChange = next
        return next
    }

    /// The certificate trusted for the account's server changed (Trust This Certificate, Forget): the drive keeps it
    /// with its account, and its extension follows it as it next asks the server what changed.
    func certificateChanged() {
        inTurn { await self.bringUp() }
        signalSoon()
    }

    /// After changes made in the app, and as it comes to the front: Finder looks again soon.
    func signalSoon() {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isOn, self.account != nil else { return }
            try? await NSFileProviderManager(for: self.domain)?.signalEnumerator(for: .workingSet)
        }
    }

    /// One of the drive's settings changed in Settings: the extension follows it when the system lists everything
    /// again.
    func setPreference(_ key: String, to value: String) async {
        do {
            try DriveCore.set(key, to: value)
            try await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if os(macOS)
    func showInFinder() async {
        do {
            guard let manager = NSFileProviderManager(for: domain) else { return }
            let root = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            self.error = error.localizedDescription
        }
    }
    #else
    /// Open the Files app at the location, through the address Files takes for a folder it shows
    /// (`shareddocuments:` and the folder's path).
    func showInFiles() async {
        do {
            guard let manager = NSFileProviderManager(for: domain) else { return }
            let root = try await manager.getUserVisibleURL(for: .rootContainer)
            var address = URLComponents(url: root, resolvingAgainstBaseURL: false)
            address?.scheme = "shareddocuments"
            guard let url = address?.url, await UIApplication.shared.open(url) else {
                self.error = String(localized: "The Files app did not open. Verso Drive is in Files under Browse, by the app's name.")
                return
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The files in the location that have not reached Immich yet: the system's pending set, which holds what was
    /// copied into Upload until the extension has uploaded it. iOS keeps nothing of a removed location, so switching
    /// the drive off or signing out asks first while there are any. 0 when the drive is off, or the system does not
    /// say within a few seconds.
    func filesWaitingInUpload() async -> Int {
        guard isOn, account != nil, let manager = NSFileProviderManager(for: domain) else { return 0 }
        let enumerator = manager.enumeratorForPendingItems()
        defer { enumerator.invalidate() }
        return await PendingFiles(enumerator: enumerator).count()
    }
    #endif

    /// Read the extension's status and whether the location is switched on.
    func refreshState() async {
        status = DriveCore.status
        let location = try? await NSFileProviderManager.domains().first { $0.identifier == Self.identifier }
        locationSwitchedOff = location.map { !$0.userEnabled } ?? false
    }

    // MARK: The location

    /// When switched on and signed in: keep the account for the extension and add the location. Another account's
    /// location goes first, with what its extension kept.
    private func bringUp() async {
        guard isOn, let account, let credential = account.client.credential else { return }
        let (client, user) = account
        let key = Self.key(apiURL: client.apiURL, userID: user?.id ?? "")
        do {
            if let kept = UserDefaults.standard.string(forKey: Self.keptAccountKey), kept != key {
                try await takeDown()
            }
            let (apiKey, sessionToken): (String?, String?) = switch credential {
            case .apiKey(let apiKey): (apiKey, nil)
            case .accessToken(let token): (nil, token)
            }
            try DriveCore.keepAccount(server: client.serverURL.absoluteString, apiKey: apiKey, sessionToken: sessionToken,
                                      certificate: ServerTrust.certificate(for: client.apiURL), email: user?.email)
            UserDefaults.standard.set(key, forKey: Self.keptAccountKey)
            // Adding the location again updates it in place: its name follows `mount.name`, and its items stay.
            try await NSFileProviderManager.add(domain)
            await readItemsAgainAfterUpdate()
            await refreshState()
            log.notice("Verso Drive is up as \(self.name, privacy: .public)")
        } catch {
            self.error = error.localizedDescription
            log.error("Verso Drive did not come up: \(String(describing: error), privacy: .public)")
        }
    }

    /// Remove the location and what was downloaded. On the Mac what has not reached Immich is kept: a file moved into
    /// Upload is its only copy until it is uploaded (PRINCIPLES.md), and Finder shows where the system kept such files.
    /// iOS removes a location whole, so there the person is asked first (`filesWaitingInUpload`).
    private func takeDown() async throws {
        #if os(macOS)
        if let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData),
           Self.keptFiles(in: preserved) != 0 {
            NSWorkspace.shared.activateFileViewerSelecting([preserved])
        }
        #else
        _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
        #endif
        DriveCore.forgetAccount()
        UserDefaults.standard.removeObject(forKey: Self.keptAccountKey)
        locationSwitchedOff = false
        log.notice("Verso Drive is down")
    }

    /// Every ten seconds while the app runs: read the status, and wake the extension to ask the server what changed.
    private func wake() async {
        let wasOnline = status?.online
        await refreshState()
        guard isOn, account != nil, let manager = NSFileProviderManager(for: domain) else { return }
        // The extension answered "server unreachable" while it was; tell the system it may stop waiting.
        if wasOnline == false, status?.online == true {
            try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
        }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    /// Have the system read every item again when the bridge's item format changed since the last run, as Immich
    /// Mount's app does: the format is part of every item's version.
    private func readItemsAgainAfterUpdate() async {
        let format = DriveCore.currentItemFormat
        let kept = (try? String(contentsOf: Self.itemFormatFile, encoding: .utf8)).flatMap { UInt32($0) }
        guard kept != format else { return }
        if kept != nil { try? await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer) }
        try? String(format).write(to: Self.itemFormatFile, atomically: true, encoding: .utf8)
    }

    private static func key(apiURL: URL, userID: String) -> String { apiURL.absoluteString + "|" + userID }

    #if os(macOS)
    /// The files a removal kept: regular files only, hidden ones left out; nil when the folder cannot be read.
    private static func keptFiles(in folder: URL) -> Int? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .count
    }
    #endif
}

#if !os(macOS)
/// Counts the files of the system's pending set, page by page (`VersoDrive.filesWaitingInUpload`). Sendable by hand:
/// what changes is behind its lock, and the rest is set once.
private final class PendingFiles: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    /// How long the system may take to say; past it, the count is 0, as when it holds nothing.
    private static let patience: Duration = .seconds(5)

    private let enumerator: NSFileProviderPendingSetEnumerator
    private let state = OSAllocatedUnfairLock<(files: Int, done: CheckedContinuation<Int, Never>?)>(initialState: (0, nil))

    init(enumerator: NSFileProviderPendingSetEnumerator) {
        self.enumerator = enumerator
    }

    func count() async -> Int {
        await withCheckedContinuation { continuation in
            state.withLock { $0.done = continuation }
            enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
            Task {
                try? await Task.sleep(for: Self.patience)
                self.finish(counted: false)
            }
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        let files = updatedItems.filter { !(($0.contentType ?? nil)?.conforms(to: .folder) ?? false) }.count
        state.withLock { $0.files += files }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
        } else {
            finish(counted: true)
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        finish(counted: false)
    }

    /// Answer once: the count, or 0 when the system did not say.
    private func finish(counted: Bool) {
        let (files, done) = state.withLock { current in
            defer { current.done = nil }
            return (current.files, current.done)
        }
        done?.resume(returning: counted ? files : 0)
    }
}
#endif
