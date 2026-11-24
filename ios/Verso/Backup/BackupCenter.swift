// Backing up's place in the app (SPEC.md, "Backing the iPhone up"): the one engine, made at launch so the
// background session's answers and the background tasks find it, given the signed-in account's server (or, in a
// background launch without a window, the account the vault keeps), and its snapshot kept for the views on the main
// actor. It holds the person's actions (switching backing up on, Start, Back Up Now, the decisions on Not in Immich and
// In Immich in Another Form) and turns the engine's events into notifications: one in the account's notifications for
// each, and the system's while Verso is in the background, only when a run the person started ends or something needs
// them. No UIKit or SwiftUI here; the app delegate's part is BackupLaunch.swift.
//
// It also keeps what is on its way for the views (BackupOnItsWay): the new photos the Library shows among Immich's
// until they arrive (`libraryTiles`), each one that arrived kept until the Library's grid has Immich's photo in its
// place (a few minutes at most), a count of arrivals that makes the Library's grid read again as each upload lands (at
// most every two seconds, as an import makes it), and how far each upload on its way has gone, for the ring on its
// tile. The person's actions on a photo on its way are here too: its favourite set in Photos (and carried with the
// upload), and deleting it from the phone, which iOS asks about, after which it never uploads. And it tells which of
// Immich's photos came from photos still on the phone, so Save to Photos saves none twice.

import Foundation
import Observation
import Photos
import UserNotifications

@MainActor @Observable
final class BackupCenter {
    static let shared = BackupCenter()

    private(set) var snapshot = BackupSnapshot()
    private(set) var settings = BackupSettings.current
    /// Why the store could not be opened, if it could not.
    private(set) var unavailable: String?
    /// The person started Back Up Now or the first run's uploads, and it has not ended.
    private(set) var personRunActive = false
    /// Signed in to Immich's public demo, where backing up is not offered.
    private(set) var isPublicDemo = false
    /// The new photos on their way, and those that arrived since they were shown, for the Library's timeline.
    private(set) var libraryTiles: [BackupLibraryTile] = []
    /// Counts the moments the Library's grid should read again: an upload landed, or a run ended.
    private(set) var arrivals = 0
    /// How much of each photo's upload has gone, by its local identifier, while it uploads.
    private(set) var progress: [String: Double] = [:]
    /// The Backup page is open, over the tabs (LibraryTabs): every way to it (the Library's card and line, the account's
    /// row, a notification, a Live Activity) opens this one.
    var pageShown = false
    /// The Library's card that offers backing up, until it is switched on or the person says Not Now (this device's).
    private(set) var invitationDismissed = UserDefaults.standard.bool(forKey: invitationKey)
    private static let invitationKey = "backup.invitationDismissed"
    /// The Backup page opens on Free Up Space's review (the Library's card and line, the reminder).
    var reviewRequested = false
    /// The Backup page opens at Space on This iPhone (the Library's card for a phone short of space).
    var freeUpSectionRequested = false
    /// When the person last opened the review from the Library's card, or said Not Now, and what was ready then;
    /// and when they put aside the card for a phone short of space (this device's).
    private(set) var freeUpCardPutAside = BackupCenter.readPutAside()
    private(set) var spaceCardPutAside = BackupCenter.readSpacePutAside()
    private static let freeUpCardKey = "freeUp.cardPutAside"
    private static let freeUpCardBytesKey = "freeUp.cardPutAsideBytes"
    private static let spaceCardKey = "freeUp.spaceCardPutAside"

    @ObservationIgnored private(set) var engine: BackupEngine?
    @ObservationIgnored private(set) var store: BackupStore?
    @ObservationIgnored private(set) var transport: BackupTransport?
    @ObservationIgnored private weak var services: AccountServices?
    @ObservationIgnored private var observer: BackupLibraryObserver?
    @ObservationIgnored private var launched = false
    /// Verso is in the foreground.
    @ObservationIgnored private var active = false
    @ObservationIgnored private var tilesRefreshing = false
    @ObservationIgnored private var tilesAgain = false
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastArrival = Date.distantPast
    @ObservationIgnored private var arrivalPending = false

    private init() {}

