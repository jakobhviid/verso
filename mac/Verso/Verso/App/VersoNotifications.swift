import Foundation
import Observation
import VersoCore

/// A notification of Verso's own, beside the server's in the bell: an import that ended, and on the iPhone what backing
/// up needs. It is kept on this device only, never sent to Immich.
struct VersoNotification: Identifiable, Equatable, Sendable {
    /// A file the import did not bring in, and why.
    struct File: Equatable, Sendable {
        let name: String
        let reason: String
    }

    var id = UUID()
    var createdAt = Date()
    let title: String
    let detail: String?
    /// Something failed, was cancelled or stopped the import: it arrives unread.
    let needsLook: Bool
    var readAt: Date?
    var files: [File] = []
}

/// Verso's own notifications for one account, kept in the app's defaults. The shared core keeps them, as on Linux
/// (`versoNotificationsAdded` and the rest): the newest 20, none older than a week; an import that ended cleanly
/// arrives read, as it was seen happening, and one that needs a look unread.
@MainActor @Observable
final class VersoNotifications {
    private(set) var items: [VersoNotification] = []
    private(set) var unreadCount = 0
    @ObservationIgnored private let key: String
    /// The notifications shown, in the form the defaults keep them: read once, at launch, and changed from there.
    @ObservationIgnored private var stored = ""

    init(account: String) {
        key = versoNotificationsKey(account: account)
        let kept = UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } ?? ""
        show(versoNotificationsRead(stored: kept, now: Date()))
    }

    func add(_ notification: VersoNotification) {
        save(versoNotificationsAdded(stored: stored, notification: KeptNotification(notification), now: Date()))
    }

    func markRead(_ ids: [UUID]) {
        save(versoNotificationsMarkedRead(stored: stored, ids: ids.map(\.uuidString), now: Date()))
    }

    func markAllRead() { markRead(items.map(\.id)) }

    func delete(_ id: UUID) {
        save(versoNotificationsDeleted(stored: stored, ids: [id.uuidString]))
    }

    func deleteAll() {
        save(versoNotificationsDeleted(stored: stored, ids: items.map(\.id.uuidString)))
    }

    private func save(_ kept: KeptNotifications) {
        UserDefaults.standard.set(Data(kept.stored.utf8), forKey: key)
        show(kept)
    }

    private func show(_ kept: KeptNotifications) {
        stored = kept.stored
        items = kept.notifications.compactMap(VersoNotification.init)
        unreadCount = Int(kept.unread)
    }
}

extension VersoNotification {
    /// A notification the core keeps; none for one whose id is no UUID, which this app never makes.
    init?(_ kept: KeptNotification) {
        guard let id = UUID(uuidString: kept.id) else { return nil }
        self.init(id: id, createdAt: kept.createdAt, title: kept.title, detail: kept.detail, needsLook: kept.needsLook,
                  readAt: kept.readAt, files: kept.files.map { File(name: $0.name, reason: $0.reason) })
    }
}

extension KeptNotification {
    init(_ notification: VersoNotification) {
        self.init(id: notification.id.uuidString, createdAt: notification.createdAt, title: notification.title,
                  detail: notification.detail, needsLook: notification.needsLook, readAt: notification.readAt,
                  files: notification.files.map { KeptNotificationFile(name: $0.name, reason: $0.reason) })
    }
}
