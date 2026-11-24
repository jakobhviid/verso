// What backing the iPhone up knows and decides (ROADMAP.md, M10, "Backing the iPhone up"), as plain values and pure
// rules, with no PhotoKit, no network and no store, so the logic tests (ios/VersoTests) run them as they are:
// - a photo's parts, each a stored resource with its own content, and the photo backed up only when every part is on
//   the server (`BackupRules.state`);
// - what the server said of each part's fingerprint, and what the person decided;
// - Not in Immich: a check's results sorted into Deleted in Immich and Missing from Immich, and the stop when most of
//   the library is gone at once (`BackupRules.verify`);
// - the first run's tally, and the photos Immich has in another form (`BackupAnotherForm`).

import Foundation

/// A stored resource of a photo with its own content, which goes to Immich as an asset of its own.
enum BackupPartRole: String, Sendable, CaseIterable, Codable {
    /// The photo or video as taken.
    case original
    /// A Live Photo's video, which goes first, hidden, and the still points at it.
    case originalPair
    /// RAW+JPEG's second file.
    case alternate
    /// An edit's rendering, stacked on top of the original.
    case render
    /// An edited Live Photo's rendered video.
    case renderPair

    /// The video half of a Live Photo, which goes hidden.
    var isPairedVideo: Bool { self == .originalPair || self == .renderPair }

    /// The still a paired video belongs to.
    var still: BackupPartRole? {
        switch self {
        case .originalPair: .original
        case .renderPair: .render
        default: nil
        }
    }

    /// The paired video a still waits for.
    var pairedVideo: BackupPartRole? {
        switch self {
        case .original: .originalPair
        case .render: .renderPair
        default: nil
        }
    }
}

/// Where a photo stands with one account's server.
enum BackupPhotoState: Int, Sendable, CaseIterable, Codable {
    /// Not yet fingerprinted and checked with Immich.
    case unchecked = 0
    /// Not in Immich: it goes.
    case toUpload = 1
    /// Not in Immich by its bytes, but Immich has one taken at the same second under the same name: the person decides.
    case anotherForm = 2
    /// The person chose not to send it (in another form).
    case skipped = 3
    /// Every part is in Immich.
    case backedUp = 5
    /// Something stopped it: a fingerprint or an upload failed, with its reason.
    case needsLook = 6
    /// Gone from Immich after Verso saw it in Immich's trash, or let go by the person: never sent again on its own.
    case deletedInImmich = 7
    /// Gone from Immich without Verso seeing it deleted: said once, never sent again without the person's yes.
    case missingFromImmich = 8
    /// In Immich's trash.
    case inImmichTrash = 9
}

/// What the server holds of a fingerprint, for one account.
enum BackupRemoteState: Int, Sendable, Codable {
    case absent = 0
    case present = 1
    case trashed = 2
}

/// What the server says of a fingerprint.
struct BackupCheck: Sendable, Equatable {
    var state: BackupRemoteState
    var assetID: String?
}

/// What the person decided for one photo.
enum BackupDecision: Int, Sendable, Codable {
    /// Send a photo that is in Immich in another form.
    case send = 1
    /// Leave a photo that is in Immich in another form.
    case skip = 2
    /// Send a photo that left Immich again.
    case sendAgain = 3
    /// Let a photo that left Immich go: it moves to Deleted in Immich.
    case letGo = 4
}

/// One part as the rules see it.
struct BackupPartFacts: Sendable, Equatable {
    var role: BackupPartRole
    /// The fingerprint, once taken.
    var checksum: String?
    /// Why the fingerprint could not be taken, shown to the person until it is tried again.
    var failure: String?
    /// What the server said of the fingerprint, once asked.
    var remote: BackupRemoteState?
    /// Verso sent it, or found it there and counted the photo backed up.
    var sent = false
    /// Verso saw it in Immich's trash at a check.
    var seenTrashed = false
}

/// One photo as the rules see it.
struct BackupPhotoFacts: Sendable, Equatable {
    var parts: [BackupPartFacts]
    /// Its state before these facts.
    var previous: BackupPhotoState = .unchecked
    var decision: BackupDecision?
    /// Whether Immich has it in another form: nil until looked at, which the first run does before anything goes.
    var anotherForm: Bool?
    /// Why the last upload of one of its parts failed, if it did.
    var uploadFailure: String?
}

