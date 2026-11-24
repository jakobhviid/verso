// How backing up sends (ARCHITECTURE.md, "Backing the iPhone up", "Sending"): behind a protocol, so the system's own
// uploads (PhotoKit's background upload extension; ROADMAP.md, M10, "The system's own uploads") can take over once
// Immich takes resumable uploads; for now one background URLSession carries the uploads, so they go on while Verso is
// suspended and the system relaunches it with their answers. New photos sent while Verso is open go through a session
// of the app's own instead (`fast`), at once rather than behind the background session's queue; their tasks are kept in
// the journal as negative numbers, so recovery never takes one for a background task still on its way, and they are
// cancelled as Verso goes to the background, to go again through the background session.
//
// Each task carries its journal step's id as its description, and the delegate keeps how much of each body has gone,
// for the ring on a tile that uploads. Its answer is recorded straight into the store by the sessions' delegate
// (BackupAnswers), whether or not the rest of the engine is running, and its body file removed:
// - 201 created or 200 duplicate: the part is on the server with the asset's id; a duplicate after the check said
//   absent is this photo's own earlier upload, whose answer was lost; a created answer for a step recovery closed
//   first, as a duplicate, makes it the upload Verso made, as it was;
// - 401: backing up stops and asks the person to sign in again;
// - 403: backing up stops with Immich's reason, once, rather than refusing every photo one by one: both the upload and
//   the duplicate check need the key's `asset.upload`, so it comes when that was taken away after the check, or from a
//   proxy;
// - 507 or a quota message: the server is full; backing up stops with one notice and tries daily;
// - 413, or another 4xx: Immich, or a proxy in front of it, refused the file; the photo needs a look, with the reason;
// - 5xx, or no answer: tried again later, with backoff; five in a row with no upload landing between pause backing up
//   (BackupOutage);
// - cancelled: nothing changes, the part goes in a later batch.

import Foundation

/// The transport the engine sends through.
protocol BackupSending: AnyObject, Sendable {
    /// Starts sending a body file; the task's identifier. `fast`: at once, while Verso is open, for a new photo.
    func send(_ request: URLRequest, file: URL, step: Int64, fast: Bool) -> Int
    /// The identifiers of the background session's tasks still on their way.
    func tasksOnTheirWay() async -> Set<Int>
    func cancelAll() async
    /// Cancels the uploads of these journal steps, wherever they are on their way.
    func cancel(steps: Set<Int64>) async
    /// Cancels the uploads sent at once, as Verso goes to the background.
    func cancelFast() async
    /// How much of each upload on its way has gone, from 0 to 1, by its journal step.
    func progress() -> [Int64: Double]
}

/// What an answer came to, for the engine.
struct BackupAnswer: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case uploaded(assetID: String, created: Bool)
        case unauthorized
        /// Immich, or a proxy in front of it, does not let this sign-in upload: Immich's reason.
        case notAllowed(String)
        case serverFull
        case refused(String)
        case retryLater(String)
        /// Tried again later, and the answer that makes an outage of it: backing up pauses (BackupOutage).
        case paused(String)
        case cancelled
    }
    var step: Int64
    var account: String
    var localID: String
    var outcome: Outcome
}

/// The background session and its delegate.
final class BackupTransport: NSObject, BackupSending, URLSessionDataDelegate, @unchecked Sendable {
    let store: BackupStore
    private let lock = NSLock()
    /// Each answer's body as it comes, by its session and task.
    private var bodies: [String: Data] = [:]
    private var sent: [Int64: Double] = [:]
    private var session: URLSession!
    /// The app's own session, for new photos while Verso is open.
    private var fastSession: URLSession!
    private var finishEvents: (() -> Void)?
    /// Told each answer once it is recorded, on the delegate's queue.
    var onAnswer: @Sendable (BackupAnswer) -> Void = { _ in }
    /// Told once a wake-up's answers are all recorded, with the system's completion to call when Verso is done
    /// (BackupScheduler.sessionWoke, which tops the uploads up first); without it, the completion is called at once.
    var onEventsDelivered: (@Sendable (@escaping @Sendable () -> Void) -> Void)?

