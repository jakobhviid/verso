// What backing up waits for, in the person's words, the same on the Backup page, the Library's line and the Live
// Activity (ARCHITECTURE.md, "Backing the iPhone up", on errors): a state Verso goes on from by itself, said calmly in
// grey, never as an error. Only what the person must put right is a stop (BackupStop) or Needs a Look.

import Foundation

enum BackupStatus {
    /// What backing up waits for now, or nil when it waits for nothing.
    static func waiting(_ snapshot: BackupSnapshot, settings: BackupSettings = .current) -> String? {
        if let needed = snapshot.needsSpace {
            return String(localized: "Needs \(needed.formatted(.byteCount(style: .file))) free on this \(DeviceWords.model)")
        }
        if !snapshot.connected { return String(localized: "Waiting for a connection") }
        let going = snapshot.going > 0
        if going && snapshot.constrained { return String(localized: "Paused for Low Data Mode") }
        if going && snapshot.onCellular && !(settings.cellularPhotos && settings.cellularVideos) {
            return String(localized: "Waiting for Wi-Fi")
        }
        if case .stopped(.unreachable) = snapshot.phase {
            if let until = snapshot.pausedUntil {
                return String(localized: "Waiting for Immich, trying again at \(until.formatted(date: .omitted, time: .shortened))")
            }
            return String(localized: "Waiting for Immich")
        }
        if snapshot.immichOutOfReachSince != nil { return String(localized: "Waiting for Immich") }
        return nil
    }

    /// What waits to be tried again, and when, while no pass runs: "1 waits, trying again at 11:35", "3 still to check,
    /// trying again at 14:32"; nil where nothing waits.
    static func retry(_ snapshot: BackupSnapshot) -> String? {
        guard let next = snapshot.nextRetry, snapshot.onTheirWay == 0 else { return nil }
        let time = next.formatted(date: .omitted, time: .shortened)
        let toCheck = snapshot.tally.total - snapshot.tally.checked
        if snapshot.going > 0 {
            return snapshot.going == 1 ? String(localized: "1 waits, trying again at \(time)")
                : String(localized: "\(snapshot.going.formatted()) wait, trying again at \(time)")
        }
        guard toCheck > 0 else { return nil }
        return toCheck == 1 ? String(localized: "1 still to check, trying again at \(time)")
            : String(localized: "\(toCheck.formatted()) still to check, trying again at \(time)")
    }

    /// "3,523 items", "1 item".
    static func itemCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count.formatted()) items")
    }

    /// "3 need a look", "1 needs a look".
    static func needLook(_ count: Int) -> String {
        count == 1 ? String(localized: "1 needs a look") : String(localized: "\(count.formatted()) need a look")
    }

    /// How much is left to go: "69 items · 403 MB".
    static func toGo(_ count: Int, bytes: Int64) -> String {
        let items = itemCount(count)
        return bytes > 0 ? "\(items) · \(bytes.formatted(.byteCount(style: .file)))" : items
    }
}
