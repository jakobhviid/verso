// Backing the iPhone up (ROADMAP.md, M10, "Backing the iPhone up"): the engine, platform-neutral Swift with no UIKit or
// SwiftUI, over the store (BackupStore), PhotoKit (BackupLibrary), the server (BackupServer) and the transport
// (BackupTransport). Two promises lead it: no photo is lost, and none is uploaded twice.
//
// A pass, run when backing up is switched on, at launch, when Verso comes to the foreground, when the library changes
// while Verso is open, and in the background time the system grants (BackupScheduler):
// 1. Recovery, once per launch: every journal step without a result is worked out again from facts (BackupRecovery),
//    and the sweep removes upload bodies and downloads nothing uses.
// 2. The library read into the store (BackupDiscovery): the first listing, then the changes since the token; read
//    again within the pass when Verso comes to the foreground or the library changes, which cuts the backlog's work
//    short.
// 3. Rounds until nothing is left, each beginning with the new photos (those that came to the phone after backing up
//    was switched on, BackupOnItsWay): their parts read, fingerprinted, checked with Immich and sent at once, through
//    the app's own session while Verso is open, before any backlog and whatever is already on its way. Then the rest:
//    each photo's parts read; fingerprints taken, newest first (an original only in
//    iCloud downloaded once, into the file it is uploaded from); the duplicate check, 500 at a time, before anything
//    goes; each photo's state worked out (BackupRules); the first run's photos that are in Immich by no fingerprint
//    looked for in another form, by the same second and name; uploads topped up; backed-up photos finished (their
//    stack, and the metadata Photos has where the file differs).
// 4. The weekly check of what Verso counts as in Immich (Not in Immich), and the stop when most of it is gone at once.
//
// Uploading starts only once the person said Start on the first run's tally. Uploads go in batches of up to 100, topped
// up when fewer than 20 are on their way, each body written within the disk budget (BackupDiskBudget).

import CoreLocation
import Foundation
import Network
import Photos
import UniformTypeIdentifiers

/// What the views show, as one value the engine sends after each step.
struct BackupSnapshot: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case off
        case noAccess
        case signedOut
        /// The first listing, with the photos read so far.
        case reading(Int)
        case checking
        case waitingForStart
        case backingUp
        case upToDate
        case stopped(BackupStop)
        /// Signed in to Immich's public demo, where anyone sees what is sent: backing up is not offered there.
        case publicDemo
    }
    var phase: Phase = .off
    var tally = BackupTally()
    /// Uploads on their way, by part.
    var onTheirWay = 0
    /// Photos that go: those to upload, and new ones not checked yet (BackupStore.goingCount).
    var going = 0
    var firstRunStarted = false
    var onCellular = false
    /// Low Data Mode, which backing up respects.
    var constrained = false
    var connected = true
    var lastChecked: Date?
    var mostGone: (gone: Int, of: Int)?
    /// Why backing up stopped, where the stop has a reason: Immich's refusal, or the outage's last failure.
    var stopReason: String?
    /// Until when an outage pauses backing up.
    var pausedUntil: Date?
    /// Since when the passes have not reached Immich, which is waited for rather than said as an error.
    var immichOutOfReachSince: Date?
    /// The free space a file waits for on this device, with nothing else held.
    var needsSpace: Int64?
    /// When what waits is tried again, while no pass runs and something is still to check or to upload.
    var nextRetry: Date?
    /// The photos Verso itself uploaded something of.
    var sentByVerso = 0
    /// Screenshots left out while the Screenshots setting is off.
    var screenshotsLeftOut = 0
    /// Verso Dev: fingerprints borrowed from Immich by the iCloud identifier its own app keeps (BackupMobileApp).
    var borrowedFingerprints = 0
    /// What Free Up Space can remove now, once a period is chosen: how many photos, and their originals' bytes.
    var freeable: (count: Int, bytes: Int64)?
    /// While Keep on This iPhone is Forever and the phone runs short of space: what keeping a year would free.
    var spaceOffer: (count: Int, bytes: Int64)?
    /// An error that has lasted an hour, other than Immich out of reach.
    var error: String?

    static func == (left: BackupSnapshot, right: BackupSnapshot) -> Bool {
        left.phase == right.phase && left.tally == right.tally && left.onTheirWay == right.onTheirWay && left.going == right.going
            && left.firstRunStarted == right.firstRunStarted && left.onCellular == right.onCellular
            && left.connected == right.connected && left.constrained == right.constrained && left.lastChecked == right.lastChecked
            && left.mostGone?.gone == right.mostGone?.gone && left.mostGone?.of == right.mostGone?.of
            && left.stopReason == right.stopReason && left.pausedUntil == right.pausedUntil
            && left.immichOutOfReachSince == right.immichOutOfReachSince && left.needsSpace == right.needsSpace
            && left.nextRetry == right.nextRetry
            && left.sentByVerso == right.sentByVerso && left.screenshotsLeftOut == right.screenshotsLeftOut
            && left.borrowedFingerprints == right.borrowedFingerprints
            && left.freeable?.count == right.freeable?.count && left.freeable?.bytes == right.freeable?.bytes
            && left.spaceOffer?.count == right.spaceOffer?.count && left.spaceOffer?.bytes == right.spaceOffer?.bytes
            && left.error == right.error
    }
}

/// Why backing up stopped, until it is answered or tried again.
enum BackupStop: String, Sendable, Equatable {
    /// Immich refused the credential: the person signs in again.
    case unauthorized
    /// Immich, or a proxy in front of it, does not let this sign-in upload (a 403, with its reason): until the person
    /// tries again or signs in again.
    case notAllowed
    /// Uploads failed again and again with none landing: a pause, until its time is up, the network changes or the
    /// person tries again (BackupOutage).
    case unreachable
    /// The server is full: tried again daily.
    case full
    /// Most of what was in Immich is gone at once: a server's problem, not deletions; nothing happens until the
    /// person answers.
    case mostGone
}

/// What the person hears of, as a notification and in the account's notifications.
enum BackupEvent: Sendable, Equatable {
    /// A run the person started ended: how many photos went.
    case runEnded(uploaded: Int)
    /// Photos that were in Immich are missing from it, said once for the batch.
    case missing(Int)
    case mostGone(gone: Int, of: Int)
    case serverFull
    case signInAgain
    /// Immich does not let this sign-in upload: its reason.
    case notAllowed(String)
    /// A run the person started paused, as Immich cannot be reached: until when, and why.
    case unreachable(until: Date?, reason: String)
    /// The first run's check did what it can before Start: what goes, its size, what Immich has, and what is left to
    /// check (iCloud originals waiting for room, which Start makes).
    case readyToStart(toUpload: Int, bytes: Int64, inImmich: Int, toCheck: Int)
    /// Free Up Space has real space to gain: how many photos and how many bytes (at most once a month).
    case freeUpReady(count: Int, bytes: Int64, months: Int)
    /// Photos the person freed are not in Immich any more, while Recently Deleted can still bring them back.
    case freedMissing(count: Int, until: Date)
}

/// The person's answer to "most of the library is gone".
enum BackupMostGoneAnswer: Sendable {
    case checkAgain
    case deleted
    case sendAgain
}

/// Whether the device is on Wi-Fi, cellular or nothing, as the settings decide what may go.
final class BackupNetwork: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    var onChange: @Sendable () -> Void = {}

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            let changed = self.path?.isExpensive != path.isExpensive || self.path?.status != path.status
                || self.path?.isConstrained != path.isConstrained
            self.path = path
            lock.unlock()
            if changed { onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "Backup network"))
    }

    var connected: Bool { lock.withLock { path?.status != .unsatisfied } }
    /// On cellular, or another connection the system counts as expensive.
    var onCellular: Bool { lock.withLock { path?.isExpensive == true } }
    var constrained: Bool { lock.withLock { path?.isConstrained == true } }
}