enum BackupRules {
    /// A photo's state from its parts and what the server and the person said.
    static func state(of photo: BackupPhotoFacts) -> (state: BackupPhotoState, reason: String?) {
        // The person said not to send it (Don't Send, or Skip for another form): their word holds, also over a part
        // that could not be read, unless the photo is in Immich whole.
        if photo.decision == .skip, !photo.parts.isEmpty, !photo.parts.allSatisfy({ $0.remote == .present }) {
            return (.skipped, nil)
        }
        if let failure = photo.parts.lazy.compactMap(\.failure).first { return (.needsLook, failure) }
        guard !photo.parts.isEmpty else { return (.needsLook, "Photos has no file for it") }
        guard photo.parts.allSatisfy({ $0.checksum != nil && $0.remote != nil }) else { return (.unchecked, nil) }
        let remotes = photo.parts.map { $0.remote ?? .absent }
        if remotes.allSatisfy({ $0 == .present }) { return (.backedUp, nil) }
        // A part Verso sent or counted, or saw in the trash, that the server no longer has: the photo left Immich.
        let gone = photo.parts.filter { $0.remote == .absent && ($0.sent || $0.seenTrashed) }
        if !gone.isEmpty {
            switch photo.decision {
            case .sendAgain: return photo.uploadFailure.map { (.needsLook, $0) } ?? (.toUpload, nil)
            case .letGo: return (.deletedInImmich, nil)
            default: break
            }
            let deletedOnPurpose = photo.previous == .deletedInImmich || photo.previous == .inImmichTrash
                || gone.contains(where: \.seenTrashed)
            return (deletedOnPurpose ? .deletedInImmich : .missingFromImmich, nil)
        }
        // A part the server never had: a new photo, or a new edit of one that is in Immich.
        if remotes.contains(.absent) {
            if let failure = photo.uploadFailure { return (.needsLook, failure) }
            if wasInImmich(photo) { return (.toUpload, nil) }
            switch photo.decision {
            case .skip: return (.skipped, nil)
            case .send, .sendAgain: return (.toUpload, nil)
            case .letGo, nil: break
            }
            switch photo.anotherForm {
            case nil: return (.unchecked, nil)
            case true?: return (.anotherForm, nil)
            case false?: return (.toUpload, nil)
            }
        }
        return (.inImmichTrash, nil)
    }

    /// Whether a part Verso could not read needs the person: only once it has failed five times over at least three
    /// days, as nearly every such failure passes (an interrupted iCloud download, Verso stopped mid-read).
    static func readNeedsLook(failures: Int, since: Date, now: Date = Date()) -> Bool {
        failures >= 5 && now.timeIntervalSince(since) >= 3 * 24 * 3600
    }

    /// The photo was in Immich once: Verso sent or counted a part of it, or saw one in Immich's trash.
    static func wasInImmich(_ photo: BackupPhotoFacts) -> Bool {
        photo.parts.contains { $0.sent || $0.seenTrashed }
    }

    /// What a weekly check found, before any of it is applied.
    struct Verification: Sendable, Equatable {
        /// Each photo checked, with its state after the check.
        var states: [String: BackupPhotoState] = [:]
        /// Photos that were backed up and are now missing, not yet said: one notification for them all.
        var newlyMissing: [String] = []
        /// Most of the library is gone at once: nothing is applied until the person answers.
        var mostGone = false
        /// How many of the checked photos were backed up before, and how many of those are gone now.
        var wereBackedUp = 0
        var goneNow = 0
    }

    /// The least of a library that counts as "most of it gone at once", and the share of it.
    static let mostGoneMinimum = 20
    static let mostGoneShare = 0.5

    /// A check of photos Verso sent: each photo's new state, the ones newly missing (never one said before), and
    /// whether so many are gone at once that it is a server's problem rather than deletions.
    static func verify(_ photos: [String: BackupPhotoFacts], announced: Set<String>) -> Verification {
        var result = Verification()
        for (identifier, photo) in photos {
            let state = Self.state(of: photo).state
            result.states[identifier] = state
            if photo.previous == .backedUp {
                result.wereBackedUp += 1
                if state == .missingFromImmich || state == .deletedInImmich { result.goneNow += 1 }
            }
            if state == .missingFromImmich && photo.previous != .missingFromImmich && !announced.contains(identifier) {
                result.newlyMissing.append(identifier)
            }
        }
        result.newlyMissing.sort()
        result.mostGone = result.goneNow >= mostGoneMinimum
            && Double(result.goneNow) >= mostGoneShare * Double(max(result.wereBackedUp, 1))
        return result
    }
}

