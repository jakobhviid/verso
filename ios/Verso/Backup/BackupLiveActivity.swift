// Backing up's own Live Activity (ARCHITECTURE.md, "Backing the iPhone up"), drawn by the widget extension
// (ios/Widgets), for what backing up does on its own: the first run's check, and a run of at least `smallestRun` items.
// iOS lets an app start one only while it is open, so it starts while Verso is in front and is kept up to date from
// the background; a run iOS starts overnight with Verso closed cannot put one up. It stays away while a run the person
// started shows with the system's own progress (BackupScheduler), so there are never two, and takes over once that
// one is gone, as after Verso was ended mid-check. It ends with how the run ended, left on the Lock Screen a while.

import ActivityKit
import Foundation

@MainActor
enum BackupLiveActivity {
    /// The fewest items on their way worth an activity: fewer go in seconds, and their tiles' rings show them.
    static let smallestRun = 5

    private static var activity: Activity<BackupActivityAttributes>?
    private static var shown: BackupActivityAttributes.ContentState?
    /// The most items on their way since the activity started, so it can say how far the run has gone.
    private static var runTotal = 0

    /// Follows the snapshot: starts, updates or ends the activity.
    static func follow(_ snapshot: BackupSnapshot, foreground: Bool, systemShowsRun: Bool) {
        // One left from before Verso was ended goes on being kept.
        if activity == nil { activity = Activity<BackupActivityAttributes>.activities.first }
        if systemShowsRun {
            end(nil, after: nil)
            return
        }
        // The run's size counts from when an activity follows it.
        runTotal = activity != nil || (foreground && worthOne(snapshot)) ? max(runTotal, snapshot.going) : 0
        guard let state = state(snapshot) else {
            end(nil, after: nil)
            return
        }
        let finished = state.stage == .done || state.stage == .stopped
        if let activity {
            if finished {
                end(state, after: 15 * 60)
            } else if state != shown {
                shown = state
                // ActivityKit's own object, which it updates from any thread.
                nonisolated(unsafe) let updating = activity
                Task { await updating.update(ActivityContent(state: state, staleDate: nil)) }
            }
        } else if foreground, !finished, worthOne(snapshot), ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: BackupActivityAttributes(),
                                                content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                shown = state
            } catch {
                // Not allowed now (Live Activities switched off for Verso, or too many): the page says it all.
            }
        }
    }

    private static func worthOne(_ snapshot: BackupSnapshot) -> Bool {
        switch snapshot.phase {
        case .reading, .checking: true
        case .backingUp: snapshot.going >= smallestRun
        default: false
        }
    }

    /// The activity's words for the snapshot, or nil where there is nothing to follow.
    private static func state(_ snapshot: BackupSnapshot) -> BackupActivityAttributes.ContentState? {
        let tally = snapshot.tally
        let backingUp = String(localized: "Backing up to Immich")
        switch snapshot.phase {
        case .off, .noAccess, .signedOut, .publicDemo:
            return nil
        case .reading(let count):
            return .init(stage: .checking, title: String(localized: "Reading your library"),
                         detail: String(localized: "\(count.formatted()) items so far"), done: 0, total: 0)
        case .checking:
            if let waiting = BackupStatus.waiting(snapshot) ?? BackupStatus.retry(snapshot) {
                return .init(stage: .waiting, title: String(localized: "Checking with Immich"), detail: waiting,
                             done: tally.checked, total: tally.total)
            }
            return .init(stage: .checking, title: String(localized: "Checking with Immich"),
                         detail: String(localized: "\(tally.checked.formatted()) of \(tally.total.formatted()) checked"),
                         done: tally.checked, total: tally.total)
        case .waitingForStart:
            return .init(stage: .done, title: String(localized: "Ready to back up"),
                         detail: String(localized: "\(BackupStatus.toGo(tally.toUpload, bytes: tally.toUploadBytes)) to upload"),
                         done: 1, total: 1)
        case .backingUp:
            let total = max(runTotal, snapshot.going)
            let done = total - snapshot.going
            if let waiting = BackupStatus.waiting(snapshot) ?? BackupStatus.retry(snapshot) {
                return .init(stage: .waiting, title: backingUp, detail: waiting, done: done, total: total)
            }
            return .init(stage: .backingUp, title: backingUp,
                         detail: String(localized: "\(BackupStatus.toGo(snapshot.going, bytes: tally.toUploadBytes)) to go"),
                         done: done, total: total)
        case .upToDate:
            let sent = runTotal
            let title = sent == 0 ? String(localized: "Backup is up to date")
                : sent == 1 ? String(localized: "Backed up 1 item") : String(localized: "Backed up \(sent.formatted()) items")
            let detail = tally.needsLook > 0 ? BackupStatus.needLook(tally.needsLook)
                : String(localized: "Everything is in Immich")
            return .init(stage: .done, title: title, detail: detail, done: 1, total: 1)
        case .stopped(.unreachable):
            return .init(stage: .waiting, title: backingUp, detail: BackupStatus.waiting(snapshot) ?? "", done: 0, total: 0)
        case .stopped(let stop):
            let title = switch stop {
            case .unauthorized: String(localized: "Sign in again to back up")
            case .notAllowed: String(localized: "Immich doesn't let Verso upload")
            case .full: String(localized: "Your Immich server is full")
            case .mostGone: String(localized: "Backing up stopped")
            case .unreachable: backingUp
            }
            return .init(stage: .stopped, title: title, detail: String(localized: "Open the Backup page to see why"), done: 0, total: 0)
        }
    }

    /// Ends the activity: with how the run ended, left on the Lock Screen for `after` seconds, or at once.
    private static func end(_ state: BackupActivityAttributes.ContentState?, after seconds: TimeInterval?) {
        guard let activity else { return }
        nonisolated(unsafe) let ending = activity
        self.activity = nil
        shown = nil
        runTotal = 0
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = seconds.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        Task { await ending.end(content, dismissalPolicy: policy) }
    }
}
