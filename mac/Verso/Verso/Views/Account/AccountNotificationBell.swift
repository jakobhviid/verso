import SwiftUI

/// The bell at the foot of the sidebar, beside the account: Verso's own notifications (the imports that ended) and the
/// server's, with how many are unread, orange while one asks something of the person (`notificationNeedsLook`, as the
/// iPhone's ring round the account's picture is). It shows while either has any to show.
struct AccountNotificationBell: View {
    let session: AccountServices
    @State private var showing = false
    // Owned here so an operation outlives a closed popover; only the popover reads its state.
    @State private var operation = AccountOperation()

    // On macOS 15 a toolbar item is rebuilt whenever its root view reads data that changes,
    // which dismisses its popover (e.g. right after the popover reloads notifications).
    // Changing data is therefore read only by the child views below.
    var body: some View {
        if session.notificationsAvailable || !session.versoNotifications.items.isEmpty {
            Button { showing.toggle() } label: { AccountNotificationBellLabel(session: session) }
                .popover(isPresented: $showing) { AccountNotificationsPopover(session: session, operation: operation) }
        }
    }
}

private struct AccountNotificationBellLabel: View {
    let session: AccountServices
    var body: some View {
        let unreadCount = session.unreadNotificationCount
        let needsLook = session.notificationNeedsLook
        HStack(spacing: 4) {
            Image(systemName: unreadCount == 0 ? "bell" : "bell.badge")
            if unreadCount > 0 { Text(unreadCount.formatted()).monospacedDigit() }
        }
        .modifier(NeedsLookTint(needsLook: needsLook))
        .accessibilityLabel("Notifications, \(unreadCount) unread")
        .help(needsLook ? Text("\(unreadCount) unread notifications, and one asks something of you")
              : Text("\(unreadCount) unread notifications"))
    }
}

/// Orange while a notification asks something of the person; the button's own colour otherwise.
private struct NeedsLookTint: ViewModifier {
    let needsLook: Bool
    func body(content: Content) -> some View {
        if needsLook { content.foregroundStyle(.orange) } else { content }
    }
}

/// Reloads the server's when opened and every minute while the app is active, so there is no Refresh button.
private struct AccountNotificationsPopover: View {
    let session: AccountServices
    let operation: AccountOperation

    var body: some View {
        let verso = session.versoNotifications.items.map(Self.versoEntry)
        let immich = session.notificationsAvailable ? session.notifications.map(Self.immichEntry) : nil
        NotificationsPanel(verso: verso, immich: immich,
                           server: session.client.serverURL.host() ?? session.client.serverURL.absoluteString,
                           busy: operation.busy, error: operation.error ?? session.notificationError,
                           markRead: markRead, delete: delete, markAllRead: markAllRead, clearAll: clearAll)
            // Read and deleted notifications leave the list, and the popover resizes, with an animation.
            .animation(.smooth(duration: 0.3), value: verso.map(\.id) + (immich ?? []).map(\.id))
            .animation(.smooth(duration: 0.3), value: (verso + (immich ?? [])).map(\.unread))
            .modifier(BusyDisabled(busy: operation.busy))
            .task { if session.notificationsAvailable { operation.run { try await session.reloadNotifications() } } }
    }

    private func markRead(_ entry: NotificationEntry) {
        switch entry.source {
        case .verso: if let id = UUID(uuidString: entry.key) { session.versoNotifications.markRead([id]) }
        case .immich: readOnServer([entry.key])
        }
    }

    private func delete(_ entry: NotificationEntry) {
        switch entry.source {
        case .verso: if let id = UUID(uuidString: entry.key) { session.versoNotifications.delete(id) }
        case .immich:
            operation.run {
                try await session.client.deleteAccountNotification(entry.key)
                try await session.reloadNotifications()
            }
        }
    }

    /// Clear All: every notification of a section, Verso's on this Mac or the server's.
    private func clearAll(_ source: NotificationEntry.Source) {
        switch source {
        case .verso: session.versoNotifications.deleteAll()
        case .immich:
            let ids = session.notifications.map(\.id)
            operation.run {
                for id in ids { try await session.client.deleteAccountNotification(id) }
                try await session.reloadNotifications()
            }
        }
    }

    private func markAllRead() {
        session.versoNotifications.markAllRead()
        let unread = session.notifications.filter { $0.readAt == nil }.map(\.id)
        if !unread.isEmpty { readOnServer(unread) }
    }

    private func readOnServer(_ ids: [String]) {
        operation.run {
            try await session.client.readAccountNotifications(ids)
            try await session.reloadNotifications()
        }
    }

    /// One of Verso's: a tick for an import that came in, a warning for one that needs a look, with the files it did
    /// not bring in.
    private static func versoEntry(_ notification: VersoNotification) -> NotificationEntry {
        NotificationEntry(source: .verso, key: notification.id.uuidString,
                          symbol: notification.needsLook ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                          tint: notification.needsLook ? .orange : .green,
                          title: notification.title, detail: notification.detail, date: notification.createdAt,
                          unread: notification.readAt == nil,
                          lines: notification.files.map { NotificationEntry.Line(name: $0.name, reason: $0.reason) })
    }

    /// One of the server's, by its level.
    private static func immichEntry(_ notification: AccountNotification) -> NotificationEntry {
        let (symbol, tint): (String, Color) = switch notification.level {
        case "success": ("checkmark.circle.fill", .green)
        case "warning": ("exclamationmark.triangle.fill", .orange)
        case "error": ("xmark.octagon.fill", .red)
        default: ("info.circle.fill", .accentColor)
        }
        return NotificationEntry(source: .immich, key: notification.id, symbol: symbol, tint: tint,
                                 title: notification.title, detail: notification.description,
                                 date: accountDateValue(notification.createdAt), unread: notification.readAt == nil)
    }
}

/// Disables the popover while busy. Not on macOS 15: disabling the focused button while the
/// popover becomes key loops forever there; `operation.run` already ignores taps while busy.
private struct BusyDisabled: ViewModifier {
    let busy: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.disabled(busy) } else { content }
    }
}