    /// At launch: the store, the background session reconnected to the uploads it carries, and the engine.
    func launch() {
        guard !launched else { return }
        launched = true
        do {
            let store = try BackupStore(file: BackupStore.defaultFile())
            let transport = BackupTransport(store: store, identifier: BackupTransport.identifier(bundle: Bundle.main.bundleIdentifier ?? "dev.hviid.Verso"))
            let engine = BackupEngine(store: store, transport: transport)
            transport.onAnswer = { answer in
                Task { await engine.answered(answer) }
                if case .uploaded(_, true) = answer.outcome { Task { @MainActor in BackupCenter.shared.uploadLanded() } }
            }
            engine.network.onChange = { Task { await engine.networkChanged() } }
            transport.onEventsDelivered = { finish in Task { @MainActor in BackupScheduler.sessionWoke(finish) } }
            self.store = store
            self.transport = transport
            self.engine = engine
            Task {
                await engine.observe(snapshot: { snapshot in
                    Task { @MainActor in BackupCenter.shared.received(snapshot) }
                }, events: { event in
                    Task { @MainActor in BackupCenter.shared.handle(event) }
                })
            }
        } catch {
            unavailable = error.localizedDescription
        }
    }

    // MARK: The account

    /// Follows the app's account from launch, each change seen whatever the window draws: a sign-out right after the
    /// kept account was restored included.
    func follow(_ app: AppModel) {
        let services = withObservationTracking {
            app.services
        } onChange: {
            Task { @MainActor in BackupCenter.shared.follow(app) }
        }
        account(services)
    }

    /// The signed-in account, whose server backing up goes to; nil once signed out. Never Immich's public demo, where
    /// anyone could see what is sent.
    func account(_ services: AccountServices?) {
        // Signed out, backing up waits for its account to come back, also when the server ended the session, so it
        // never stops unnoticed (the Library's line asks to sign in again); another account's sign-in finds it off
        // until the person switches it on for that account. The uploads already on their way are called back as the
        // account signs out, which carry its credential: nothing is sent for an account signed out of, and each goes
        // again once it is back.
        let signedOut = self.services != nil && services == nil
        self.services = services
        if signedOut {
            Task {
                await engine?.cancelPass()
                await transport?.cancelAll()
            }
        }
        if let services, settings.isOn {
            let account = Self.accountKey(services)
            let kept = UserDefaults.standard.string(forKey: BackupSettings.Key.account)
            if kept == nil {
                UserDefaults.standard.set(account, forKey: BackupSettings.Key.account)
            } else if kept != account {
                Task { await setOn(false) }
            }
        }
        guard let engine else { return }
        isPublicDemo = services.map { Self.isPublicDemo($0.client.serverURL) } ?? false
        let server = isPublicDemo ? nil : services.map { ImmichBackupServer(client: $0.client, userID: $0.cacheUserID) }
        Task {
            await engine.setServer(server)
            if server != nil, settings.isOn { await engine.kick() }
        }
        watchLibrary(settings.isOn && services != nil)
    }

    /// An account as backing up keeps it: its server's API address and its user.
    private static func accountKey(_ services: AccountServices) -> String {
        services.client.apiURL.absoluteString + "|" + services.cacheUserID
    }

    /// Immich's public demo server, which anyone may sign in to and read.
    nonisolated static func isPublicDemo(_ server: URL) -> Bool {
        let host = server.host()?.lowercased() ?? ""
        return host == "demo.immich.app" || host.hasSuffix(".demo.immich.app")
    }

    /// In a background launch without a window: the account the vault keeps, so a background task can back up.
    func accountForBackground() async {
        guard let engine, await engine.account == nil, let saved = try? AccountVault.load(),
              !Self.isPublicDemo(saved.account.serverURL) else { return }
        let account = saved.account
        let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
        await engine.setServer(ImmichBackupServer(client: client, userID: saved.userID))
    }

    // MARK: Settings

    /// Back Up This iPhone: asks for the whole library first, and for notifications, which say when a run ends or
    /// something needs a look.
    func setOn(_ on: Bool) async {
        if on {
            var status = BackupLibrary.accessStatus
            if status == .notDetermined { status = await BackupLibrary.requestAccess() }
            await BackupNotifications.askOnce()
        }
        UserDefaults.standard.set(on, forKey: BackupSettings.Key.isOn)
        // Switched on once, the Library's card has done its part.
        if on { dismissInvitation() }
        if on, let services {
            UserDefaults.standard.set(Self.accountKey(services), forKey: BackupSettings.Key.account)
            // Photos that come to the phone from now on are new, and the Library shows them until they arrive.
            try? store?.markSwitchedOn(account: Self.accountKey(services))
        }
        settings = .current
        watchLibrary(on && services != nil)
        if on {
            // The first run's check goes on in the background too, with the system's progress, asked for before the
            // check starts, so Verso's own Live Activity never shows for a moment beside it.
            if services != nil, !snapshot.firstRunStarted, BackupLibrary.hasFullAccess, !isPublicDemo {
                BackupScheduler.submitContinued(title: "Checking with Immich")
            }
            await engine?.kick()
            BackupScheduler.scheduleOwnBackups()
        } else {
            await engine?.cancelPass()
            await transport?.cancelAll()
            BackupScheduler.cancelOwnBackups()
        }
        await refresh()
    }

