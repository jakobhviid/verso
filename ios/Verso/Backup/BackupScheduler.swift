// Backing up's time in the background (ARCHITECTURE.md, "Backing the iPhone up", "Sending"), with BackgroundTasks
// alone:
// - Back Up Now and the first run (its check, as backing up is switched on, and its uploads, from Start) are continued
//   processing tasks the person starts (`<bundle>.backup.now.<UUID>`), with the system's progress and its Stop, which
//   stops the run and its uploads;
// - backing up on its own uses background processing (`<bundle>.backup.overnight`: overnight, with the network, and on
//   power when Only While Charging says so) and background refresh (`<bundle>.backup.refresh`: a short look for new
//   photos and answers, topping the uploads up), both registered as Verso launches (BackupLaunch) and asked for again
//   after each run while backing up is on;
// - the system's wake-ups for the background session's answers top the uploads up before Verso says it is done
//   (`sessionWoke`), so the session has its next uploads while Verso is suspended.
// The uploads themselves go on in the background session whatever time Verso has (BackupTransport). The Info.plist
// permits the three identifiers and has the fetch and processing background modes.

import BackgroundTasks
import Foundation
import UIKit

@MainActor
enum BackupScheduler {
    static var bundle: String { Bundle.main.bundleIdentifier ?? "dev.hviid.Verso" }
    static var overnight: String { bundle + ".backup.overnight" }
    static var refresh: String { bundle + ".backup.refresh" }
    static var continuedPrefix: String { bundle + ".backup.now." }

    private static var continued: BGContinuedProcessingTask?
    /// A run the person started shows with the system's own progress, or is about to: Verso's Live Activity stays
    /// away meanwhile.
    static var isContinuing: Bool {
        continued != nil || submitted.map { Date().timeIntervalSince($0) < 10 } == true
    }
    /// When the system took a run's request, until it starts it.
    private static var submitted: Date?
    private static var registered = false
    /// Background processing or refresh tasks under way, whose passes are theirs to end.
    private static var running = 0