/// The first run's tally, as the Backup page shows it while it checks: "Already in Immich: 87,000. To upload:
/// 13,000, 52 GB."
struct BackupTally: Sendable, Equatable {
    var total = 0
    var checked = 0
    var alreadyInImmich = 0
    var toUpload = 0
    var toUploadBytes: Int64 = 0
    var anotherForm = 0
    var skipped = 0
    var needsLook = 0
    var inImmichTrash = 0
    var deletedInImmich = 0
    var missingFromImmich = 0

    /// The tally of photos in their states, and the bytes of the parts still to go.
    init(states: [BackupPhotoState: Int] = [:], toUploadBytes: Int64 = 0) {
        for (state, count) in states {
            total += count
            switch state {
            case .unchecked: break
            case .toUpload: toUpload += count
            case .anotherForm: anotherForm += count
            case .skipped: skipped += count
            case .backedUp: alreadyInImmich += count
            case .needsLook: needsLook += count
            case .deletedInImmich: deletedInImmich += count
            case .missingFromImmich: missingFromImmich += count
            case .inImmichTrash: inImmichTrash += count
            }
            if state != .unchecked { checked += count }
        }
        self.toUploadBytes = toUploadBytes
    }

    /// Whether every photo has been looked at.
    var isComplete: Bool { checked == total }
}

/// Photos Immich has in another form: not in Immich by their bytes, but with one taken at the same second under the
/// same name, an export or the rendering of an edit another app sent alone. Never uploaded on their own: the first run
/// lists them for the person.
enum BackupAnotherForm {
    /// A photo on the phone, as the match reads it.
    struct Local: Sendable, Equatable {
        let identifier: String
        /// When it was taken, in whole seconds since 1970.
        let takenSecond: Int64
        let name: String
        /// The same wall-clock time read as UTC, as Immich files a photo whose file names no time zone (a camera's,
        /// where Photos reads it in the phone's zone).
        var wallClockSecond: Int64?
    }

    /// An asset on the server, as a month of the timeline gives it: its id and when it was taken.
    struct Remote: Sendable, Equatable {
        let assetID: String
        let takenSecond: Int64
    }

    /// The server's assets taken at each local photo's second: the ones whose names are worth reading.
    static func sameSecond(_ locals: [Local], _ remotes: [Remote]) -> [String: [String]] {
        var bySecond: [Int64: [String]] = [:]
        for remote in remotes { bySecond[remote.takenSecond, default: []].append(remote.assetID) }
        var matches: [String: [String]] = [:]
        for local in locals {
            var assets = bySecond[local.takenSecond] ?? []
            if let wallClock = local.wallClockSecond, wallClock != local.takenSecond { assets += bySecond[wallClock] ?? [] }
            if !assets.isEmpty { matches[local.identifier] = assets }
        }
        return matches
    }

    /// Whether two file names are the same photo's: the same name before the extension, ignoring case, as an export
    /// changes the extension (IMG_0001.HEIC sent as IMG_0001.JPG) and some apps add an edit's suffix.
    static func sameName(_ local: String, _ remote: String) -> Bool {
        let localStem = stem(local)
        let remoteStem = stem(remote)
        // A name that is only an extension names nothing.
        guard !localStem.isEmpty, !localStem.hasPrefix(".") else { return false }
        if localStem == remoteStem { return true }
        // Immich's app and others name an edit's rendering after the original with a suffix: IMG_0001_edited.
        for suffix in ["_edited", "-edited", " (edited)", "_e"] where remoteStem == localStem + suffix { return true }
        return false
    }

    private static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// The whole second of a date, as both sides are compared.
    static func second(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}

/// The disk budget for upload bodies and downloaded originals: at most 2 GB or a tenth of the free space, always
/// leaving 1 GB free. A file larger than the budget (a long 4K video) goes alone, with nothing else held, as long as the
/// 1 GB stays free: otherwise it could never go at all.
enum BackupDiskBudget {
    static let ceiling: Int64 = 2 << 30
    static let reserve: Int64 = 1 << 30

    static func budget(free: Int64) -> Int64 { min(ceiling, free / 10) }

    /// Whether `size` more bytes fit, with `used` already held by Verso's other files and `free` free on the device.
    static func fits(_ size: Int64, used: Int64, free: Int64) -> Bool {
        guard free - size >= reserve else { return false }
        return used == 0 || used + size <= budget(free: free)
    }