    func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        settings = .current
        if key == BackupSettings.Key.onlyWhileCharging { BackupScheduler.scheduleOwnBackups() }
        if key == BackupSettings.Key.hiddenPhotos {
            store?.hiddenIncluded = value
            Task {
                await engine?.refreshFreeUp()
                await refresh()
            }
        }
        Task { await engine?.kick() }
    }

    /// The person granted the whole library in Settings, or came back from there.
    func libraryAccessMayHaveChanged() {
        settings = .current
        watchLibrary(settings.isOn && services != nil)
        Task {
            await engine?.kick()
            await refresh()
        }
    }

    // MARK: The person's actions

    /// Start on the first run's tally, as a run the system shows with its progress and its Stop.
    func startFirstRun() {
        personRunActive = true
        Task { await engine?.startFirstRun() }
        BackupScheduler.submitContinued(title: "Backing Up to Immich")
    }

    /// Opens the Backup page, from wherever Verso is.
    func showPage() {
        pageShown = true
    }

    /// The Library's card offers backing up: it is off, on this account's own server, and the person has not said Not
    /// Now.
    var invitationShown: Bool {
        !settings.isOn && services != nil && !isPublicDemo && !invitationDismissed
    }

    func dismissInvitation() {
        invitationDismissed = true
        UserDefaults.standard.set(true, forKey: Self.invitationKey)
    }

    /// Opens Free Up Space's review on the Backup page, from wherever Verso is.
    func showFreeUp() {
        reviewRequested = BackupSettings.current.keepMonths != nil
        pageShown = true
    }

    /// The Library's card for what is ready to free (FreeUpRules.cardShown): backing up on and past its first run, a
    /// period chosen, and a gigabyte or more ready.
    var freeUpCardShown: Bool {
        guard settings.isOn, settings.keepMonths != nil, snapshot.firstRunStarted, !isPublicDemo,
              let freeable = snapshot.freeable else { return false }
        return FreeUpRules.cardShown(bytes: freeable.bytes, putAside: freeUpCardPutAside)
    }

    /// The Library's card for a phone short of space while Keep on This iPhone is Forever (FreeUpRules.spaceCardShown).
    var spaceCardShown: Bool {
        guard settings.isOn, settings.keepMonths == nil, snapshot.firstRunStarted, !isPublicDemo,
              let offer = snapshot.spaceOffer else { return false }
        return FreeUpRules.spaceCardShown(bytes: offer.bytes, putAside: spaceCardPutAside)
    }

    /// Review or Not Now on the card for what is ready to free: it waits for the next month, or another gigabyte.
    func putAsideFreeUpCard() {
        let now = Date()
        let bytes = snapshot.freeable?.bytes ?? 0
        freeUpCardPutAside = (now, bytes)
        UserDefaults.standard.set(now, forKey: Self.freeUpCardKey)
        UserDefaults.standard.set(bytes, forKey: Self.freeUpCardBytesKey)
    }

    /// Free Up Space or Not Now on the card for a phone short of space: it waits three months.
    func putAsideSpaceCard() {
        let now = Date()
        spaceCardPutAside = now
        UserDefaults.standard.set(now, forKey: Self.spaceCardKey)
    }

    private static func readPutAside() -> (date: Date, bytes: Int64)? {
        guard !cardsAfresh, let date = UserDefaults.standard.object(forKey: freeUpCardKey) as? Date else { return nil }
        return (date, (UserDefaults.standard.object(forKey: freeUpCardBytesKey) as? Int64) ?? 0)
    }

    private static func readSpacePutAside() -> Date? {
        guard !cardsAfresh else { return nil }
        return UserDefaults.standard.object(forKey: spaceCardKey) as? Date
    }

    /// Verso Dev's walk (FreeUpSpaceWalkTests) sees the cards whatever an earlier run said to them.
    private static var cardsAfresh: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["VERSO_FREE_UP_CARDS_AFRESH"] != nil
        #else
        return false
        #endif
    }

    /// Check Again: every fingerprint Verso counts as in Immich asked of it now, as the weekly check does.
    func checkNow() {
        Task {
            await engine?.checkNow()
            await refresh()
        }
    }

    #if DEBUG
    /// Verso Dev's reset: backing up off, everything it knows on this device forgotten and its files removed, and the
    /// Library's card back, so the first run can be walked again from the start. Immich is not touched.
    func resetForWalk() async {
        await setOn(false)
        await transport?.cancelAll()
        await engine?.forgetEverything()
        UserDefaults.standard.removeObject(forKey: BackupSettings.Key.account)
        UserDefaults.standard.removeObject(forKey: Self.invitationKey)
        invitationDismissed = false
        for key in [Self.freeUpCardKey, Self.freeUpCardBytesKey, Self.spaceCardKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        freeUpCardPutAside = nil
        spaceCardPutAside = nil
        await refresh()
    }
    #endif

    // MARK: Free Up Space

    /// The person said yes to what deleting means for iCloud Photos and a Shared Library, once.
    var freeUpUnderstood: Bool { UserDefaults.standard.bool(forKey: BackupSettings.Key.freeUpUnderstood) }

    func understandFreeUp() {
        UserDefaults.standard.set(true, forKey: BackupSettings.Key.freeUpUnderstood)
    }

    /// Keep on This iPhone: a period in months, or nil for Forever.
    func setKeep(months: Int?) {
        if let months { UserDefaults.standard.set(months, forKey: BackupSettings.Key.keepMonths) }
        else { UserDefaults.standard.removeObject(forKey: BackupSettings.Key.keepMonths) }
        freeUpSettingsChanged()
    }

    func setKeepFavorites(_ keep: Bool) {
        UserDefaults.standard.set(keep, forKey: BackupSettings.Key.keepFavorites)
        freeUpSettingsChanged()
    }

    func setKeepHidden(_ keep: Bool) {
        UserDefaults.standard.set(keep, forKey: BackupSettings.Key.keepHidden)
        freeUpSettingsChanged()
    }

    /// The signed-in account's client, whose session the review unlocks with the account's PIN for hidden photos.
    var accountClient: ImmichClient? { services?.client }

    func setKeepAlbums(_ albums: [String]) {
        UserDefaults.standard.set(albums, forKey: BackupSettings.Key.keepAlbums)
        freeUpSettingsChanged()
    }

    private func freeUpSettingsChanged() {
        settings = .current
        Task {
            await engine?.refreshFreeUp()
            await refresh()
        }
    }

    func freeUpCandidates() async -> [FreeUpCandidate] {
        await engine?.freeUpCandidates() ?? []
    }

    func freeUpVerify(_ candidates: [FreeUpCandidate], readBorrowed: Bool,
                      progress: @escaping @Sendable (Int) -> Void) async -> [String: String] {
        guard let engine else {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.photo.localID, String(localized: "Backing up is not running")) })
        }
        return await engine.freeUpVerify(candidates, readBorrowed: readBorrowed, progress: progress)
    }

    enum FreeUpOutcome: Equatable {
        /// Moved to Recently Deleted: how many and their bytes, and the ProRAW photos left for Photos to delete.
        case deleted(count: Int, bytes: Int64, rawLeft: Int)
        /// The person said no to iOS's question: nothing changed.
        case declined
        case failed(String)
    }

    /// Deletes the photos from the phone, after iOS's own question: one request for them all, so one question;
    /// ProRAW photos in a request of their own, given 90 seconds, as an Apple bug can hang the delete of some 48 MP
    /// ProRAW photos. What went is watched for the 30 days Recently Deleted keeps it.
    func freeUp(_ candidates: [FreeUpCandidate]) async -> FreeUpOutcome {
        let regular = candidates.filter { !$0.isRaw }
        let raw = candidates.filter(\.isRaw)
        var deleted: [FreeUpCandidate] = []
        if !regular.isEmpty {
            switch await Self.delete(regular.map(\.photo.localID), within: nil) {
            case .done: deleted += regular
            case .declined: return .declined
            case .failed(let message): return .failed(message)
            case .timedOut: break
            }
        }
        var rawLeft = 0
        if !raw.isEmpty {
            switch await Self.delete(raw.map(\.photo.localID), within: 90) {
            case .done: deleted += raw
            case .declined where deleted.isEmpty: return .declined
            case .declined, .failed, .timedOut: rawLeft = raw.count
            }
        }
        await engine?.recordFreed(deleted)
        await refresh()
        return .deleted(count: deleted.count, bytes: deleted.reduce(0) { $0 + $1.size }, rawLeft: rawLeft)
    }

    fileprivate enum DeleteResult: Sendable { case done, declined, timedOut, failed(String) }

    private static func delete(_ identifiers: [String], within seconds: Double?) async -> DeleteResult {
        let answer = DeleteAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task {
                do {
                    try await PHPhotoLibrary.shared().performChanges(Self.deleting(identifiers))
                    answer.give(.done)
                } catch {
                    // Don't Allow on iOS's question: PhotoKit's "user cancelled" (3072).
                    let code = (error as NSError).code
                    answer.give(code == PHPhotosError.Code.userCancelled.rawValue || code == 3072 ? .declined
                                : .failed(error.localizedDescription))
                }
            }
            if let seconds {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    answer.give(.timedOut)
                }
            }
        }
    }

    /// The change that deletes these photos, made outside the main actor: PhotoKit runs it on a queue of its own, where
    /// a block that belonged to the main actor stops the app at Swift's isolation check.
    nonisolated private static func deleting(_ identifiers: [String]) -> @Sendable () -> Void {
        {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: BackupLibrary.fetchOptions(includingHidden: true))
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// The system's task for a run the person started ended, done or ended by iOS: Back Up Now is there again. What
    /// is left goes on by itself.
    func personRunEnded() {
        personRunActive = false
    }

    /// Back Up Now.
    func backUpNow() {
        personRunActive = true
        Task { await engine?.backUpNow() }
        BackupScheduler.submitContinued(title: "Backing Up to Immich")
    }

    func decide(_ identifiers: [String], _ decision: BackupDecision?) {
        Task {
            await engine?.decide(identifiers, decision)
            await refresh()
        }
    }

    func retry(_ identifiers: [String]) {
        Task {
            await engine?.retry(identifiers)
            await refresh()
        }
    }

    func answerMostGone(_ answer: BackupMostGoneAnswer) {
        Task { await engine?.answerMostGone(answer) }
    }

    func signedInAgain() {
        Task { await engine?.signedInAgain() }
    }

    func refresh() async {
        guard let engine else { return }
        received(await engine.snapshot())
    }

    // MARK: The foreground

    /// Verso came to the foreground or left it: coming forward, the library is read again and its new photos go at
    /// once, while Verso is open.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        Task {
            await engine?.setForeground(active)
            if active { await refresh() }
        }
        followProgress()
    }

    #if DEBUG
    /// Verso Dev's walk holds uploads for a while, so photos on their way can be seen before they arrive.
    func holdUploads(for seconds: TimeInterval) {
        Task { await engine?.hold(for: seconds) }
    }
    #endif

    // MARK: On its way

    /// The photos on their way, newest first, a page at a time, for On Its Way on the Backup page.
    func waitingPhotos(limit: Int, offset: Int = 0) async -> [BackupWaitingPhoto] {
        guard let store, let account = await engine?.account else { return [] }
        return (try? store.waitingPhotos(account: account, onlyNew: false, screenshots: settings.screenshots,
                                         limit: limit, offset: offset)) ?? []
    }

    /// How many photos are on their way: those that go and those that need a look.
    var waitingCount: Int { snapshot.going + snapshot.tally.needsLook }

    /// A photo's mark on its tile, from its state, what the connection allows and how far its upload has gone.
    func mark(_ photo: BackupWaitingPhoto) -> BackupTileMark {
        var stopped = false
        if case .stopped = snapshot.phase { stopped = true }
        let connection = BackupConnection(connected: snapshot.connected, onCellular: snapshot.onCellular,
                                          constrained: snapshot.constrained, cellularPhotos: settings.cellularPhotos,
                                          cellularVideos: settings.cellularVideos)
        return BackupOnItsWay.mark(photo, progress: progress[photo.localID], connection: connection, stopped: stopped)
    }

    /// The Library's new photos read again: those still on their way, and those of them that arrived, each with the
    /// asset Immich made, until the Library's grid has it (a few minutes at most).
    private func refreshTiles() async {
        if tilesRefreshing { tilesAgain = true; return }
        tilesRefreshing = true
        defer { tilesRefreshing = false }
        repeat {
            tilesAgain = false
            await readTiles()
        } while tilesAgain
    }

    private func readTiles() async {
        guard let store, let account = await engine?.account, settings.isOn, !isPublicDemo, BackupLibrary.hasFullAccess,
              let fresh = try? store.waitingPhotos(account: account, onlyNew: true, screenshots: settings.screenshots, limit: 500)
        else {
            if !libraryTiles.isEmpty { libraryTiles = [] }
            return
        }
        let freshIDs = Set(fresh.map(\.localID))
        let now = Date()
        var arrived = libraryTiles.filter { $0.arrivedAsset != nil && now.timeIntervalSince($0.arrivedAt ?? now) < 300
            && !freshIDs.contains($0.photo.localID) }
        // Shown before, and on their way no longer: in Immich now, if Verso uploaded them.
        let left = libraryTiles.filter { $0.arrivedAsset == nil && !freshIDs.contains($0.photo.localID) }.map(\.photo)
        if !left.isEmpty, let assets = try? store.arrivedAssets(account: account, left.map(\.localID)), !assets.isEmpty {
            for photo in left {
                if let asset = assets[photo.localID] {
                    arrived.append(BackupLibraryTile(photo: photo, arrivedAsset: asset, arrivedAt: now))
                }
            }
            noteArrival()
        }
        let tiles = fresh.map { BackupLibraryTile(photo: $0) } + arrived
        if tiles != libraryTiles { libraryTiles = tiles }
    }

    /// An upload landed: the Library's photos on their way are read again first, so a tile that arrived is known as
    /// such before the grid has Immich's photo for it, then the grid reads again.
    private func uploadLanded() {
        Task {
            await refreshTiles()
            noteArrival()
        }
    }

    /// The Library's grid reads again now, or two seconds after it last did, so a backlog's uploads redraw it every two
    /// seconds rather than for every photo.
    private func noteArrival() {
        let wait = 2 - Date().timeIntervalSince(lastArrival)
        guard wait > 0 else {
            lastArrival = Date()
            arrivals += 1
            return
        }
        guard !arrivalPending else { return }
        arrivalPending = true
        Task {
            try? await Task.sleep(for: .seconds(wait))
            arrivalPending = false
            lastArrival = Date()
            arrivals += 1
        }
    }

    /// Follows how far the uploads on their way have gone while Verso is open, twice a second.
    private func followProgress() {
        guard active, snapshot.onTheirWay > 0, settings.isOn else {
            progressTask?.cancel()
            progressTask = nil
            if !progress.isEmpty { progress = [:] }
            return
        }
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readProgress()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func readProgress() {
        guard let store, let transport, let account = services.map(Self.accountKey) else { return }
        let sent = transport.progress()
        var parts: [String: [Double]] = [:]
        for upload in (try? store.openUploads(account: account)) ?? [] {
            parts[upload.localID, default: []].append(sent[upload.step] ?? 0)
        }
        let fresh = parts.mapValues { $0.reduce(0, +) / Double($0.count) }
        if fresh != progress { progress = fresh }
    }

    // MARK: The person's actions on a photo on its way

    /// Favourite in Photos, which the upload carries to Immich as `isFavorite` (and, where its body went already, the
    /// step that finishes it). False when the change did not happen.
    func setFavorite(_ identifiers: [String], _ favorite: Bool) async -> Bool {
        guard await BackupPhoneChanges.setFavorite(identifiers, favorite) else { return false }
        for identifier in identifiers { try? store?.setFavorite(identifier, favorite) }
        libraryTiles = libraryTiles.map { tile in
            var tile = tile
            if identifiers.contains(tile.photo.localID) { tile.photo.favorite = favorite }
            return tile
        }
        return true
    }

    /// Deletes photos from the phone, which iOS asks about; once deleted they never upload, and an upload on its way is
    /// cancelled. False when iOS was told no, or the deletion failed.
    func deleteFromPhone(_ identifiers: [String]) async -> Bool {
        guard await BackupPhoneChanges.delete(identifiers) else { return false }
        libraryTiles.removeAll { identifiers.contains($0.photo.localID) }
        await engine?.forget(identifiers)
        await refresh()
        return true
    }

    // MARK: Photos from Immich

    /// Of these Immich assets, those that came from photos still in this phone's library, each with the photo's local
    /// identifier, as backing up's store knows them: Save to Photos saves none of them a second time.
    func photosOnPhone(_ assets: [String]) async -> [String: String] {
        guard !assets.isEmpty, let store, let account = await engine?.account,
              let found = try? store.phonePhotos(account: account, assets: assets) else { return [:] }
        return found.filter { BackupLibrary.asset($0.value) != nil }
    }

    // MARK: Lists for the Backup page

    /// Photos in these states, newest first, a page at a time.
    func identifiers(in states: [BackupPhotoState], limit: Int = 200, offset: Int = 0) async -> [String] {
        guard let store, let account = await engine?.account else { return [] }
        return (try? store.identifiers(account: account, in: states, limit: limit, offset: offset,
                                       screenshots: settings.screenshots)) ?? []
    }

    func reason(_ identifier: String) async -> String? {
        guard let store, let account = await engine?.account else { return nil }
        return try? store.reason(account: account, identifier)
    }

    /// What a photo still to check or to upload waits for, in the person's words, with when it is tried again: a part
    /// put off (a retry, a download's turn, room, Wi-Fi), a part not read yet, or a Live Photo's still after its video.
    func waitingReason(_ identifier: String) async -> String? {
        guard let store, let parts = try? store.parts(identifier) else { return nil }
        let now = Date()
        for part in parts {
            guard let retry = part.retryAfter, retry > now else { continue }
            let time = retry.formatted(date: .omitted, time: .shortened)
            return part.waitReason.map { String(localized: "\($0), trying again at \(time)") }
                ?? String(localized: "Trying again at \(time)")
        }
        if parts.contains(where: { $0.checksum == nil }) { return String(localized: "Waiting its turn to be read") }
        if parts.contains(where: { $0.role == .originalPair }) { return String(localized: "Its video goes first, then the photo") }
        return nil
    }

    func anotherFormAsset(_ identifier: String) async -> String? {
        guard let store, let account = await engine?.account else { return nil }
        return try? store.anotherFormAsset(account: account, identifier)
    }

    // MARK: Snapshots and events

    private func received(_ snapshot: BackupSnapshot) {
        var snapshot = snapshot
        if isPublicDemo { snapshot.phase = .publicDemo }
        self.snapshot = snapshot
        BackupScheduler.reportProgress(snapshot)
        BackupLiveActivity.follow(snapshot, foreground: active, systemShowsRun: BackupScheduler.isContinuing)
        followProgress()
        Task { await refreshTiles() }
    }

    private func handle(_ event: BackupEvent) {
        let notification: VersoNotification
        switch event {
        case .freeUpReady(let count, let bytes, let months):
            let size = bytes.formatted(.byteCount(style: .file))
            notification = VersoNotification(title: String(localized: "Free up \(size) on this \(DeviceWords.model)"),
                                             detail: String(localized: "\(count.formatted()) photos and videos older than \(FreeUpPeriod.phrase(months)) are safe in Immich. Review them to free the space."),
                                             needsLook: false)
        case .freedMissing(let count, let until):
            notification = VersoNotification(title: count == 1 ? String(localized: "A photo you freed is not in Immich")
                                                 : String(localized: "\(count.formatted()) photos you freed are not in Immich"),
                                             detail: String(localized: "Bring them back from Recently Deleted in Photos before \(until.formatted(date: .abbreviated, time: .omitted))."),
                                             needsLook: true)
        case .readyToStart(let toUpload, let bytes, let inImmich, let toCheck):
            let size = bytes.formatted(.byteCount(style: .file))
            var detail = toUpload == 0 ? "Nothing to upload yet." : toUpload == 1 ? "1 item, \(size), to upload." : "\(toUpload.formatted()) items, \(size), to upload."
            detail += inImmich == 1 ? " 1 is already in Immich." : " \(inImmich.formatted()) are already in Immich."
            if toCheck > 0 { detail += " \(toCheck.formatted()) more are checked once it starts." }
            notification = VersoNotification(title: "Ready to back up", detail: detail, needsLook: false)
        case .runEnded(let uploaded):
            personRunActive = false
            // What the run sent shows in the Library.
            if uploaded > 0 { noteArrival() }
            BackupScheduler.finishContinued(success: true)
            let title = uploaded == 0 ? "Backup is up to date" : uploaded == 1 ? "Backed up 1 item" : "Backed up \(uploaded) items"
            notification = VersoNotification(title: title, detail: snapshot.tally.needsLook > 0
                                             ? "\(snapshot.tally.needsLook) need a look on the Backup page." : nil,
                                             needsLook: snapshot.tally.needsLook > 0)
        case .missing(let count):
            notification = VersoNotification(title: count == 1 ? "1 photo is missing from Immich" : "\(count) photos are missing from Immich",
                                             detail: "Verso backed them up, and they are gone from your server. Send them again or let them go on the Backup page.",
                                             needsLook: true)
        case .mostGone(let gone, let total):
            personRunActive = false
            BackupScheduler.finishContinued(success: false)
            notification = VersoNotification(title: "Backing up stopped",
                                             detail: "\(gone) of the \(total) photos Verso backed up are gone from Immich at once, which looks like a problem with the server rather than deletions. Nothing changes until you answer on the Backup page.",
                                             needsLook: true)
        case .serverFull:
            personRunActive = false
            BackupScheduler.finishContinued(success: false)
            notification = VersoNotification(title: "Your Immich server is full",
                                             detail: "Backing up stopped. Verso tries again each day.", needsLook: true)
        case .signInAgain:
            personRunActive = false
            BackupScheduler.finishContinued(success: false)
            notification = VersoNotification(title: "Sign in again to back up",
                                             detail: "Your Immich server no longer accepts this sign-in.", needsLook: true)
        case .unreachable(let until, let reason):
            personRunActive = false
            BackupScheduler.finishContinued(success: false)
            let when = until.map { "at \($0.formatted(date: .omitted, time: .shortened))" } ?? "soon"
            notification = VersoNotification(title: "Backing up paused",
                                             detail: "Immich can't be reached (\(reason)). Verso tries again \(when), and when the connection changes.",
                                             needsLook: false)
        case .notAllowed(let reason):
            personRunActive = false
            BackupScheduler.finishContinued(success: false)
            notification = VersoNotification(title: "Immich doesn't let Verso upload",
                                             detail: "Backing up stopped: \(reason). Try again on the Backup page once it is put right.",
                                             needsLook: true)
        }
        services?.versoNotifications.add(notification)
        Task { await BackupNotifications.post(notification, kind: event) }
    }

    // MARK: The library while Verso is open

    private func watchLibrary(_ watching: Bool) {
        if watching, observer == nil, BackupLibrary.hasFullAccess, let engine {
            observer = BackupLibraryObserver(engine: engine)
        } else if !watching, let observer {
            observer.stop()
            self.observer = nil
        }
    }
}

