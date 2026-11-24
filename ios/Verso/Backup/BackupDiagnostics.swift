// Verso Dev's view into backing up on a real device: what each photo still to upload, to check or needing a look is
// waiting for, written as text into the app's own Documents folder, which the Mac can copy from a development build
// (`xcrun devicectl device copy from --domain-type appDataContainer`), as iOS lets it read no App Group container. At
// launch, before the first pass changes anything (`backup-diagnostics-launch.txt`), and after each pass
// (`backup-diagnostics.txt`). Identifiers, fingerprints and states only: no photo, no credential. Not in a release.

#if DEBUG
import Foundation

enum BackupDiagnostics {
    static func write(store: BackupStore, account: String, snapshot: BackupSnapshot, note: String, launch: Bool) {
        var lines: [String] = []
        let now = Date()
        func when(_ date: Date?) -> String {
            guard let date else { return "-" }
            let seconds = Int(date.timeIntervalSince(now))
            return "\(date.formatted(date: .omitted, time: .standard)) (\(seconds >= 0 ? "in" : "ago") \(abs(seconds))s)"
        }
        lines.append("Verso Dev backup diagnostics, \(now.formatted(date: .numeric, time: .standard)): \(note)")
        let tally = snapshot.tally
        lines.append("phase \(snapshot.phase); total \(tally.total), checked \(tally.checked), in Immich \(tally.alreadyInImmich), "
                     + "to upload \(tally.toUpload) (\(tally.toUploadBytes) bytes), needs a look \(tally.needsLook), "
                     + "another form \(tally.anotherForm), trash \(tally.inImmichTrash), skipped \(tally.skipped)")
        lines.append("going \(snapshot.going), on their way \(snapshot.onTheirWay), connected \(snapshot.connected), "
                     + "cellular \(snapshot.onCellular), constrained \(snapshot.constrained), needs space \(snapshot.needsSpace.map(String.init) ?? "-"), "
                     + "out of reach since \(when(snapshot.immichOutOfReachSince)), error \(snapshot.error ?? "-")")
        lines.append("")
        lines.append("meta:")
        let meta = (try? store.database.query("SELECT key, value FROM meta ORDER BY key", []) { row in
            (row.text(0) ?? "", row.text(1) ?? "<data>")
        }) ?? []
        for (key, value) in meta where !key.hasPrefix("token") {
            lines.append("  \(key) = \(value.prefix(80))")
        }
        lines.append("")
        lines.append("open steps:")
        let open = (try? store.openSteps()) ?? []
        for step in open.prefix(50) {
            lines.append("  #\(step.id) \(step.kind.rawValue) \(step.localID.prefix(12)) \(step.role?.rawValue ?? "-") task \(step.task.map(String.init) ?? "-") started \(when(step.started))")
        }
        lines.append("")
        // The photos the tally counts as to upload, to check or needing a look, as counts() filters them.
        let states = [BackupPhotoState.toUpload, .unchecked, .needsLook].map(\.rawValue)
        let photos = (try? store.database.query("""
        SELECT b.local_id, b.state, coalesce(b.reason, '-'), b.decision, coalesce(b.upload_failure, '-'), b.uploaded,
               b.finished, coalesce(b.another_form, '-'), p.kind, p.subtypes, p.parts_read, p.created, p.cloud_id
        FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND p.gone = 0 AND p.hidden = 0 AND b.state IN (\(states.map(String.init).joined(separator: ",")))
        ORDER BY b.state, p.created DESC LIMIT 60
        """, [account]) { row in
            (row.text(0) ?? "", row.int(1), row.text(2) ?? "", row.optionalInt(3), row.text(4) ?? "", row.int(5), row.int(6),
             row.text(7) ?? "", row.int(8), row.int(9), row.int(10), row.date(11), row.text(12) != nil)
        }) ?? []
        for photo in photos {
            let state = BackupPhotoState(rawValue: photo.1).map { "\($0)" } ?? "\(photo.1)"
            lines.append("photo \(photo.0.prefix(12)) \(state): kind \(photo.8), subtypes \(photo.9), parts read \(photo.10), "
                         + "taken \(photo.11.map { $0.formatted(date: .numeric, time: .shortened) } ?? "-"), iCloud id \(photo.12), "
                         + "decision \(photo.3.map(String.init) ?? "-"), uploaded \(photo.5), finished \(photo.6), "
                         + "another form \(photo.7)")
            if photo.2 != "-" { lines.append("  reason: \(photo.2)") }
            if photo.4 != "-" { lines.append("  upload failure: \(photo.4)") }
            for part in (try? store.parts(photo.0)) ?? [] {
                let remote = part.checksum.flatMap { try? store.remoteState(account: account, checksum: $0) }
                lines.append("  part \(part.role.rawValue) \(part.name) \(part.uti ?? "-"): fingerprint \(part.checksum == nil ? "none" : "yes")"
                             + "\(part.borrowed ? " (borrowed)" : ""), size \(part.size.map(String.init) ?? "-"), "
                             + "remote \(remote.map { "\($0)" } ?? "-"), failures \(part.failures), first failure \(when(part.firstFailure)), "
                             + "retry \(when(part.retryAfter)), staged \(part.staged == nil ? "no" : (FileManager.default.fileExists(atPath: part.staged ?? "") ? "yes" : "missing"))")
                if let failure = part.failure { lines.append("    failure: \(failure)") }
            }
            let steps = (try? store.database.query("""
            SELECT id, step, coalesce(role, '-'), coalesce(result, 'open'), started, finished, task FROM journal
            WHERE account = ? AND local_id = ? ORDER BY id DESC LIMIT 6
            """, [account, photo.0]) { row in
                "#\(row.int64(0)) \(row.text(1) ?? "") \(row.text(2) ?? "") \(row.text(3) ?? "") started \(when(row.date(4))) finished \(when(row.date(5))) task \(row.optionalInt(6).map(String.init) ?? "-")"
            }) ?? []
            for step in steps { lines.append("  step \(step)") }
        }
        lines.append("")
        lines.append("steps of the last 6 hours that did not land (every account):")
        let since = now.addingTimeInterval(-6 * 3600)
        let unlanded = (try? store.database.query("""
        SELECT id, step, local_id, coalesce(role, '-'), coalesce(result, 'open'), started, finished, task FROM journal
        WHERE started > ? AND (result IS NULL OR result NOT IN ('created', 'duplicate', 'stacked', 'set'))
        ORDER BY id DESC LIMIT 80
        """, [since]) { row in
            "#\(row.int64(0)) \(row.text(1) ?? "") \(row.text(2)?.prefix(12) ?? "") \(row.text(3) ?? "") \(row.text(4) ?? "") started \(when(row.date(5))) finished \(when(row.date(6))) task \(row.optionalInt(7).map(String.init) ?? "-")"
        }) ?? []
        for step in unlanded { lines.append("  \(step)") }
        lines.append("")
        lines.append("parts that failed to be read and wait to be tried again:")
        let failing = (try? store.database.query("""
        SELECT local_id, role, failures, first_failure, retry_after, coalesce(failure, '-'), wait_reason FROM part
        WHERE failures > 0 OR (checksum IS NULL AND retry_after IS NOT NULL) ORDER BY retry_after LIMIT 40
        """, []) { row in
            "\(row.text(0)?.prefix(12) ?? "") \(row.text(1) ?? ""): failures \(row.int(2)), first \(when(row.date(3))), retry \(when(row.date(4))), failure \(row.text(5) ?? ""), waits: \(row.text(6) ?? "-")"
        }) ?? []
        for part in failing { lines.append("  \(part)") }
        let folder = URL.documentsDirectory
        let name = launch ? "backup-diagnostics-launch.txt" : "backup-diagnostics.txt"
        try? lines.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
#endif