    /// Whether a file of `size` is larger than the budget, so it goes only with nothing else held.
    static func goesAlone(_ size: Int64, free: Int64) -> Bool {
        size > budget(free: free)
    }

    /// The free space a file of `size` needs before it fits with nothing else held.
    static func freeNeeded(for size: Int64) -> Int64 {
        size + reserve
    }
}

/// Free Up Space's rules (ROADMAP.md, M10, "Free Up Space"; ARCHITECTURE.md, "Free Up Space"), as plain values: a
/// photo's age, the periods offered, the months the review groups by, and when the reminder and the Library's cards may
/// come.
enum FreeUpRules {
    /// Keep on This iPhone's periods, in months; Forever is none.
    static let periods = [1, 3, 6, 12, 24]

    /// When a photo began to count as old: the later of when it was taken and when it came to the phone, so a photo
    /// old in years but only just received is not removed at once.
    static func ageStart(created: Date?, added: Date?) -> Date? {
        switch (created, added) {
        case let (created?, added?): max(created, added)
        case let (one?, nil), let (nil, one?): one
        default: nil
        }
    }

    /// The moment before which a photo is old enough to go, keeping `months`.
    static func cutoff(months: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: -months, to: now) ?? now
    }

    /// Enough to be worth the person's time: about a gigabyte.
    static var worthReminding: Int64 {
        #if DEBUG
        // Verso Dev's walk (FreeUpSpaceWalkTests), whose lab photos come to a few megabytes.
        if let bytes = ProcessInfo.processInfo.environment["VERSO_FREE_UP_WORTH"].flatMap(Int64.init) { return bytes }
        #endif
        return 1 << 30
    }

    private static let month: TimeInterval = 30 * 24 * 3600

    /// The reminder comes at most once a month, and only when there is real space to gain.
    static func remind(bytes: Int64, lastReminded: Date?, now: Date = Date()) -> Bool {
        guard bytes >= worthReminding else { return false }
        guard let lastReminded else { return true }
        return now.timeIntervalSince(lastReminded) >= month
    }

    /// The Library's card for what is ready to free: with real space to gain, and, once the person has opened its
    /// review or said Not Now, again a month later, or sooner once another gigabyte is ready.
    static func cardShown(bytes: Int64, putAside: (date: Date, bytes: Int64)?, now: Date = Date()) -> Bool {
        guard bytes >= worthReminding else { return false }
        guard let putAside else { return true }
        return now.timeIntervalSince(putAside.date) >= month || bytes >= putAside.bytes + worthReminding
    }

    /// What the Library's card offers to free while Keep on This iPhone is Forever and the phone runs short of space:
    /// the photos older than a year.
    static let offerMonths = 12

    /// The phone runs short of space: under 5 GB free, or under a tenth of it.
    static func lowOnSpace(free: Int64, total: Int64) -> Bool {
        free < 5_000_000_000 || (total > 0 && free * 10 < total)
    }

    /// The Library's card for a phone short of space: with real space to gain, and after Not Now, again in three
    /// months.
    static func spaceCardShown(bytes: Int64, putAside: Date?, now: Date = Date()) -> Bool {
        guard bytes >= worthReminding else { return false }
        guard let putAside else { return true }
        return now.timeIntervalSince(putAside) >= 3 * month
    }