/// A photo on its way in the Library's timeline, or one that arrived, with the asset Immich made for it, which takes
/// its place once the Library's grid has it.
struct BackupLibraryTile: Equatable, Identifiable {
    var photo: BackupWaitingPhoto
    var arrivedAsset: String?
    var arrivedAt: Date?

    var id: String { photo.localID }
}

/// New photos seen at once while Verso is open: a change to the library starts a pass, which reads what changed and
/// sends the new photos first.
final class BackupLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let engine: BackupEngine

    init(engine: BackupEngine) {
        self.engine = engine
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func stop() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { await engine.photosChanged() }
    }
}

/// The person's changes to photos on the phone, made through PhotoKit, whose change blocks run on its own queue, away
/// from the main actor. Whether each happened: iOS asks before deleting, and the person may say no.
enum BackupPhoneChanges {
    nonisolated static func setFavorite(_ identifiers: [String], _ favorite: Bool) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers,
                                                 options: BackupLibrary.fetchOptions(includingHidden: true))
                assets.enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isFavorite = favorite }
            }
            return true
        } catch {
            return false
        }
    }

    nonisolated static func delete(_ identifiers: [String]) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers,
                                                 options: BackupLibrary.fetchOptions(includingHidden: true))
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }
}

/// The system's notifications about backing up, asked for when it is switched on.
enum BackupNotifications {
    static func askOnce() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Shown by the system while Verso is in the background; in the foreground the account's notifications have it.
    static func post(_ notification: VersoNotification, kind: BackupEvent) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let detail = notification.detail { content.body = detail }
        content.sound = .default
        let identifier = switch kind {
        case .runEnded: "backup-ended"
        case .missing: "backup-missing"
        case .mostGone: "backup-stopped"
        case .serverFull: "backup-full"
        case .signInAgain: "backup-sign-in"
        case .notAllowed: "backup-not-allowed"
        case .unreachable: "backup-paused"
        case .readyToStart: "backup-ready"
        case .freeUpReady: freeUpIdentifier
        case .freedMissing: "backup-freed-missing"
        }
        // Ready to back up offers Start Backup beside opening the Backup page (BackupLaunch, the notifications' delegate).
        if case .readyToStart = kind { content.categoryIdentifier = readyCategory }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static let readyCategory = "backup-ready"
    /// Free Up Space's reminder, which opens its review.
    static let freeUpIdentifier = "backup-free-up"
    static let startAction = "start"

