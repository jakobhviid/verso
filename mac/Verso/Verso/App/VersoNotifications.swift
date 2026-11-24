import Foundation
import Observation

/// A notification of Verso's own, beside the server's in the bell: for now, an import that ended. It is kept on this
/// Mac only, never sent to Immich.
struct VersoNotification: Codable, Identifiable, Equatable, Sendable {
    /// A file the import did not bring in, and why.
    struct File: Codable, Equatable, Sendable {
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

/// Verso's own notifications for one account, kept in the app's defaults: the newest 20, none older than a week. An
/// import that ended cleanly arrives read, as it was seen happening; one that needs a look arrives unread.
@MainActor @Observable
final class VersoNotifications {
    static let kept = 20
    static let keptFor: TimeInterval = 7 * 24 * 3600

    private(set) var items: [VersoNotification] = []
    @ObservationIgnored private let key: String

    init(account: String) {
        key = "notifications.verso." + account
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([VersoNotification].self, from: data) {
            items = saved
        }
        prune()
    }

    var unreadCount: Int { items.filter { $0.readAt == nil }.count }

    func add(_ notification: VersoNotification) {
        var added = notification
        if !added.needsLook { added.readAt = added.createdAt }
        items.insert(added, at: 0)
        prune()
        save()
    }

    func markRead(_ ids: [UUID]) {
        let now = Date()
        for index in items.indices where ids.contains(items[index].id) && items[index].readAt == nil { items[index].readAt = now }
        save()
    }

    func markAllRead() { markRead(items.map(\.id)) }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        items = []
        save()
    }

    private func prune() {
        let oldest = Date().addingTimeInterval(-Self.keptFor)
        items = Array(items.filter { $0.createdAt >= oldest }.prefix(Self.kept))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}