actor BackupEngine {
    let store: BackupStore
    let transport: any BackupSending
    let files: BackupFiles
    let network: BackupNetwork
    private var server: (any BackupServer)?
    /// Counts setServer's calls, so one that waited for a pass to end never undoes a later one.
    private var serverChanges = 0
    private var settings = BackupSettings()
    private var pass: Task<Void, Never>?
    private var passAgain = false
    /// The pass tops the uploads up before anything else (`topUpFirst`).
    private var wokenForAnswers = false
    #if DEBUG
    private var wroteLaunchDiagnostics = false
    #endif
    private var recovered = false
    private var reading: Int?
    private var lastError: String?
    /// When the errors of passes in a row began, and whether the last was Immich out of reach, which is waited for
    /// calmly; another is said only once it has lasted an hour, as most pass by themselves.
    private var lastErrorSince: Date?
    private var lastErrorReach = false
    /// The server's timeline months and the photos in each, read once per launch for the another-form look.
    private var months: Set<String>?
    private var monthPhotos: [String: [BackupAnotherForm.Remote]] = [:]
    /// Photos whose finishing waits for Immich to read their metadata, until then.
    private var finishLater: [String: Date] = [:]
    /// A run the person started, with the uploads it has made.
    private var personRun: Int?
    /// Verso is open: new photos go through the app's own session, at once.
    private var foreground = false
    /// The library changed, or Verso came to the foreground, since the pass last read it.
    private var libraryChanged = false
    /// Uploads wait until then: Verso Dev's walk holds them, to see photos on their way (BackupCenter).
    private var holdUntil: Date?
    private var lastSnapshot = BackupSnapshot()
    private var snapshotPending = false
    private var onSnapshot: @Sendable (BackupSnapshot) -> Void = { _ in }
    private var onEvent: @Sendable (BackupEvent) -> Void = { _ in }

    init(store: BackupStore, transport: any BackupSending, files: BackupFiles = .standard, network: BackupNetwork = BackupNetwork()) {
        self.store = store
        self.transport = transport
        self.files = files
        self.network = network
        files.prepare()
    }

    func observe(snapshot: @escaping @Sendable (BackupSnapshot) -> Void, events: @escaping @Sendable (BackupEvent) -> Void) {
        onSnapshot = snapshot
        onEvent = events
        publishNow()
    }

    /// The signed-in account's server, or none once signed out. Another account's pass ends first: it never sees this
    /// server, and the kick that follows starts a pass of this account's own rather than landing on the one ending.
    func setServer(_ server: (any BackupServer)?) async {
        serverChanges += 1
        let change = serverChanges
        if self.server?.account != server?.account {
            if let ending = pass {
                ending.cancel()
                await ending.value
                // Another change came while this one waited: the later one holds.
                guard change == serverChanges else { return }
            }
            months = nil
            monthPhotos = [:]
            recovered = false
        }
        self.server = server
        publish()
    }

    var account: String? { server?.account }

    // MARK: Passes

    /// Starts a pass, or runs another once the one under way ends.
    func kick() {
        if pass != nil { passAgain = true; return }
        pass = Task { await runPasses() }
    }

    /// Runs passes until one ends with nothing new asked for; returns when done, or when cancelled.
    func runUntilDone() async {
        kick()
        while let pass { await pass.value }
    }

    func cancelPass() {
        pass?.cancel()
    }

    /// Returns once no pass is under way, without starting one.
    func passesEnded() async {
        while let pass { await pass.value }
    }

    /// Verso came to the foreground or went to the background. Coming forward, the library is read again and new photos
    /// go at once; going back, what was sent at once is cancelled, to go again through the background session.
    func setForeground(_ active: Bool) async {
        guard active != foreground else { return }
        foreground = active
        if active {
            photosChanged()
        } else {
            await transport.cancelFast()
        }
    }

    /// A wake-up for the background session's answers: the next round of a pass tops the uploads up before its other
    /// work, so the session has them before Verso is suspended again (BackupScheduler.sessionWoke).
    func topUpFirst() {
        wokenForAnswers = true
    }

    /// The device's connection changed: an outage's pause ends, as Immich may be in reach again (a server at home, and
    /// the phone home), and a pass goes.
    func networkChanged() {
        if let account { try? BackupOutage.lift(store: store, account: account) }
        kick()
    }

    /// The library changed while Verso is open: a pass reads it at once, and its new photos go first.
    func photosChanged() {
        libraryChanged = true
        kick()
    }

    /// Holds uploads for a while (Verso Dev's walk), and goes on after.
    func hold(for seconds: TimeInterval) {
        holdUntil = Date().addingTimeInterval(seconds)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            kick()
        }
    }

    private var holding: Bool { holdUntil.map { Date() < $0 } ?? false }

    /// Photos the person deleted from the phone in Verso: they never upload, and an upload on its way is cancelled.
    func forget(_ identifiers: [String]) async {
        try? store.markGone(identifiers)
        guard let account else { return }
        let steps = ((try? store.openUploads(account: account)) ?? []).filter { identifiers.contains($0.localID) }
        await transport.cancel(steps: Set(steps.map(\.step)))
        publish()
    }

    /// A pass is under way.
    var isRunning: Bool { pass != nil }

    private func runPasses() async {
        repeat {
            passAgain = false
            await runPass()
        } while passAgain && !Task.isCancelled
        pass = nil
        if !Task.isCancelled { scheduleWake() }
        publishNow()
    }

    /// A pass of its own when what waits is due: the soonest part put off (a retry, a download's turn), an outage's
    /// pause ending, a photo's finishing tried again. While Verso runs; suspended, the system's background runs take
    /// over (BackupScheduler).
    private var wake: Task<Void, Never>?

    private func scheduleWake() {
        wake?.cancel()
        wake = nil
        guard let account else { return }
        var due: [Date] = finishLater.values.map { $0 }
        if let next = try? store.nextRetry(account: account) { due.append(next) }
        if let until = try? BackupOutage.pausedUntil(store: store, account: account) { due.append(until) }
        guard let soonest = due.min() else { return }
        let seconds = max(1, soonest.timeIntervalSinceNow + 1)
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    private func runPass() async {
        settings = .current
        store.hiddenIncluded = settings.hiddenPhotos
        guard settings.isOn, let server else { publishNow(); return }
        guard BackupLibrary.hasFullAccess else { publishNow(); return }
        let account = server.account
        do {
            #if DEBUG
            // Verso Dev: what backing up found at launch, before this pass changes anything.
            if !wroteLaunchDiagnostics {
                wroteLaunchDiagnostics = true
                BackupDiagnostics.write(store: store, account: account, snapshot: makeSnapshot(), note: "at launch", launch: true)
            }
            #endif
            if !recovered { try await recover(account: account) }
            sweepStaged(account: account)
            // The free space a file waited for is there now: the page stops asking for it.
            if let needed = try store.meta("needsSpace").flatMap({ Int64($0) }), files.freeBytes() >= needed {
                try store.setMeta("needsSpace", nil)
            }
            libraryChanged = false
            try await discover()
            try store.ensureBackupRows(account: account)
            while !Task.isCancelled {
                if wokenForAnswers {
                    wokenForAnswers = false
                    try await planUploads(account: account)
                }
                if libraryChanged {
                    libraryChanged = false
                    try await discover()
                    try store.ensureBackupRows(account: account)
                }
                var worked = try await sendNewFirst(account: account)
                worked = try await readParts() || worked
                worked = try await fingerprint() || worked
                worked = try await checkWithServer(account: account) || worked
                worked = try refreshReady(account: account) || worked
                worked = try await lookForAnotherForm(account: account) || worked
                try await planUploads(account: account)
                worked = try await finishPhotos(account: account) || worked
                publish()
                if !worked { break }
            }
            try await verifyIfDue(account: account)
            try await watchFreed(account: account)
            await refreshFreeUp()
            try await planUploads(account: account)
            lastError = nil
            lastErrorSince = nil
            // Everything that could be done now is done: a run the person started may have ended, and the first run's
            // check may be ready for Start.
            if !Task.isCancelled {
                endPersonRunIfDone(account: account)
                try sayReadyToStart(account: account)
            }
        } catch is CancellationError {
        } catch let error as PHPhotosError where error.code == .accessUserDenied || error.code == .accessRestricted {
            lastError = BackupError.noLibraryAccess.localizedDescription
        } catch ImmichError.unauthorized {
            try? store.setMeta("stop.\(account)", BackupStop.unauthorized.rawValue)
            onEvent(.signInAgain)
        } catch ImmichError.http(403, let message) {
            let reason = message ?? HTTPURLResponse.localizedString(forStatusCode: 403)
            if (try? stop(account: account)) != .notAllowed {
                try? store.setMeta("stop.\(account)", BackupStop.notAllowed.rawValue)
                try? store.setMeta("stopReason.\(account)", reason)
                onEvent(.notAllowed(reason))
            }
        } catch {
            failed(error)
        }
        #if DEBUG
        BackupDiagnostics.write(store: store, account: account, snapshot: makeSnapshot(), note: "after a pass", launch: false)
        #endif
        publishNow()
    }

    /// A pass, or the person's check, ended with an error.
    private func failed(_ error: Error) {
        if lastErrorSince == nil { lastErrorSince = Date() }
        lastError = error.localizedDescription
        lastErrorReach = Self.isOutOfReach(error)
    }

    /// Immich out of reach or busy: no connection to it, no answer, or a 5xx or 429 from it or a proxy.
    static func isOutOfReach(_ error: Error) -> Bool {
        switch error {
        case is URLError: return true
        case ImmichError.serverUnreachable: return true
        case ImmichError.http(let status, _): return status >= 500 || status == 408 || status == 429
        default: return (error as NSError).domain == NSURLErrorDomain
        }
    }

    private func discover() async throws {
        reading = nil
        let outcome = try await BackupDiscovery(store: store).run { [weak self] count in
            Task { await self?.listed(count) }
        }
        reading = nil
        if case .listed = outcome { publish() }
    }

    private func listed(_ count: Int) {
        reading = count
        publish()
    }

    // MARK: Recovery

    /// Every unfinished step worked out again from facts, then the sweep.
    private func recover(account: String) async throws {
        let steps = try store.openSteps()
        let plan = BackupRecovery.plan(steps, tasksOnTheirWay: await transport.tasksOnTheirWay())
        for id in plan.redo {
            guard let step = steps.first(where: { $0.id == id }) else { continue }
            try store.finishStep(id, result: "redo")
            try store.setFinished(account: step.account, step.localID, false)
        }
        let asking = steps.filter { plan.ask.contains($0.id) }
        // Only this account's server can be asked; another account's steps are closed, and their parts checked again
        // when it is back. Offline, they stay open and recovery is tried at the next pass.
        let mine = asking.filter { $0.account == account }
        let checks: [String: BackupCheck]
        do {
            checks = try await server?.check(Array(Set(mine.compactMap(\.checksum)))) ?? [:]
        } catch {
            if error is CancellationError { throw error }
            return
        }
        for step in asking {
            let found = step.account == account ? step.checksum.flatMap { checks[$0] } : nil
            let (result, assetID, arrived) = BackupRecovery.result(of: found)
            if arrived, let checksum = step.checksum, let assetID {
                try store.recordUploaded(account: step.account, checksum: checksum, assetID: assetID, trashed: found?.state == .trashed)
            }
            try store.finishStep(step.id, result: result, assetID: assetID)
            if let file = step.file { try? FileManager.default.removeItem(atPath: file) }
            try store.refreshState(account: step.account, step.localID)
        }
        files.sweep(keeping: try store.filesInUse())
        try store.pruneJournal(before: Date().addingTimeInterval(-30 * 24 * 3600))
        recovered = true
    }

    /// Downloaded originals that will not go after all are removed.
    private func sweepStaged(account: String) {
        for (identifier, role, path) in (try? store.stagedNotGoing(account: account)) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
            try? store.setStaged(identifier, role, nil)
        }
    }

    // MARK: Parts and fingerprints

    /// Reads the parts of photos that need it, newest first, or of `only` these; the backlog's reading gives way to
    /// new photos as soon as the library changes.
    private func readParts(only: [String]? = nil) async throws -> Bool {
        let photos = try store.photosNeedingParts(limit: 50, only: only)
        guard !photos.isEmpty else { return false }
        for photo in photos {
            try Task.checkCancellation()
            if only == nil, libraryChanged { break }
            guard let asset = BackupLibrary.asset(photo.localID) else {
                try store.markGone([photo.localID])
                continue
            }
            let parts = await BackupParts.parts(of: asset)
            try store.setParts(photo.localID, parts, account: server?.account)
        }
        return true
    }

    /// Why an original only in iCloud waits to come down, in the person's words.
    private var notDownloadable: String {
        if !network.connected { return String(localized: "Only in iCloud, waiting for a connection to download it") }
        if network.constrained { return String(localized: "Only in iCloud, waiting while Low Data Mode is on") }
        return String(localized: "Only in iCloud, waiting for Wi-Fi to download it")
    }

    /// Whether an original only in iCloud may come down now: never in Low Data Mode, nor on cellular unless the setting
    /// allows its kind.
    private func downloadsAllowed(video: Bool) -> Bool {
        network.connected && !network.constrained && (!network.onCellular || settings.cellular(video: video))
    }

    /// Takes the fingerprints of parts without one, newest first, or of `only` these photos; the backlog's give way to
    /// new photos as soon as the library changes. Up to `readsAtOnce` at a time: a read is mostly waiting, on iCloud or
    /// the disk, and each still reads its whole file.
    private func fingerprint(only: [String]? = nil) async throws -> Bool {
        let pending = try store.partsToFingerprint(limit: 20, screenshots: settings.screenshots, only: only)
        guard !pending.isEmpty else { return false }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var reading = 0
            for (photo, part) in pending {
                try Task.checkCancellation()
                if only == nil, libraryChanged { break }
                if reading == Self.readsAtOnce {
                    try await group.next()
                    reading -= 1
                }
                group.addTask { try await self.fingerprint(photo, part) }
                reading += 1
            }
            try await group.waitForAll()
        }
        return true
    }

    static let readsAtOnce = 4

    /// One part's fingerprint: read on the phone, or downloaded from iCloud where it is only there.
    private func fingerprint(_ photo: BackupPhotoRow, _ part: BackupPartRow) async throws {
        do {
            let sink = BackupSink(file: nil)
            try await Self.readFromLibrary(photo.localID, part.role, networkAllowed: false, into: sink)
            let result = sink.result
            try store.setFingerprint(photo.localID, part.role, checksum: result.checksum, size: result.size)
        } catch BackupError.inCloudOnly {
            // One Immich's own app uploaded is known by its iCloud identifier, without a download.
            if await borrowFingerprint(photo, part) { return }
            guard downloadsAllowed(video: photo.isVideo || part.role.isPairedVideo) else {
                try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(15 * 60), reason: notDownloadable)
                return
            }
            try await download(photo, part)
        } catch BackupError.gone {
            try store.markGone([photo.localID])
        } catch BackupError.changed {
            try store.rereadParts(photo.localID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try fingerprintFailed(photo, part, error)
        }
    }

    /// An original only in iCloud, of a photo never edited, that Immich's own app uploaded: its fingerprint taken from
    /// Immich by the iCloud identifier that app keeps with the asset (BackupMobileApp), rather than downloaded. Only the
    /// assets taken at its second are asked (the timeline's months, read once per launch): a request or two, against
    /// seconds of download. Anything that fails leaves it to the download.
    private func borrowFingerprint(_ photo: BackupPhotoRow, _ part: BackupPartRow) async -> Bool {
        guard part.role == .original, let server, let cloudID = photo.cloudID, let created = photo.created,
              let parts = try? store.parts(photo.localID),
              parts.allSatisfy({ $0.role == .original || $0.role == .originalPair }) else { return false }
        do {
            if months == nil { months = Set(try await server.timelineMonths()) }
            let second = BackupAnotherForm.second(created)
            let local = BackupAnotherForm.Local(identifier: photo.localID, takenSecond: second, name: photo.name ?? "",
                                                wallClockSecond: second + Int64(TimeZone.current.secondsFromGMT(for: created)))
            var remotes: [BackupAnotherForm.Remote] = []
            for bucket in Self.buckets(around: created) where months?.contains(bucket) == true {
                remotes += try await monthOnServer(bucket)
            }
            for assetID in (BackupAnotherForm.sameSecond([local], remotes)[photo.localID] ?? []).prefix(3) {
                guard let value = try await server.mobileAppMetadata(assetID),
                      BackupMobileApp.matches(value, cloudID: cloudID, created: created, latitude: photo.latitude,
                                              longitude: photo.longitude),
                      let found = try await server.fingerprint(assetID) else { continue }
                try store.setFingerprint(photo.localID, part.role, checksum: found.checksum, size: found.size, borrowed: true)
                return true
            }
        } catch {
            // Offline, or Immich answered otherwise: the download it is.
        }
        return false
    }

    /// Downloads from iCloud on their way. A photo's, or a Live Photo's few seconds of video, is small, and up to
    /// `readsAtOnce` go together, each holding `heldPerDownload` of the budget for the others; a video's may be
    /// gigabytes and its size is unknown until it is read, so it goes alone.
    private var downloading = 0
    private var videoDownloading = false
    static let heldPerDownload: Int64 = 200 << 20

    /// An original only in iCloud, downloaded once into the file it is uploaded from, its fingerprint taken on the way.
    private func download(_ photo: BackupPhotoRow, _ part: BackupPartRow) async throws {
        guard !videoDownloading, !photo.isVideo || downloading == 0 else {
            // Another download holds the room it needs: tried again shortly, the others going on meanwhile.
            try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(2 * 60),
                               reason: String(localized: "Only in iCloud, downloaded after the ones before it"))
            return
        }
        let held = Int64(downloading) * Self.heldPerDownload
        downloading += 1
        if photo.isVideo { videoDownloading = true }
        defer {
            downloading -= 1
            if photo.isVideo { videoDownloading = false }
        }
        let file = files.staged.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            let free = files.freeBytes()
            let used = files.usedBytes()
            // Within the budget, or as large as it is with nothing else held, always leaving the reserve free.
            let alone = used == 0 && held == 0
            let room = alone ? Int64.max : max(0, BackupDiskBudget.budget(free: free) - used - held)
            let sink = BackupSink(file: output, limit: min(room, max(0, free - BackupDiskBudget.reserve - held)))
            try await Self.readFromLibrary(photo.localID, part.role, networkAllowed: true, into: sink)
            let result = sink.result
            try store.setFingerprint(photo.localID, part.role, checksum: result.checksum, size: result.size, staged: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            if case BackupError.noRoom(let needs) = error {
                if files.usedBytes() == 0 && held == 0 {
                    // Larger than the device has room for with nothing else held: the page says how much free space it
                    // needs (a state of the device, not of the photo), and it is tried again in an hour.
                    try store.setMeta("needsSpace", String(BackupDiskBudget.freeNeeded(for: needs)))
                    try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(3600),
                                       reason: String(localized: "Only in iCloud, and larger than the free space on this \(DeviceWords.model) allows"))
                } else {
                    // The budget is held by other downloads and by those waiting for their uploads: tried again once
                    // they have gone.
                    try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(10 * 60),
                                       reason: String(localized: "Only in iCloud, waiting for room while other downloads wait for their uploads"))
                }
                return
            }
            if error is CancellationError { throw error }
            try fingerprintFailed(photo, part, error)
        }
    }

    /// A fingerprint that failed: tried again quietly with backoff, as most such failures pass (an interrupted iCloud
    /// download, Verso stopped); only one still failing after five tries over three days needs a look, with its reason.
    private func fingerprintFailed(_ photo: BackupPhotoRow, _ part: BackupPartRow, _ error: Error) throws {
        let attempts = part.failures + 1
        let since = part.firstFailure ?? Date()
        let retry = Date().addingTimeInterval(BackupBackoff.delay(attempt: attempts))
        if BackupRules.readNeedsLook(failures: attempts, since: since) {
            let reason = "Verso couldn't read it from Photos for three days (\(error.localizedDescription)). Open it in Photos, or check iCloud."
            try store.setFingerprintFailure(photo.localID, part.role, reason: reason, retryAfter: retry)
        } else {
            try store.setFingerprintRetry(photo.localID, part.role, retryAfter: retry,
                                          reason: String(localized: "Couldn't be read (\(error.localizedDescription))"))
        }
    }

    /// A part's stored bytes into a sink: from the phone, and from iCloud where it is only there and the network may
    /// be used.
    static func readFromLibrary(_ identifier: String, _ role: BackupPartRole, networkAllowed: Bool, into sink: BackupSink) async throws {
        guard let asset = BackupLibrary.asset(identifier) else { throw BackupError.gone }
        guard let resource = BackupParts.resource(role, of: asset) else { throw BackupError.changed }
        do {
            try await BackupReader.read(resource, networkAllowed: false, into: sink)
        } catch BackupError.inCloudOnly where networkAllowed && sink.result.size == 0 {
            try await BackupReader.read(resource, networkAllowed: true, into: sink)
        }
    }

    // MARK: Checking with Immich

    /// The duplicate check: fingerprints the server has not been asked about, 500 at a time, or those of `only` these
    /// photos.
    private func checkWithServer(account: String, only: [String]? = nil) async throws -> Bool {
        guard let server else { return false }
        let checksums = try store.checksumsToCheck(account: account, limit: 500, only: only)
        guard !checksums.isEmpty else { return false }
        let checks = try await server.check(checksums)
        try store.recordChecks(account: account, checks.mapValues { ($0.state, $0.assetID) })
        sweepStaged(account: account)
        return true
    }

    private func refreshReady(account: String) throws -> Bool {
        let ready = try store.photosReadyForState(account: account, limit: 500)
        for identifier in ready { try store.refreshState(account: account, identifier) }
        return !ready.isEmpty
    }

    /// The first run's photos that are in Immich by no fingerprint, looked for in another form: an asset taken at the
    /// same second (the months of the account's timeline around it), whose name is the same. Photos that came to the
    /// phone after the first run started are new and are not looked for.
    private func lookForAnotherForm(account: String) async throws -> Bool {
        guard let server else { return false }
        let photos = try store.photosToMatch(account: account, limit: 100)
        guard !photos.isEmpty else { return false }
        let startedAt = try store.metaDate("firstRunStarted.\(account)")
        if months == nil { months = Set(try await server.timelineMonths()) }
        for photo in photos {
            try Task.checkCancellation()
            if libraryChanged { break }
            if let startedAt, let added = photo.added ?? photo.created, added > startedAt {
                try store.setAnotherForm(account: account, photo.localID, assetID: nil)
                continue
            }
            guard let created = photo.created, let name = photo.name else {
                try store.setAnotherForm(account: account, photo.localID, assetID: nil)
                continue
            }
            let second = BackupAnotherForm.second(created)
            let local = BackupAnotherForm.Local(identifier: photo.localID, takenSecond: second, name: name,
                                                wallClockSecond: second + Int64(TimeZone.current.secondsFromGMT(for: created)))
            var remotes: [BackupAnotherForm.Remote] = []
            for bucket in Self.buckets(around: created) where months?.contains(bucket) == true {
                remotes += try await monthOnServer(bucket)
            }
            var match: String?
            for assetID in (BackupAnotherForm.sameSecond([local], remotes)[photo.localID] ?? []).prefix(5) {
                // An asset gone since its month was read is no match; any other failure leaves the photo unlooked at,
                // and nothing of it goes, until the next pass.
                let asset: BackupAssetFacts?
                do { asset = try await server.asset(assetID) } catch ImmichError.http(404, _) { continue }
                if let asset, BackupAnotherForm.sameName(name, asset.name) {
                    match = assetID
                    break
                }
            }
            try store.setAnotherForm(account: account, photo.localID, assetID: match)
        }
        return true
    }

    private func monthOnServer(_ bucket: String) async throws -> [BackupAnotherForm.Remote] {
        if let kept = monthPhotos[bucket] { return kept }
        guard let server else { return [] }
        let photos = try await server.timelineMonth(bucket)
        monthPhotos[bucket] = photos
        return photos
    }

    /// The timeline months a photo taken at `date` may be in: Immich files it by the time where it was taken, up to 14
    /// hours either side of UTC.
    static func buckets(around date: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var buckets: [String] = []
        let offsets: [TimeInterval] = [-14 * 3600, 0, 14 * 3600]
        for offset in offsets {
            let components = calendar.dateComponents([.year, .month], from: date.addingTimeInterval(offset))
            let bucket = String(format: "%04d-%02d-01", components.year ?? 0, components.month ?? 0)
            if !buckets.contains(bucket) { buckets.append(bucket) }
        }
        return buckets
    }

    // MARK: Uploading

    /// Why nothing goes now, if something stops it.
    private func stop(account: String) throws -> BackupStop? {
        guard let stop = try store.meta("stop.\(account)").flatMap(BackupStop.init) else { return nil }
        if stop == .full, let since = try store.metaDate("stopSince.\(account)"), Date().timeIntervalSince(since) > 24 * 3600 {
            // A full server is tried again daily.
            try store.setMeta("stop.\(account)", nil)
            return nil
        }
        if stop == .unreachable {
            let until = try BackupOutage.pausedUntil(store: store, account: account) ?? .distantPast
            if Date() >= until {
                try BackupOutage.lift(store: store, account: account)
                return nil
            }
        }
        return stop
    }

    /// New photos first: those that came to the phone after backing up was switched on, newest first, read, checked
    /// and sent now, whatever is already on its way, through the app's own session while Verso is open. They are not
    /// looked for in another form, as the first run's photos are.
    private func sendNewFirst(account: String) async throws -> Bool {
        guard let server, settings.isOn, try stop(account: account) == nil else { return false }
        let new = try store.newPhotosToSend(account: account, screenshots: settings.screenshots, limit: 20)
        guard !new.isEmpty else { return false }
        var worked = try await readParts(only: new)
        worked = try await fingerprint(only: new) || worked
        if network.connected { worked = try await checkWithServer(account: account, only: new) || worked }
        // A new photo is not looked for in another form: it goes once Immich has none of its parts.
        for identifier in new where (try? store.state(account: account, identifier)) == .unchecked {
            try store.setAnotherForm(account: account, identifier, assetID: nil)
        }
        guard network.connected, !holding else { return worked }
        // After an outage's pause, a few at a time until one lands.
        let limit = try BackupOutage.probing(store: store, account: account)
            ? max(0, BackupOutage.probe - store.uploadsOnTheirWay(account: account)) : 20
        let candidates = try limit == 0 ? [] : store.uploadCandidates(account: account, limit: limit, screenshots: settings.screenshots, only: new)
        for candidate in candidates {
            try Task.checkCancellation()
            guard fit(candidate, account: account) == .fits else { continue }
            try await send(candidate, account: account, server: server, fast: foreground)
            worked = true
        }
        if worked { publish() }
        return worked
    }

    enum Fit { case fits, later, alone }

    /// Whether a part's body fits the disk budget now. A downloaded original is the body's source and goes once the
    /// body is written, so it counts once, as the body. A part larger than the budget goes alone (`alone`, while others
    /// are held); one the device has no room for even then waits, saying how much free space it needs.
    private func fit(_ candidate: BackupUploadCandidate, account: String) -> Fit {
        let needs = candidate.part.size ?? 0
        let own = candidate.part.staged.flatMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        } ?? 0
        let used = max(0, files.usedBytes() - own)
        let free = files.freeBytes()
        if BackupDiskBudget.fits(needs, used: used, free: free) { return .fits }
        if free - needs < BackupDiskBudget.reserve {
            // The device has no room for it even with nothing else held: the page says how much free space it needs,
            // a state of the device rather than of the photo, which goes once there is room.
            if used == 0 { try? store.setMeta("needsSpace", String(BackupDiskBudget.freeNeeded(for: needs))) }
            return .later
        }
        return BackupDiskBudget.goesAlone(needs, free: free) ? .alone : .later
    }

    /// Tops the uploads up to 100 on their way once fewer than 20 are.
    private func planUploads(account: String) async throws {
        guard let server, settings.isOn, try store.meta("firstRunStarted.\(account)") != nil,
              try stop(account: account) == nil, network.connected, !holding else { return }
        let onTheirWay = try store.uploadsOnTheirWay(account: account)
        // After an outage's pause, a few at a time until one lands.
        let probing = try BackupOutage.probing(store: store, account: account)
        guard onTheirWay < (probing ? BackupOutage.probe : 20) else { return }
        let candidates = try store.uploadCandidates(account: account, limit: (probing ? BackupOutage.probe : 100) - onTheirWay,
                                                    screenshots: settings.screenshots)
        // Once a part larger than the budget waits to go alone, nothing new is started before it, so what is held
        // drains; only parts already downloaded go meanwhile, which frees their room as they arrive.
        var draining = false
        for candidate in candidates {
            try Task.checkCancellation()
            if libraryChanged { break }
            if draining && candidate.part.staged == nil { continue }
            switch fit(candidate, account: account) {
            case .fits:
                try await send(candidate, account: account, server: server)
            case .later:
                continue
            case .alone:
                draining = true
            }
        }
        publish()
    }

    /// One part's upload: its intent written, its body written by the same code that took its fingerprint (and the
    /// two compared), then handed to the background session, or to the app's own (`fast`).
    private func send(_ candidate: BackupUploadCandidate, account: String, server: any BackupServer,
                      fast: Bool = false) async throws {
        let photo = candidate.photo
        let part = candidate.part
        guard let expected = part.checksum else { return }
        let video = photo.isVideo || part.role.isPairedVideo
        let boundary = "Verso-\(UUID().uuidString)"
        let file = files.uploads.appendingPathComponent(UUID().uuidString)
        let step = try store.beginStep(account: account, photo.localID, role: part.role, kind: .upload, checksum: expected,
                                       file: file.path)
        do {
            // The still or video of a photo never edited carries the iCloud identifier Immich's own app keeps, so that app
            // knows the asset without reading the photo again (BackupMobileApp); a Live Photo's video does not, as that
            // app's do not.
            let unedited = try store.parts(photo.localID).allSatisfy { $0.role == .original || $0.role == .originalPair }
            let mobileApp = part.role == .original && unedited
                ? BackupMobileApp.field(cloudID: photo.cloudID, created: photo.created, latitude: photo.latitude,
                                        longitude: photo.longitude)
                : nil
            let fields = BackupUploadBody.fields(photo: photo, part: part, pairedVideoAssetID: candidate.pairedVideoAssetID,
                                                 mobileApp: mobileApp)
            let type = part.uti.flatMap(UTType.init) ?? UTType(filenameExtension: (part.name as NSString).pathExtension)
            var downloaded = part.staged.map(URL.init(fileURLWithPath:))
            if let file = downloaded, !FileManager.default.fileExists(atPath: file.path) {
                // Gone (Verso stopped between its upload and the record of it, say): read from Photos again.
                try store.setStaged(photo.localID, part.role, nil)
                downloaded = nil
            }
            let staged = downloaded
            let downloads = downloadsAllowed(video: video)
            let written = try await BackupUploadBody.write(to: file, boundary: boundary, fields: fields, fileName: part.name,
                                                           mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                                           limit: nil) { sink in
                if let staged {
                    try BackupUploadBody.stream(staged, into: sink)
                } else {
                    try await Self.readFromLibrary(photo.localID, part.role, networkAllowed: downloads, into: sink)
                }
            }
            guard written.checksum == expected else {
                // Edited while it was read: its new fingerprint is checked with Immich before anything goes.
                try store.finishStep(step, result: "changed")
                try? FileManager.default.removeItem(at: file)
                try store.setFingerprint(photo.localID, part.role, checksum: written.checksum, size: written.size)
                try store.rereadParts(photo.localID)
                return
            }
            if let staged {
                try? FileManager.default.removeItem(at: staged)
                try store.setStaged(photo.localID, part.role, nil)
            }
            let request = try server.uploadRequest(boundary: boundary, checksum: expected, cellular: settings.cellular(video: video))
            let task = transport.send(request, file: file, step: step, fast: fast)
            try store.setStepTask(step, task: task)
        } catch {
            try? FileManager.default.removeItem(at: file)
            switch error {
            case BackupError.gone:
                try store.finishStep(step, result: "gone")
                try store.markGone([photo.localID])
            case BackupError.changed:
                try store.finishStep(step, result: "changed")
                try store.rereadParts(photo.localID)
            case BackupError.inCloudOnly:
                try store.finishStep(step, result: "waiting for the network")
                try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(15 * 60), reason: notDownloadable)
            case is CancellationError:
                try store.finishStep(step, result: "cancelled")
                throw error
            default:
                try store.finishStep(step, result: "unread: \(error.localizedDescription)")
                try store.postpone(photo.localID, part.role, until: Date().addingTimeInterval(BackupBackoff.delay(attempt: 3)),
                                   reason: String(localized: "Couldn't be read for its upload (\(error.localizedDescription))"))
            }
        }
    }

    /// An upload's answer, recorded by the transport: what it means for the person, and the next uploads.
    func answered(_ answer: BackupAnswer) {
        switch answer.outcome {
        case .uploaded(_, let created):
            if created, personRun != nil { personRun? += 1 }
        case .unauthorized:
            // The stop is the run's end, said once.
            personRun = nil
            onEvent(.signInAgain)
        case .serverFull:
            personRun = nil
            onEvent(.serverFull)
        case .notAllowed(let reason):
            personRun = nil
            onEvent(.notAllowed(reason))
        case .paused(let reason):
            // Said for a run the person started, which ends here; backing up on its own pauses quietly, and the
            // Library's line says so.
            if personRun != nil {
                personRun = nil
                onEvent(.unreachable(until: try? BackupOutage.pausedUntil(store: store, account: answer.account), reason: reason))
            }
        case .refused, .retryLater, .cancelled:
            break
        }
        kick()
    }

    // MARK: Finishing

    /// Backed-up photos Verso uploaded something of: an edit's stack with the newest rendering on top, RAW+JPEG's
    /// second file under the first, a burst's frames under the one picked once all are in Immich, and the date and
    /// place Photos has where Immich read others from the file.
    private func finishPhotos(account: String) async throws -> Bool {
        guard let server else { return false }
        let now = Date()
        finishLater = finishLater.filter { $0.value > now }
        let identifiers = try store.photosToFinish(account: account, limit: 20).filter { finishLater[$0] == nil }
        guard !identifiers.isEmpty else { return false }
        let batch = Array(identifiers.prefix(10))
        // Immich keeps each asset under the checksum it took of the bytes it received: asked by Verso's own, in one
        // request for the batch, it shows the parts Verso made arrived as they were read.
        var made: [String: Set<String>] = [:]
        var sent: [String: [String]] = [:]
        for identifier in batch {
            made[identifier] = try store.assetsMade(account: account, identifier)
            sent[identifier] = try store.parts(identifier).compactMap { part in
                guard let checksum = part.checksum, let asset = try store.remoteAssetID(account: account, checksum: checksum),
                      made[identifier]?.contains(asset) == true else { return nil }
                return checksum
            }
        }
        let arrived: [String: BackupCheck]
        do {
            let checksums = Array(Set(sent.values.joined()))
            arrived = try await checksums.isEmpty ? [:] : server.check(checksums)
        } catch {
            if error is CancellationError { throw error }
            if case ImmichError.unauthorized = error { throw error }
            for identifier in batch { finishLater[identifier] = Date().addingTimeInterval(3600) }
            return false
        }
        var finished = false
        for identifier in batch {
            try Task.checkCancellation()
            let differ = (sent[identifier] ?? []).filter { arrived[$0]?.state == .absent }
            if !differ.isEmpty {
                try store.recordNotAsSent(account: account, identifier, checksums: differ,
                                          reason: "Immich doesn't hold it as it was sent: it arrived otherwise, which a proxy in front of Immich may cause, or it was deleted there. Retry sends it again.")
                continue
            }
            guard let photo = try store.photo(identifier) else { continue }
            // A hidden photo is in the Locked Folder, which Immich lets no one stack or date without the account's PIN:
            // its date and place are the file's own, and it is done once it arrived.
            if photo.hidden {
                try store.setFinished(account: account, identifier, true)
                finished = true
                continue
            }
            var assets: [BackupPartRole: String] = [:]
            for part in try store.parts(identifier) {
                if let checksum = part.checksum, let asset = try store.remoteAssetID(account: account, checksum: checksum) {
                    assets[part.role] = asset
                }
            }
            var stack: [String] = []
            if let top = assets[.render], let original = assets[.original] {
                stack = [top, original] + [assets[.alternate]].compactMap { $0 } + (try store.previousTops(account: account, identifier))
            } else if let original = assets[.original], let alternate = assets[.alternate] {
                stack = [original, alternate]
            }
            stack = stack.reduce(into: []) { kept, id in if !kept.contains(id) { kept.append(id) } }
            do {
                if stack.count > 1 {
                    let step = try store.beginStep(account: account, identifier, role: nil, kind: .stack)
                    try await server.stack(stack)
                    try store.finishStep(step, result: "stacked")
                }
                if let burst = photo.burst { try await stackBurst(burst, account: account, server: server) }
                // Only on assets Verso made: one Immich had already (from another app, its date perhaps put right
                // there) is left as it is.
                let shown = [assets[.render], assets[.original]].compactMap { $0 }.filter { made[identifier]?.contains($0) == true }
                if try await setMetadata(photo, assets: shown, account: account, server: server) {
                    try store.setFinished(account: account, identifier, true)
                    finished = true
                } else {
                    finishLater[identifier] = Date().addingTimeInterval(10 * 60)
                }
            } catch {
                if error is CancellationError { throw error }
                if case ImmichError.unauthorized = error { throw error }
                // Tried again in an hour; the photo is in Immich either way.
                finishLater[identifier] = Date().addingTimeInterval(3600)
            }
        }
        return finished
    }

    /// A burst's frames stacked under the one picked, once every frame is in Immich.
    private func stackBurst(_ burst: String, account: String, server: any BackupServer) async throws {
        let key = "burst.\(account).\(burst)"
        guard try store.meta(key) == nil else { return }
        let frames = try store.burst(burst)
        guard frames.count > 1 else { return }
        var ids: [String] = []
        for frame in frames {
            guard try store.state(account: account, frame.localID) == .backedUp else { return }
            let parts = try store.parts(frame.localID)
            let top = parts.first { $0.role == .render } ?? parts.first { $0.role == .original }
            guard let checksum = top?.checksum, let asset = try store.remoteAssetID(account: account, checksum: checksum) else { return }
            ids.append(asset)
        }
        let step = try store.beginStep(account: account, frames[0].localID, role: nil, kind: .stack)
        try await server.stack(ids)
        try store.finishStep(step, result: "stacked burst")
        try store.setMeta(key, "stacked")
    }

    /// Photos' date and place set on the assets where Immich read others from the file (a date or place changed in
    /// Photos stays out of the file). Waits while Immich has not read the file yet, for up to an hour after the upload.
    /// The favourite too, where the person changed it on the phone after the upload's body was written.
    private func setMetadata(_ photo: BackupPhotoRow, assets: [String], account: String, server: any BackupServer) async throws -> Bool {
        let uploadedAt = try store.lastUpload(account: account, photo.localID) ?? .distantPast
        for assetID in assets {
            guard let facts = try await server.asset(assetID) else { continue }
            if facts.isFavorite != photo.favorite { try await server.setFavorite([assetID], photo.favorite) }
            if !facts.extracted && Date().timeIntervalSince(uploadedAt) < 3600 { return false }
            var takenAt: String?
            if let created = photo.created, let serverTaken = facts.takenAt, abs(created.timeIntervalSince(serverTaken)) >= 1 {
                takenAt = BackupServerDates.format(created, timeZone: facts.timeZone ?? TimeZone.current.identifier)
            }
            var latitude: Double?
            var longitude: Double?
            if let phoneLatitude = photo.latitude, let phoneLongitude = photo.longitude {
                let differs = facts.latitude.map { abs($0 - phoneLatitude) > 0.0001 } ?? true
                    || facts.longitude.map { abs($0 - phoneLongitude) > 0.0001 } ?? true
                if differs { latitude = phoneLatitude; longitude = phoneLongitude }
            }
            guard takenAt != nil || latitude != nil else { continue }
            let step = try store.beginStep(account: account, photo.localID, role: nil, kind: .metadata)
            try await server.setMetadata([assetID], takenAt: takenAt, latitude: latitude, longitude: longitude)
            try store.finishStep(step, result: "set")
        }
        return true
    }

    // MARK: Not in Immich

    /// The weekly check that what Verso counts as in Immich still is (about 200 requests at 100,000 photos).
    private func verifyIfDue(account: String) async throws {
        guard try store.meta("firstRunStarted.\(account)") != nil, try stop(account: account) == nil else { return }
        let last = try store.metaDate("verified.\(account)") ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 24 * 3600 else { return }
        if last == .distantPast {
            // The first run's own photos were checked as it ran: the first check is a week after it.
            try store.setMetaDate("verified.\(account)", Date())
            return
        }
        try await verify(account: account, answer: nil)
    }

    /// Checks every fingerprint Verso counts as in Immich, sorts what is gone into Deleted in Immich and Missing from
    /// Immich, and says the newly missing ones once. When most of it is gone at once, nothing is applied: backing up
    /// stops until the person answers, and their answer applies to what is gone.
    func verify(account: String, answer: BackupMostGoneAnswer?) async throws {
        guard let server, server.account == account else { return }
        var checks: [String: BackupCheck] = [:]
        var after = ""
        while true {
            let page = try store.checksumsToVerify(account: account, after: after, limit: 500)
            guard let last = page.last else { break }
            try Task.checkCancellation()
            checks.merge(try await server.check(page)) { $1 }
            after = last
        }
        let announced = try store.announced(account: account)
        var verification = BackupRules.Verification()
        var offset = 0
        while true {
            let identifiers = try store.identifiers(account: account, in: [.backedUp, .missingFromImmich, .deletedInImmich, .inImmichTrash],
                                                    limit: 1000, offset: offset)
            guard !identifiers.isEmpty else { break }
            var photos: [String: BackupPhotoFacts] = [:]
            for identifier in identifiers {
                guard var facts = try store.facts(account: account, identifier) else { continue }
                for index in facts.parts.indices {
                    guard let checksum = facts.parts[index].checksum, let check = checks[checksum] else { continue }
                    facts.parts[index].remote = check.state
                    if check.state == .trashed { facts.parts[index].seenTrashed = true }
                    if check.state == .present { facts.parts[index].sent = true }
                }
                photos[identifier] = facts
            }
            let page = BackupRules.verify(photos, announced: announced)
            verification.states.merge(page.states) { $1 }
            verification.newlyMissing += page.newlyMissing
            verification.wereBackedUp += page.wereBackedUp
            verification.goneNow += page.goneNow
            offset += identifiers.count
        }
        verification.mostGone = verification.goneNow >= BackupRules.mostGoneMinimum
            && Double(verification.goneNow) >= BackupRules.mostGoneShare * Double(max(verification.wereBackedUp, 1))
        if verification.mostGone && (answer == nil || answer == .checkAgain) {
            try store.setMeta("stop.\(account)", BackupStop.mostGone.rawValue)
            try store.setMeta("mostGone.\(account)", "\(verification.goneNow)/\(verification.wereBackedUp)")
            onEvent(.mostGone(gone: verification.goneNow, of: verification.wereBackedUp))
            publish()
            return
        }
        try store.recordChecks(account: account, checks.mapValues { ($0.state, $0.assetID) })
        let gone = verification.states.filter { $0.value == .missingFromImmich || $0.value == .deletedInImmich }.map(\.key)
        switch answer {
        case .deleted?: try store.setDecision(account: account, gone, .letGo)
        case .sendAgain?: try store.setDecision(account: account, gone, .sendAgain)
        case .checkAgain?, nil: break
        }
        for identifier in verification.states.keys { try store.refreshState(account: account, identifier) }
        let missing = answer == nil ? verification.newlyMissing : []
        if !missing.isEmpty {
            try store.markAnnounced(account: account, missing)
            onEvent(.missing(missing.count))
        }
        try store.setMeta("stop.\(account)", nil)
        try store.setMeta("mostGone.\(account)", nil)
        try store.setMetaDate("verified.\(account)", Date())
        publish()
    }

    /// The person's answer to "most of the library is gone".
    func answerMostGone(_ answer: BackupMostGoneAnswer) async {
        guard let account else { return }
        do {
            try await verify(account: account, answer: answer)
            kick()
        } catch {
            failed(error)
            publishNow()
        }
    }

    /// A check now, from the Backup page.
    func checkNow() async {
        guard let account else { return }
        do {
            try await verify(account: account, answer: nil)
        } catch {
            failed(error)
        }
        publishNow()
    }

    // MARK: Free Up Space

    /// What Free Up Space can remove now, as the snapshot says it; refreshed after each pass and as its settings change.
    private var freeable: (count: Int, bytes: Int64)?
    /// What keeping a year would free, while Keep on This iPhone is Forever and the phone runs short of space.
    private var spaceOffer: (count: Int, bytes: Int64)?

    /// The photos Free Up Space may remove now, newest first, with Always Keep's left out: the favourites, the albums
    /// chosen, and hidden photos where they stay.
    func freeUpCandidates() async -> [FreeUpCandidate] {
        guard let months = BackupSettings.current.keepMonths else { return [] }
        return candidates(keepingMonths: months)
    }

    private func candidates(keepingMonths months: Int) -> [FreeUpCandidate] {
        let settings = BackupSettings.current
        guard let account else { return [] }
        var ageFromTaken = false
        #if DEBUG
        // Verso Dev's walk (FreeUpSpaceWalkTests): a Simulator's photos were all added lately.
        ageFromTaken = ProcessInfo.processInfo.environment["VERSO_FREE_UP_BY_TAKEN"] != nil
        #endif
        var candidates = (try? store.freeUpCandidates(account: account, cutoff: FreeUpRules.cutoff(months: months),
                                                      keepFavorites: settings.keepFavorites,
                                                      includeHidden: settings.hiddenPhotos && !settings.keepHidden,
                                                      ageFromTaken: ageFromTaken)) ?? []
        if !settings.keepAlbums.isEmpty {
            let kept = BackupLibrary.members(ofAlbums: settings.keepAlbums)
            candidates.removeAll { kept.contains($0.photo.localID) }
        }
        return candidates
    }

    /// Free Up Space's count and size for the snapshot, and its reminder: at most once a month, with a gigabyte or
    /// more to gain. While Keep on This iPhone is Forever, what keeping a year would free, once the phone runs short of
    /// space, for the Library's card; never a notification.
    func refreshFreeUp() async {
        let settings = BackupSettings.current
        guard let account else {
            freeable = nil
            spaceOffer = nil
            publish()
            return
        }
        guard let months = settings.keepMonths else {
            freeable = nil
            spaceOffer = nil
            if Self.phoneLowOnSpace() {
                let candidates = candidates(keepingMonths: FreeUpRules.offerMonths)
                spaceOffer = (candidates.count, candidates.reduce(0) { $0 + $1.size })
            }
            publish()
            return
        }
        spaceOffer = nil
        let candidates = await freeUpCandidates()
        let bytes = candidates.reduce(0) { $0 + $1.size }
        freeable = (candidates.count, bytes)
        publish()
        if FreeUpRules.remind(bytes: bytes, lastReminded: try? store.metaDate("freeUpReminded.\(account)")) {
            try? store.setMetaDate("freeUpReminded.\(account)", Date())
            onEvent(.freeUpReady(count: candidates.count, bytes: bytes, months: months))
        }
    }

    /// The phone's own storage runs short (FreeUpRules.lowOnSpace).
    private static func phoneLowOnSpace() -> Bool {
        #if DEBUG
        // Verso Dev's walk (FreeUpSpaceWalkTests): the Simulator has the Mac's disk.
        if ProcessInfo.processInfo.environment["VERSO_LOW_ON_SPACE"] != nil { return true }
        #endif
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL.homeDirectory.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage else { return false }
        return FreeUpRules.lowOnSpace(free: free, total: Int64(values.volumeTotalCapacity ?? 0))
    }

    /// The safety checks, for each photo, when the review opens and again right before deleting: every part in Immich
    /// by its fingerprint (the duplicate check); the asset itself the account's own, not in the trash, not an external
    /// library's, with the same checksum and size; its original readable from the server's disk; on the phone,
    /// unchanged since it was read, and a fingerprint borrowed from Immich read for real (`readBorrowed`; the check
    /// right before deleting does not read again what the review read minutes before). Why each photo stays, by its
    /// local identifier; one absent may go. `progress` hears how many are done.
    func freeUpVerify(_ candidates: [FreeUpCandidate], readBorrowed: Bool,
                      progress: @escaping @Sendable (Int) -> Void) async -> [String: String] {
        guard let server, let account else {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.photo.localID, String(localized: "Verso is not signed in")) })
        }
        let userID = String(account.split(separator: "|").last ?? "")
        let checks: [String: BackupCheck]
        do {
            checks = try await server.check(Array(Set(candidates.flatMap { $0.parts.map(\.checksum) })))
        } catch {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.photo.localID, String(localized: "Immich couldn't be asked")) })
        }
        var reasons: [String: String] = [:]
        var done = 0
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            for candidate in candidates {
                if running == 6, let (identifier, reason) = await group.next() {
                    running -= 1
                    done += 1
                    progress(done)
                    if let reason { reasons[identifier] = reason }
                }
                let downloads = downloadsAllowed(video: candidate.photo.isVideo)
                group.addTask {
                    (candidate.photo.localID, await Self.verify(candidate, checks: checks, server: server, userID: userID,
                                                                downloads: downloads, readBorrowed: readBorrowed))
                }
                running += 1
            }
            for await (identifier, reason) in group {
                done += 1
                progress(done)
                if let reason { reasons[identifier] = reason }
            }
        }
        return reasons
    }

    private static func verify(_ candidate: FreeUpCandidate, checks: [String: BackupCheck], server: any BackupServer,
                               userID: String, downloads: Bool, readBorrowed: Bool) async -> String? {
        let photo = candidate.photo
        guard let asset = BackupLibrary.asset(photo.localID) else { return String(localized: "It is no longer on this \(DeviceWords.model)") }
        if let modified = asset.modificationDate, let known = photo.modified, modified.timeIntervalSince(known) > 1 {
            return String(localized: "It changed on this \(DeviceWords.model) since it was backed up")
        }
        guard !candidate.parts.isEmpty else { return String(localized: "Immich doesn't have it as it is on this \(DeviceWords.model)") }
        for part in candidate.parts {
            guard let check = checks[part.checksum], check.state == .present, let id = check.assetID ?? part.assetID else {
                return String(localized: "Immich doesn't have it as it is on this \(DeviceWords.model)")
            }
            let facts: BackupFreeUpFacts?
            do { facts = try await server.freeUpFacts(id) } catch { return String(localized: "Immich couldn't be asked about it") }
            guard let facts else { return String(localized: "Immich doesn't have it as it is on this \(DeviceWords.model)") }
            if facts.ownerID != nil && facts.ownerID != userID { return String(localized: "It is in Immich under another account") }
            if facts.trashed { return String(localized: "It is in Immich's trash") }
            if facts.external { return String(localized: "It is in one of Immich's external libraries") }
            if facts.checksum != part.checksum { return String(localized: "Immich holds other bytes than this \(DeviceWords.model)") }
            if let size = facts.size, let local = part.size, size != local {
                return String(localized: "Immich holds a file of another size")
            }
            guard (try? await server.originalReadable(id)) == true else { return String(localized: "Immich couldn't read its original") }
            if part.borrowed && readBorrowed {
                // Known by its iCloud identifier, not read: read now, as only the phone's own bytes may let it go.
                let sink = BackupSink(file: nil)
                do {
                    try await readFromLibrary(photo.localID, part.role, networkAllowed: downloads, into: sink)
                } catch {
                    return String(localized: "It couldn't be read on this \(DeviceWords.model) to compare with Immich")
                }
                if sink.result.checksum != part.checksum { return String(localized: "On this \(DeviceWords.model) it is not what Immich holds") }
            }
        }
        return nil
    }

    /// Freed photos, watched for the 30 days Recently Deleted keeps them, once a day: any no longer in Immich is said
    /// once, while it can still be brought back.
    private func watchFreed(account: String) async throws {
        let now = Date()
        try store.pruneFreed(before: now.addingTimeInterval(-30 * 24 * 3600))
        if let last = try store.metaDate("freedWatched.\(account)"), now.timeIntervalSince(last) < 24 * 3600 { return }
        let watched = try store.freedToWatch(account: account, since: now.addingTimeInterval(-30 * 24 * 3600))
        guard !watched.isEmpty, let server else { return }
        let checks = try await server.check(Array(Set(watched.map(\.checksum))))
        try store.setMetaDate("freedWatched.\(account)", now)
        let gone = watched.filter { checks[$0.checksum]?.state != .present }
        guard !gone.isEmpty else { return }
        try store.markFreedAnnounced(account: account, gone.map(\.checksum))
        let photos = Set(gone.map(\.localID)).count
        let until = (gone.map(\.freed).min() ?? now).addingTimeInterval(30 * 24 * 3600)
        onEvent(.freedMissing(count: photos, until: until))
    }

    /// Photos the person freed: watched for 30 days.
    func recordFreed(_ candidates: [FreeUpCandidate]) async {
        guard let account else { return }
        try? store.recordFreed(account: account, candidates)
        await refreshFreeUp()
    }

    // MARK: The person's actions

    /// Start on the first run's tally: uploading begins.
    func startFirstRun() {
        guard let account else { return }
        if (try? store.meta("firstRunStarted.\(account)")) == nil {
            try? store.setMetaDate("firstRunStarted.\(account)", Date())
        }
        personRun = 0
        kick()
    }

    /// Back Up Now: a run the person started, said when it ends.
    func backUpNow() {
        guard let account else { return }
        // A full server, one that did not let this sign-in upload, or one out of reach is tried at once; most of the
        // library gone waits for the person's answer.
        if let current = try? stop(account: account), current == .full || current == .notAllowed { liftStop(account: account) }
        try? BackupOutage.lift(store: store, account: account)
        personRun = personRun ?? 0
        kick()
    }

    func decide(_ identifiers: [String], _ decision: BackupDecision?) {
        guard let account else { return }
        // Sent after all: what failed before is tried again now.
        if decision == .send { try? store.clearFailures(account: account, identifiers) }
        try? store.setDecision(account: account, identifiers, decision)
        kick()
    }

    func retry(_ identifiers: [String]) {
        guard let account else { return }
        try? store.clearFailures(account: account, identifiers)
        for identifier in identifiers { _ = try? store.refreshState(account: account, identifier) }
        kick()
    }

    func signedInAgain() {
        guard let account else { return }
        if let current = try? stop(account: account), current == .unauthorized || current == .notAllowed { liftStop(account: account) }
        kick()
    }

    private func liftStop(account: String) {
        try? store.setMeta("stop.\(account)", nil)
        try? store.setMeta("stopReason.\(account)", nil)
    }

    /// The first run's check, done with what it can do before Start, said once: by then every photo is checked, or the
    /// rest wait for something Start brings (room for iCloud originals) or for a quiet retry.
    private func sayReadyToStart(account: String) throws {
        guard try store.meta("firstRunStarted.\(account)") == nil, try store.meta("readySaid.\(account)") == nil,
              (try? store.meta("listed")) == "done" else { return }
        let tally = BackupTally(states: try store.counts(account: account, screenshots: settings.screenshots),
                                toUploadBytes: try store.bytesToUpload(account: account, screenshots: settings.screenshots))
        guard tally.checked > 0 else { return }
        try store.setMeta("readySaid.\(account)", "yes")
        onEvent(.readyToStart(toUpload: tally.toUpload, bytes: tally.toUploadBytes, inImmich: tally.alreadyInImmich,
                              toCheck: tally.total - tally.checked))
    }

    #if DEBUG
    /// Verso Dev's reset: everything backing up knows on this device forgotten, its files removed, so the first run can
    /// be walked again. Immich is not touched.
    func forgetEverything() async {
        if let ending = pass {
            ending.cancel()
            await ending.value
        }
        try? store.forgetEverything()
        files.sweep(keeping: [])
        recovered = false
        months = nil
        monthPhotos = [:]
        personRun = nil
        finishLater = [:]
        lastError = nil
        lastErrorSince = nil
        reading = nil
        publishNow()
    }
    #endif

    /// The run the person started ended once nothing is left to go.
    private func endPersonRunIfDone(account: String) {
        guard let uploaded = personRun, (try? store.uploadsOnTheirWay(account: account)) == 0 else { return }
        let toUpload = (try? store.counts(account: account, screenshots: settings.screenshots)[.toUpload]) ?? 0
        guard toUpload == 0, (try? stop(account: account)) == nil else { return }
        personRun = nil
        onEvent(.runEnded(uploaded: uploaded))
    }

    func uploadedInPersonRun() -> Int? { personRun }

    // MARK: The snapshot

    /// Sends the snapshot at most twice a second while things change.
    private func publish() {
        guard !snapshotPending else { return }
        snapshotPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            snapshotPending = false
            publishNow()
        }
    }

    private func publishNow() {
        let snapshot = makeSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot(snapshot)
    }

    func snapshot() -> BackupSnapshot { makeSnapshot() }

    private func makeSnapshot() -> BackupSnapshot {
        var snapshot = BackupSnapshot()
        snapshot.onCellular = network.onCellular
        snapshot.constrained = network.constrained
        snapshot.connected = network.connected
        // Immich out of reach is waited for; another error is said once it has lasted an hour.
        if let lastError, let since = lastErrorSince {
            if lastErrorReach {
                snapshot.immichOutOfReachSince = since
            } else if Date().timeIntervalSince(since) > 3600 {
                snapshot.error = lastError
            }
        }
        let settings = BackupSettings.current
        guard settings.isOn else { snapshot.phase = .off; return snapshot }
        guard BackupLibrary.hasFullAccess else { snapshot.phase = .noAccess; return snapshot }
        guard let account else { snapshot.phase = .signedOut; return snapshot }
        let counts = (try? store.counts(account: account, screenshots: settings.screenshots)) ?? [:]
        let bytes = (try? store.bytesToUpload(account: account, screenshots: settings.screenshots)) ?? 0
        snapshot.tally = BackupTally(states: counts, toUploadBytes: bytes)
        snapshot.onTheirWay = (try? store.uploadsOnTheirWay(account: account)) ?? 0
        snapshot.going = (try? store.goingCount(account: account, screenshots: settings.screenshots)) ?? 0
        snapshot.firstRunStarted = (try? store.meta("firstRunStarted.\(account)")) != nil
        snapshot.lastChecked = try? store.metaDate("verified.\(account)")
        if let text = try? store.meta("mostGone.\(account)") {
            let numbers = text.split(separator: "/").compactMap { Int($0) }
            if numbers.count == 2 { snapshot.mostGone = (numbers[0], numbers[1]) }
        }
        snapshot.stopReason = try? store.meta("stopReason.\(account)")
        snapshot.freeable = freeable
        snapshot.spaceOffer = spaceOffer
        // What waits, while no pass runs: when it is tried again.
        if pass == nil { snapshot.nextRetry = try? store.nextRetry(account: account) }
        snapshot.needsSpace = try? store.meta("needsSpace").flatMap { Int64($0) }
        snapshot.sentByVerso = (try? store.sentByVerso(account: account)) ?? 0
        snapshot.screenshotsLeftOut = settings.screenshots ? 0 : ((try? store.screenshots()) ?? 0)
        #if DEBUG
        snapshot.borrowedFingerprints = (try? store.borrowedCount()) ?? 0
        #endif
        snapshot.pausedUntil = try? BackupOutage.pausedUntil(store: store, account: account)
        if let reading, (try? store.meta("listed")) != "done" {
            snapshot.phase = .reading(reading)
        } else if let stop = try? stop(account: account) {
            snapshot.phase = .stopped(stop)
        } else if !snapshot.firstRunStarted {
            snapshot.phase = pass == nil ? .waitingForStart : .checking
        } else if pass != nil || snapshot.onTheirWay > 0 || snapshot.going > 0 || snapshot.tally.checked < snapshot.tally.total {
            // Not backed up while anything is still to check or to upload, waiting or not.
            snapshot.phase = .backingUp
        } else {
            snapshot.phase = .upToDate
        }
        return snapshot
    }
}