    /// Registers the background tasks; called before the app finishes launching.
    static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: overnight, using: .main) { task in
            MainActor.assumeIsolated { run(task, lasting: nil) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: .main) { task in
            MainActor.assumeIsolated { run(task, lasting: .seconds(25)) }
        }
    }

    /// A background task's run: the account from the vault where no window has signed in, then passes until done or
    /// out of time; the next ones asked for after.
    private static func run(_ task: BGTask, lasting limit: Duration?) {
        let center = BackupCenter.shared
        center.launch()
        guard let engine = center.engine, BackupSettings.current.isOn else {
            task.setTaskCompleted(success: true)
            return
        }
        running += 1
        let work = Task {
            await center.accountForBackground()
            if let limit {
                let pass = Task { await engine.runUntilDone() }
                try? await Task.sleep(for: limit)
                pass.cancel()
                await engine.cancelPass()
            } else {
                await engine.runUntilDone()
            }
        }
        task.expirationHandler = {
            work.cancel()
            Task { await engine.cancelPass() }
        }
        Task {
            await work.value
            running -= 1
            scheduleOwnBackups()
            task.setTaskCompleted(success: true)
        }
    }

    /// The system woke Verso for the background session's answers, which kicked a pass. Uploads are topped up first,
    /// and the pass has 20 seconds at most before it stops, so the session has its next uploads before Verso is
    /// suspended again, and nothing is left open when it is; then the system's completion (`finish`). Its own time is
    /// about 30 seconds. Where a background task or the person's run goes on, or Verso is in front, the pass is theirs
    /// and the completion goes at once.
    static func sessionWoke(_ finish: @escaping @Sendable () -> Void) {
        let center = BackupCenter.shared
        guard let engine = center.engine, BackupSettings.current.isOn, continued == nil, running == 0,
              UIApplication.shared.applicationState != .active else {
            finish()
            return
        }
        Task {
            await center.accountForBackground()
            await engine.topUpFirst()
            let limit = Task {
                try? await Task.sleep(for: .seconds(20))
                await engine.cancelPass()
            }
            await engine.runUntilDone()
            limit.cancel()
            finish()
        }
    }

    /// Asks for the next background processing and refresh, while backing up is on.
    static func scheduleOwnBackups() {
        guard BackupSettings.current.isOn else { return }
        let processing = BGProcessingTaskRequest(identifier: overnight)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = BackupSettings.current.onlyWhileCharging
        processing.earliestBeginDate = Date().addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(processing)
        let refreshing = BGAppRefreshTaskRequest(identifier: refresh)
        refreshing.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(refreshing)
    }

    static func cancelOwnBackups() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: overnight)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refresh)
        finishContinued(success: false)
    }

    // MARK: A run the person started

    /// Asks the system for a continued processing task for the run, which shows its progress and lets the person
    /// stop it. Registered as it is submitted, under an identifier of its own.
    static func submitContinued(title: String) {
        guard continued == nil else { return }
        let identifier = continuedPrefix + UUID().uuidString
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(where: { $0 == identifier || ($0.hasSuffix("*") && identifier.hasPrefix(String($0.dropLast()))) })
        else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                started(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting")
        request.strategy = .fail
        if (try? BGTaskScheduler.shared.submit(request)) != nil { submitted = Date() }
    }

    private static func started(_ task: BGContinuedProcessingTask) {
        submitted = nil
        let center = BackupCenter.shared
        guard center.personRunActive || !center.snapshot.firstRunStarted, let engine = center.engine else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        // Stopped from the system's progress, or out of time: the run and its uploads stop; the next pass sends them.
        task.expirationHandler = {
            Task { @MainActor in
                await engine.cancelPass()
                await center.transport?.cancelAll()
                continued = nil
                center.personRunEnded()
            }
        }
        reportProgress(center.snapshot)
        // Kept going while the run has something on its way, so answers keep topping the uploads up; the first run's
        // check until it has looked at what it can. Once nothing more can be done now, it ends as done, saying what waits
        // for a retry if anything does: a task whose progress stops is ended by iOS as failed, after a while, and what
        // waits goes by itself (BackupEngine's wake) whether the task runs or not.
        Task {
            while continued === task {
                try? await Task.sleep(for: .seconds(3))
                if await isDone(engine) {
                    await engine.kick()
                    try? await Task.sleep(for: .seconds(3))
                    if await isDone(engine) {
                        if let retry = BackupStatus.retry(await engine.snapshot()) {
                            task.updateTitle(task.title, subtitle: retry)
                        }
                        finishContinued(success: true)
                    }
                }
            }
        }
    }

    /// Nothing more to do now: no pass under way and nothing on its way. What is left, if anything, waits for a retry,
    /// a connection or room.
    private static func isDone(_ engine: BackupEngine) async -> Bool {
        guard await !engine.isRunning else { return false }
        return await engine.snapshot().onTheirWay == 0
    }

    static func reportProgress(_ snapshot: BackupSnapshot) {
        guard let continued else { return }
        let tally = snapshot.tally
        continued.progress.totalUnitCount = Int64(max(tally.total, 1))
        guard snapshot.firstRunStarted else {
            // The first run's check: how many photos have been looked at.
            continued.progress.completedUnitCount = Int64(tally.checked)
            continued.updateTitle("Checking with Immich", subtitle: "\(tally.checked.formatted()) of \(tally.total.formatted())")
            return
        }
        let remaining = snapshot.going
        continued.progress.completedUnitCount = Int64(tally.alreadyInImmich + tally.skipped + tally.inImmichTrash)
        let subtitle = remaining == 0 ? "Finishing" : remaining == 1 ? "1 item to go" : "\(remaining.formatted()) items to go"
        continued.updateTitle("Backing Up to Immich", subtitle: subtitle)
    }

    static func finishContinued(success: Bool) {
        guard let task = continued else { return }
        continued = nil
        BackupCenter.shared.personRunEnded()
        task.setTaskCompleted(success: success)
    }
}