    static func identifier(bundle: String) -> String { bundle + ".backup.uploads" }

    init(store: BackupStore, identifier: String) {
        self.store = store
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Low Data Mode is respected; cellular is the request's own, from the settings.
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 6
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Backup uploads"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let fast = URLSessionConfiguration.default
        fast.allowsConstrainedNetworkAccess = false
        fast.timeoutIntervalForResource = 3600
        fastSession = URLSession(configuration: fast, delegate: self, delegateQueue: queue)
    }

    private func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        (session === fastSession ? "fast-" : "") + String(task.taskIdentifier)
    }

    /// The system woke Verso for this session's events: `completion` is called once they have all been delivered.
    func handleEvents(completion: @escaping () -> Void) {
        lock.lock()
        finishEvents = completion
        lock.unlock()
    }

    func send(_ request: URLRequest, file: URL, step: Int64, fast: Bool) -> Int {
        let task = (fast ? fastSession : session).uploadTask(with: request, fromFile: file)
        task.taskDescription = String(step)
        if fast { task.priority = URLSessionTask.highPriority }
        task.resume()
        return fast ? -(task.taskIdentifier + 1) : task.taskIdentifier
    }

    func tasksOnTheirWay() async -> Set<Int> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.map(\.taskIdentifier))
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
        await cancelFast()
    }

    func cancel(steps: Set<Int64>) async {
        guard !steps.isEmpty else { return }
        for task in await session.allTasks + fastSession.allTasks
        where task.taskDescription.flatMap(Int64.init).map(steps.contains) == true {
            task.cancel()
        }
    }

    func cancelFast() async {
        for task in await fastSession.allTasks { task.cancel() }
    }

    func progress() -> [Int64: Double] {
        lock.withLock { sent }
    }

    // MARK: The delegate

    /// The server's certificate as every session of the app judges it: as the system does, or as the certificate
    /// trusted for the server (ServerTrust), which the account brings as Verso launches (`BackupCenter.launch`).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.answer(challenge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = key(session, dataTask)
        lock.lock()
        bodies[key, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let step = task.taskDescription.flatMap(Int64.init), totalBytesExpectedToSend > 0 else { return }
        lock.withLock { sent[step] = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = key(session, task)
        let step = task.taskDescription.flatMap(Int64.init)
        lock.lock()
        let body = bodies.removeValue(forKey: key) ?? Data()
        if let step { sent[step] = nil }
        lock.unlock()
        guard let step else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let answer = BackupAnswers.record(store: store, step: step, status: status, body: body, error: error) {
            onAnswer(answer)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = finishEvents
        finishEvents = nil
        lock.unlock()
        guard let completion else { return }
        // The system's completion is called on the main queue, as it asks.
        nonisolated(unsafe) let handler = completion
        let finish: @Sendable () -> Void = { DispatchQueue.main.async { handler() } }
        if let onEventsDelivered { onEventsDelivered(finish) } else { finish() }
    }
}

/// Recording an upload's answer in the store: the facts first, then the step's result, then the body's removal.
enum BackupAnswers {
    static func record(store: BackupStore, step id: Int64, status: Int?, body: Data, error: Error?,
                       now: Date = Date()) -> BackupAnswer? {
        guard let step = try? store.step(id) else { return nil }
        defer {
            if let file = step.file { try? FileManager.default.removeItem(atPath: file) }
        }
        var outcome = outcome(status: status, body: body, error: error)
        do {
            switch outcome {
            case .uploaded(let assetID, let created):
                if let checksum = step.checksum {
                    try store.recordUploaded(account: step.account, checksum: checksum, assetID: assetID, trashed: false, now: now)
                }
                // Recovery may have closed the step first, asking Immich by its fingerprint, which cannot tell Verso's
                // own upload from one Immich had already: Immich's answer, coming after, says which.
                guard try store.finishStep(id, result: created ? "created" : "duplicate", assetID: assetID, now: now)
                        || (created && store.recordCreatedAfterRecovery(id, assetID: assetID, now: now)) else { return nil }
                try store.setMeta("fullSaid.\(step.account)", nil)
                try BackupOutage.landed(store: store, account: step.account)
                if created { try store.database.run("UPDATE backup SET uploaded = 1 WHERE account = ? AND local_id = ?", [step.account, step.localID]) }
                try store.refreshState(account: step.account, step.localID, now: now)
            case .refused(let reason):
                guard try store.finishStep(id, result: "refused", now: now) else { return nil }
                try store.setUploadFailure(account: step.account, step.localID, "Immich did not take it: \(reason)")
            case .retryLater(let reason):
                guard try store.finishStep(id, result: "retry: \(reason)", now: now) else { return nil }
                if let role = step.role {
                    let earlier = try store.database.first("""
                    SELECT count(*) FROM journal WHERE account = ? AND local_id = ? AND role = ? AND result LIKE 'retry%'
                      AND finished > ?
                    """, [step.account, step.localID, role.rawValue, now.addingTimeInterval(-3 * 24 * 3600)]) { $0.int(0) } ?? 1
                    try store.postpone(step.localID, role, until: now.addingTimeInterval(BackupBackoff.delay(attempt: earlier)),
                                       reason: "Immich didn't take it this time (\(reason))")
                }
                if try BackupOutage.failed(store: store, account: step.account, reason: reason, now: now) { outcome = .paused(reason) }
            case .paused:
                break
            case .unauthorized:
                guard try store.finishStep(id, result: "unauthorized", now: now) else { return nil }
                // Said once: the other uploads' same answers add nothing.
                guard try store.meta("stop.\(step.account)") != "unauthorized" else { return nil }
                try store.setMeta("stop.\(step.account)", "unauthorized")
            case .notAllowed(let reason):
                guard try store.finishStep(id, result: "not allowed", now: now) else { return nil }
                guard try store.meta("stop.\(step.account)") != "notAllowed" else { return nil }
                try store.setMeta("stop.\(step.account)", "notAllowed")
                try store.setMeta("stopReason.\(step.account)", reason)
            case .serverFull:
                guard try store.finishStep(id, result: "full", now: now) else { return nil }
                guard try store.meta("stop.\(step.account)") != "full" else { return nil }
                try store.setMeta("stop.\(step.account)", "full")
                try store.setMetaDate("stopSince.\(step.account)", now)
                // One notice for a full server, not one for each day it is tried again and still full.
                guard try store.meta("fullSaid.\(step.account)") == nil else { return nil }
                try store.setMeta("fullSaid.\(step.account)", "yes")
            case .cancelled:
                guard try store.finishStep(id, result: "cancelled", now: now) else { return nil }
            }
        } catch {
            return nil
        }
        return BackupAnswer(step: id, account: step.account, localID: step.localID, outcome: outcome)
    }

    static func outcome(status: Int?, body: Data, error: Error?) -> BackupAnswer.Outcome {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return .cancelled }
            return .retryLater(error.localizedDescription)
        }
        guard let status else { return .retryLater("no answer") }
        struct Answer: Decodable { let id: String?; let status: String?; let message: FlexibleMessage? }
        struct FlexibleMessage: Decodable {
            let text: String
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let one = try? container.decode(String.self) { text = one } else { text = (try container.decode([String].self)).joined(separator: " ") }
            }
        }
        let answer = try? JSONDecoder().decode(Answer.self, from: body)
        let message = answer?.message?.text ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 200..<300:
            guard let id = answer?.id, !id.isEmpty else { return .retryLater("an answer without an asset") }
            return .uploaded(assetID: id, created: answer?.status != "duplicate")
        case 401: return .unauthorized
        // Too large for the server, or for a proxy in front of it (nginx's default limit, Cloudflare's 100 MB): this
        // file's own refusal, which the person can look at, not a full server that stops everything.
        case 413: return .refused("it is larger than the server takes; a proxy in front of Immich may limit the size of uploads")
        case 507: return .serverFull
        case 400..<500 where message.localizedCaseInsensitiveContains("quota"): return .serverFull
        case 403: return .notAllowed(message)
        case 408, 425, 429: return .retryLater(message)
        case 400..<500: return .refused(message)
        default: return .retryLater(message)
        }
    }
}