    /// The month a photo is listed under in the review, as "2025-05".
    static func month(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// The `mobile-app` metadata Immich's own iPhone app keeps with each asset it uploads: the photo's iCloud identifier,
/// when it was taken, when it was last edited, and where. That app matches a phone's photo to an asset when all of them
/// agree, so a reinstall or a second device need not read the photo again. Verso writes the same with its uploads, so
/// that app knows them, and reads it to take an original only in iCloud's fingerprint from Immich rather than download
/// it. Both for photos never edited only: that app reads an edit's time through a key of PhotoKit's that is not public,
/// which Verso does not use, so only "no edit" is known to agree on both sides.
enum BackupMobileApp {
    static let key = "mobile-app"

    /// The upload's `metadata` field for a photo never edited, or nil where it could not match (no iCloud identifier,
    /// or one iCloud has not finished, ending in ":").
    static func field(cloudID: String?, created: Date?, latitude: Double?, longitude: Double?) -> String? {
        guard let cloudID, !cloudID.isEmpty, !cloudID.hasSuffix(":"), let created else { return nil }
        var value = ["iCloudId": cloudID, "createdAt": format(created)]
        if let latitude, let longitude {
            value["latitude"] = "\(latitude)"
            value["longitude"] = "\(longitude)"
        }
        let items: [[String: Any]] = [["key": key, "value": value]]
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an asset's metadata is this photo's, as that app decides: the same iCloud identifier, the same second
    /// taken, the same place, and no edit on either side (the caller knows the phone's).
    static func matches(_ value: [String: String], cloudID: String, created: Date, latitude: Double?, longitude: Double?) -> Bool {
        guard value["iCloudId"] == cloudID, value["adjustmentTime"] == nil,
              let taken = value["createdAt"].flatMap(parse),
              BackupAnotherForm.second(taken) == BackupAnotherForm.second(created) else { return false }
        return same(value["latitude"].flatMap(Double.init), latitude) && same(value["longitude"].flatMap(Double.init), longitude)
    }

    private static func same(_ remote: Double?, _ local: Double?) -> Bool {
        switch (remote, local) {
        case (nil, nil): true
        case let (remote?, local?): abs(remote - local) < 1e-9
        default: false
        }
    }

    /// As that app writes it: UTC to the whole second, with milliseconds, "2024-05-01T10:00:00.000Z".
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Where backing up keeps its files: upload bodies and downloaded originals, in Application Support. The store keeps
/// their paths relative to this folder, which moves with the app's container, which iOS does not promise to keep in
/// one place across an update or a restore.
struct BackupFiles: Sendable {
    let root: URL
    var uploads: URL { root.appendingPathComponent("Uploads", isDirectory: true) }
    var staged: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

    static let standard = BackupFiles(root: URL.applicationSupportDirectory.appendingPathComponent("Backup", isDirectory: true))

    /// The folders, kept out of the phone's own backup (iCloud Backup, a computer's): they hold copies of what the
    /// library holds already, up to the disk budget.
    func prepare() {
        for directory in [uploads, staged] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
    }

    /// A file's path as the store keeps it: relative to the folder.
    func kept(_ path: String) -> String {
        let prefix = root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// A kept path where the file is now. One kept whole (by Verso before it kept them relative) is found by its
    /// folder and name under the folder's place today.
    func path(_ kept: String) -> String {
        guard kept.hasPrefix("/") else { return root.appendingPathComponent(kept).path }
        let components = Array((kept as NSString).pathComponents.suffix(3))
        guard components.count == 3, components[0] == root.lastPathComponent,
              [uploads.lastPathComponent, staged.lastPathComponent].contains(components[1]) else { return kept }
        return root.appendingPathComponent(components[1]).appendingPathComponent(components[2]).path
    }

    /// The bytes Verso's backup files take now.
    func usedBytes() -> Int64 {
        var total: Int64 = 0
        for directory in [uploads, staged] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }

    /// The free space the system would give Verso for something the person asked for.
    func freeBytes() -> Int64 {
        let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Removes every file nothing uses: what an earlier run left when it ended before it could clean up. Files are
    /// told apart by their folder and name, whatever path leads to the container.
    func sweep(keeping used: Set<String>) {
        let keeping = Set(used.map { (($0 as NSString).pathComponents.suffix(2)).joined(separator: "/") })
        for directory in [uploads, staged] {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where !keeping.contains(directory.lastPathComponent + "/" + file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Working out at launch what the journal's unfinished steps came to, from facts: an upload whose task the session
/// still carries is left to it; any other upload is asked of the server by its fingerprint (there: it arrived, as a
/// resend would only be a duplicate; absent: it did not, and goes again); a stack or metadata step is done again, as
/// both are the same however often they run.
enum BackupRecovery {
    struct Plan: Sendable, Equatable {
        var leave: [Int64] = []
        var ask: [Int64] = []
        var redo: [Int64] = []
    }

    static func plan(_ steps: [BackupStep], tasksOnTheirWay: Set<Int>) -> Plan {
        var plan = Plan()
        for step in steps {
            switch step.kind {
            case .upload:
                if let task = step.task, tasksOnTheirWay.contains(task) { plan.leave.append(step.id) } else { plan.ask.append(step.id) }
            case .stack, .metadata:
                plan.redo.append(step.id)
            }
        }
        return plan
    }

    /// An upload's result from the server's answer about its fingerprint.
    static func result(of check: BackupCheck?) -> (result: String, assetID: String?, arrived: Bool) {
        guard let check, check.state != .absent, let asset = check.assetID else { return ("lost", nil, false) }
        return ("duplicate", asset, true)
    }
}
