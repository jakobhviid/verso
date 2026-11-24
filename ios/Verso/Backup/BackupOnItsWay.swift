// What is on its way to Immich (ROADMAP.md, M10, "Backing the iPhone up"), as plain values and pure rules with no
// PhotoKit, no network and no views, so the logic tests (ios/VersoTests) run them as they are:
// - a photo waiting or uploading, as the store lists it for On Its Way on the Backup page and for the Library;
// - which photos are new: those that came to the phone after backing up was switched on for the account (or, on a
//   store from before that was kept, after the first run's Start), which the Library shows among Immich's photos until
//   they arrive; the first run's backlog stays on the Backup page;
// - the small mark each tile carries: a ring filling while it uploads, a cloud with an upward arrow while it waits, a
//   clock while the connection keeps it back (cellular not allowed for its kind, Low Data Mode, no connection), and an
//   exclamation mark when it needs a look, which a stop (sign in again, a full server, most of the library gone) is
//   for every photo, as nothing goes until the person answers.
// Only While Charging holds backing up on its own, which runs while Verso is closed; while Verso is open it sends, so
// a tile never waits for charging there.

import Foundation

/// A photo on the phone on its way to Immich: waiting, uploading, or needing a look.
struct BackupWaitingPhoto: Sendable, Equatable, Identifiable {
    var localID: String
    /// When it was taken, which places it among Immich's photos.
    var created: Date?
    /// When it came to the phone.
    var added: Date?
    var isVideo: Bool
    var favorite: Bool
    var state: BackupPhotoState
    /// A part of it is being sent now.
    var uploading: Bool

    var id: String { localID }

    /// Its ID in a grid's selection, beside Immich's asset IDs, which never begin so.
    var gridID: String { BackupWaitingPhoto.gridPrefix + localID }

    static let gridPrefix = "phone:"

    /// The local identifier a grid ID names, if it names a photo on the phone.
    static func localID(gridID: String) -> String? {
        gridID.hasPrefix(gridPrefix) ? String(gridID.dropFirst(gridPrefix.count)) : nil
    }
}

/// The small mark a photo on its way carries on its tile.
enum BackupTileMark: Sendable, Equatable {
    /// A ring filling as it uploads, with how much has gone when it is known.
    case uploading(Double?)
    /// A cloud with an upward arrow: it goes as soon as its turn comes.
    case waiting
    /// A clock: the connection keeps it back (Wi-Fi needed, Low Data Mode, or none).
    case waitingForConnection
    /// An exclamation mark: it needs a look, or backing up stopped until the person answers.
    case needsLook

    /// What it says in words, for VoiceOver and the viewer's title.
    var words: String {
        switch self {
        case .uploading: "Uploading to Immich"
        case .waiting: "On its way to Immich"
        case .waitingForConnection: "Waiting for Wi-Fi"
        case .needsLook: "Needs a look"
        }
    }
}

/// What the connection allows now, as the settings read it.
struct BackupConnection: Sendable, Equatable {
    var connected = true
    var onCellular = false
    /// Low Data Mode, which backing up respects.
    var constrained = false
    var cellularPhotos = false
    var cellularVideos = false

    /// Whether a photo or video may go now.
    func allows(video: Bool) -> Bool {
        connected && !constrained && (!onCellular || (video ? cellularVideos : cellularPhotos))
    }
}

enum BackupOnItsWay {
    /// Whether a photo is new for the Library: it came to the phone (its `added`, or its `created` where Photos gives
    /// no date added) after `since`, when backing up was switched on. Nothing is new before that is known.
    static func isNew(added: Date?, created: Date?, since: Date?) -> Bool {
        guard let since, let came = added ?? created else { return false }
        return came > since
    }

    /// The date new photos count from: when backing up was switched on for the account, or, on a store kept from
    /// before that date was written, when the first run started.
    static func newSince(switchedOn: Date?, firstRunStarted: Date?) -> Date? {
        switchedOn ?? firstRunStarted
    }

    /// A tile's mark. `stopped`: backing up stopped and waits for the person (sign in again, a full server, most of the
    /// library gone).
    static func mark(_ photo: BackupWaitingPhoto, progress: Double?, connection: BackupConnection,
                     stopped: Bool) -> BackupTileMark {
        if stopped || photo.state == .needsLook { return .needsLook }
        if !connection.allows(video: photo.isVideo) { return .waitingForConnection }
        if photo.uploading { return .uploading(progress) }
        return .waiting
    }

    /// The line under the Library's title while photos go, as Photos says "Syncing 1 Item…": "Backing Up 1 Item…",
    /// "Backing Up 3 Items…".
    static func line(going: Int) -> String {
        going == 1 ? "Backing Up 1 Item…" : "Backing Up \(going.formatted()) Items…"
    }
}