    /// The categories backing up's notifications use: Ready to back up's Start Backup, which opens Verso and starts.
    static func registerCategories() {
        let start = UNNotificationAction(identifier: startAction, title: String(localized: "Start Backup"), options: [.foreground])
        let ready = UNNotificationCategory(identifier: readyCategory, actions: [start], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([ready])
    }

    /// Whether a notification is backing up's, which opens the Backup page.
    static func isBackup(_ identifier: String) -> Bool { identifier.hasPrefix("backup-") }
}

/// A delete's answer, given once: iOS's, or the time limit's.
private final class DeleteAnswer: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<BackupCenter.DeleteResult, Never>?
    private var answered = false

    func give(_ value: BackupCenter.DeleteResult) {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        answered = true
        let continuation = self.continuation
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Keep on This iPhone's periods in words: "1 Month", "6 Months", "1 Year", and in a sentence, "6 months", "a year".
enum FreeUpPeriod {
    static func name(_ months: Int) -> String {
        switch months {
        case 12: String(localized: "1 Year")
        case 24: String(localized: "2 Years")
        case 1: String(localized: "1 Month")
        default: String(localized: "\(months) Months")
        }
    }

    static func phrase(_ months: Int) -> String {
        switch months {
        case 12: String(localized: "a year")
        case 24: String(localized: "2 years")
        case 1: String(localized: "a month")
        default: String(localized: "\(months) months")
        }
    }
}
