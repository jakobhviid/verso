// Backing up under the Library's title (SPEC.md, "Backing the iPhone up"), in the place an import's progress
// has (LibraryImportLine), which it gives way to while an import shows: while photos go, a small cloud and how many,
// as Photos says "Syncing 1 Item…" ("Backing Up 3 Items…"); otherwise the ring with "Checking with Immich" on the
// first run, what it waits for (Wi-Fi, a connection, Immich, free space: calm, as it goes on by itself), the photos that
// need a look, or why it stopped. A tap opens the Backup page (BackupCenter.showPage). It shows only while there is
// something to say: never while backing up is off or everything is in Immich.

import SwiftUI

struct BackupLibraryLine: View {
    let services: AccountServices

    /// Whether backing up has something to say under the Library's title.
    @MainActor static var isShown: Bool { line(BackupCenter.shared.snapshot) != nil }

    var body: some View {
        let snapshot = BackupCenter.shared.snapshot
        Button {
            BackupCenter.shared.showPage()
        } label: {
            HStack(spacing: 6) {
                if Self.isBackingUp(snapshot) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                } else {
                    ImportRing(progress: Self.ring(snapshot), size: 17)
                }
                Text(Self.line(snapshot) ?? "")
                    .lineLimit(1)
            }
            .font(.headline)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Backup Line")
        .accessibilityHint("Shows the backup")
    }

    /// What the line says, or nil when backing up has nothing to say.
    static func line(_ snapshot: BackupSnapshot) -> String? {
        let going = snapshot.going
        let needsLook = snapshot.tally.needsLook
        switch snapshot.phase {
        case .off, .signedOut, .publicDemo: return nil
        case .upToDate:
            guard needsLook > 0 else { return nil }
            return needsLook == 1 ? "1 Needs a Look" : "\(needsLook.formatted()) Need a Look"
        case .noAccess: return "Backup Needs All Photos"
        case .reading: return "Reading Your Library…"
        case .checking: return snapshot.immichOutOfReachSince != nil ? "Waiting for Immich" : "Checking with Immich…"
        case .waitingForStart: return "Ready to Back Up"
        case .backingUp:
            if let waiting = waiting(snapshot) { return waiting }
            if BackupStatus.retry(snapshot) != nil { return "Waiting to Try Again" }
            guard going > 0 else {
                let toCheck = snapshot.tally.total - snapshot.tally.checked
                return toCheck > 0 ? "Checking with Immich…" : nil
            }
            return BackupOnItsWay.line(going: going)
        case .stopped(.unauthorized): return "Backup Needs Sign-In"
        case .stopped(.notAllowed): return "Backup Not Allowed"
        case .stopped(.unreachable): return "Waiting for Immich"
        case .stopped(.full): return "Immich Is Full"
        case .stopped(.mostGone): return "Backup Stopped"
        }
    }

    /// What backing up waits for, in the line's own short words (BackupStatus has the page's).
    private static func waiting(_ snapshot: BackupSnapshot) -> String? {
        guard BackupStatus.waiting(snapshot) != nil else { return nil }
        if snapshot.needsSpace != nil { return "Needs Free Space" }
        if !snapshot.connected { return "Waiting for a Connection" }
        if snapshot.constrained { return "Paused for Low Data Mode" }
        if snapshot.onCellular { return "Waiting for Wi-Fi" }
        return "Waiting for Immich"
    }

    /// Photos are going, which the cloud says beside their count, as Photos' line has it.
    private static func isBackingUp(_ snapshot: BackupSnapshot) -> Bool {
        guard case .backingUp = snapshot.phase, snapshot.going > 0 else { return false }
        return waiting(snapshot) == nil
    }

    /// The import's ring, filling as the library is backed up, or with a warning when it stopped.
    private static func ring(_ snapshot: BackupSnapshot) -> ImportProgress {
        var progress = ImportProgress(backupPhase: .working)
        let tally = snapshot.tally
        switch snapshot.phase {
        case .stopped(.unreachable):
            progress.progress = tally.total == 0 ? nil : Double(tally.alreadyInImmich) / Double(tally.total)
        case .stopped, .noAccess:
            progress.phase = .attention
        case .reading:
            progress.phase = .looking
        case .checking, .waitingForStart:
            progress.progress = tally.total == 0 ? nil : Double(tally.checked) / Double(tally.total)
        default:
            progress.progress = tally.total == 0 ? nil : Double(tally.alreadyInImmich) / Double(tally.total)
        }
        return progress
    }
}

extension ImportProgress {
    /// The ring's state for backing up, which has no import behind it.
    init(backupPhase: Phase, progress: Double? = nil) {
        phase = backupPhase
        title = ""
        detail = nil
        self.progress = progress
    }
}

/// Backing up's word after the Library's number of items at its newest end, while nothing more urgent is said: "· Backed
/// Up", or "· 2.3 GB to Free" in the tint once Free Up Space has a period and photos to free. A tap opens the Backup
/// page, or the review where there is something to free.
struct BackupCountAccessory: View {
    @MainActor static var isShown: Bool {
        let center = BackupCenter.shared
        return center.settings.isOn && center.snapshot.phase == .upToDate
    }

    var body: some View {
        let center = BackupCenter.shared
        let toFree = Self.toFree(center.snapshot)
        Button {
            if toFree { center.showFreeUp() } else { center.showPage() }
        } label: {
            Text(Self.words(center.snapshot))
                .font(.headline)
                .foregroundStyle(toFree ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Backup Count Line")
        .accessibilityHint(toFree ? "Reviews what can go" : "Shows the backup")
    }

    /// Something is ready to free: the words are a link, in the tint, to the review.
    private static func toFree(_ snapshot: BackupSnapshot) -> Bool {
        (snapshot.freeable?.count ?? 0) > 0
    }

    static func words(_ snapshot: BackupSnapshot) -> String {
        if let freeable = snapshot.freeable, freeable.count > 0 {
            return String(localized: " · \(freeable.bytes.formatted(.byteCount(style: .file))) to Free")
        }
        return String(localized: " · Backed Up")
    }
}