/// An outage: uploads failing in a row with none landing between, as when Immich is down or out of reach (a server
/// only on the home network, with the phone away). After `streak` such answers backing up pauses, for 15 minutes the
/// first time, doubling up to 4 hours, rather than writing body after body (reading each from Photos, perhaps from
/// iCloud) for each to fail too. An upload landing, the network changing or the person's Try Now ends it; after a
/// pause, only `probe` uploads go at a time until one lands.
enum BackupOutage {
    static let streak = 5
    static let probe = 2

    static func pause(_ count: Int) -> TimeInterval {
        min(4 * 3600, 900 * pow(2, Double(max(0, count - 1))))
    }

    /// An upload to try again later: true when it starts a pause. Another stop (a full server, a sign-in) comes first.
    static func failed(store: BackupStore, account: String, reason: String, now: Date) throws -> Bool {
        let failures = (try store.meta("failures.\(account)").flatMap { Int($0) } ?? 0) + 1
        try store.setMeta("failures.\(account)", String(failures))
        guard failures >= streak, try store.meta("stop.\(account)") == nil else { return false }
        let pauses = (try store.meta("pauses.\(account)").flatMap { Int($0) } ?? 0) + 1
        try store.setMeta("pauses.\(account)", String(pauses))
        try store.setMeta("stop.\(account)", "unreachable")
        try store.setMeta("stopReason.\(account)", reason)
        try store.setMetaDate("pausedUntil.\(account)", now.addingTimeInterval(pause(pauses)))
        return true
    }

    /// An upload landed: whatever outage there was is over.
    static func landed(store: BackupStore, account: String) throws {
        guard try store.meta("failures.\(account)") != nil || store.meta("pauses.\(account)") != nil else { return }
        try store.setMeta("failures.\(account)", nil)
        try store.setMeta("pauses.\(account)", nil)
        try lift(store: store, account: account)
    }

    /// The pause ends before its time (the person's Try Now, the network changing): uploads go again, probing.
    static func lift(store: BackupStore, account: String) throws {
        guard try store.meta("stop.\(account)") == "unreachable" else { return }
        try store.setMeta("stop.\(account)", nil)
        try store.setMeta("stopReason.\(account)", nil)
        try store.setMeta("pausedUntil.\(account)", nil)
    }

    /// Paused until then, while it lasts.
    static func pausedUntil(store: BackupStore, account: String) throws -> Date? {
        try store.meta("stop.\(account)") == "unreachable" ? store.metaDate("pausedUntil.\(account)") : nil
    }

    /// Uploads go a few at a time: a pause came, and nothing has landed since.
    static func probing(store: BackupStore, account: String) throws -> Bool {
        try store.meta("pauses.\(account)") != nil
    }
}

/// How long to wait before trying again: half a minute, then 2 minutes, then 5 minutes, doubling, at most a day. One
/// failure is most often a moment's (a proxy's 502 while Immich restarts), so the first retry comes soon; an outage is
/// the outage pause's (BackupOutage).
enum BackupBackoff {
    static func delay(attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 30
        case 2: 120
        default: min(24 * 3600, 300 * pow(2, Double(attempt - 3)))
        }
    }
}
