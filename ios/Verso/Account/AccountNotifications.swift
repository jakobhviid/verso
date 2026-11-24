// The notifications at the top of the account's sheet on iOS (ROADMAP.md, M10), where the Mac and Linux have the bell,
// in two sections that say where each comes from (DESIGN.md): Verso's own, kept on this device (the imports that ended,
// read once seen, unread when one needs a look), and Immich's, from the server (album invitations, failed jobs, its
// admin's messages). A section shows while it holds any, under Verso's lens or Immich's server and its address. A tap
// on one marks it read and opens the files an import did not bring in; its × clears it, as a swipe does, and a swipe
// the other way marks it read; Mark All Read heads the first section while any is unread, and Clear All each section
// that holds more than one. The account's picture in Collections wears a ring while any is kept, and carries the
// unread count (NotificationCount.swift).

import SwiftUI
import UIKit

/// The notifications' sections, for the account sheet's list.
struct AccountNotificationsSections: View {
    let services: AccountServices
    /// Why a change on the server did not go through.
    @State private var error: String?

    var body: some View {
        let verso = services.versoNotifications.items.map(NotificationsEntry.init)
        let immich = services.notificationsAvailable ? services.notifications.map(NotificationsEntry.init) : []
        let anyUnread = (verso + immich).contains(where: \.unread)
        let message = error ?? services.notificationError
        if !verso.isEmpty {
            Section {
                ForEach(verso) { NotificationsRow(entry: $0, markRead: markRead, delete: delete) }
            } header: {
                header(.verso, place: "On This \(UIDevice.current.model)", offersMarkAllRead: anyUnread,
                       offersClearAll: verso.count > 1)
            } footer: {
                if immich.isEmpty, let message { errorText(message) }
            }
        }
        if !immich.isEmpty {
            Section {
                ForEach(immich) { NotificationsRow(entry: $0, markRead: markRead, delete: delete) }
            } header: {
                header(.immich, place: serverName, offersMarkAllRead: anyUnread && verso.isEmpty,
                       offersClearAll: immich.count > 1)
            } footer: {
                if let message { errorText(message) }
            }
        }
    }

    /// A section's heading, with Mark All Read at its end on the first section, and Clear All where it holds more than
    /// one.
    private func header(_ source: NotificationsEntry.Source, place: String, offersMarkAllRead: Bool,
                        offersClearAll: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NotificationsSourceHeading(source: source, place: place)
            Spacer(minLength: 0)
            if offersMarkAllRead {
                Button("Mark All Read", action: markAllRead)
                    .font(.subheadline)
                    .textCase(nil)
            }
            if offersClearAll {
                Button("Clear All") { clearAll(source) }
                    .font(.subheadline)
                    .textCase(nil)
            }
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private var serverName: String {
        services.client.serverURL.host() ?? services.client.serverURL.absoluteString
    }

    private func markRead(_ entry: NotificationsEntry) {
        switch entry.source {
        case .verso:
            if let id = UUID(uuidString: entry.key) { services.versoNotifications.markRead([id]) }
        case .immich:
            readOnServer([entry.key])
        }
    }

    private func delete(_ entry: NotificationsEntry) {
        switch entry.source {
        case .verso:
            if let id = UUID(uuidString: entry.key) { services.versoNotifications.delete(id) }
        case .immich:
            // Gone from the list at once; the server's list is read again after.
            services.notifications.removeAll { $0.id == entry.key }
            onServer { try await services.client.deleteAccountNotification(entry.key) }
        }
    }

    private func clearAll(_ source: NotificationsEntry.Source) {
        switch source {
        case .verso:
            services.versoNotifications.deleteAll()
        case .immich:
            let ids = services.notifications.map(\.id)
            services.notifications = []
            onServer { for id in ids { try await services.client.deleteAccountNotification(id) } }
        }
    }

    private func markAllRead() {
        services.versoNotifications.markAllRead()
        let unread = services.notifications.filter { $0.readAt == nil }.map(\.id)
        if !unread.isEmpty { readOnServer(unread) }
    }

    private func readOnServer(_ ids: [String]) {
        let now = Date().ISO8601Format()
        services.notifications = services.notifications.map { notification in
            guard ids.contains(notification.id), notification.readAt == nil else { return notification }
            return AccountNotification(id: notification.id, title: notification.title,
                                       description: notification.description, level: notification.level,
                                       createdAt: notification.createdAt, readAt: now)
        }
        onServer { try await services.client.readAccountNotifications(ids) }
    }

    /// A change on the server, then its list read again, which also puts back what the change could not do.
    private func onServer(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await change()
                error = nil
            } catch {
                self.error = error.localizedDescription
                services.handle(error)
            }
            await services.reloadNotificationsNow()
        }
    }
}

extension AccountServices {
    /// The server's notifications read again now, as the account's sheet opens, on a pull and after a change, between
    /// the readings every minute (`startNotifications`), and with the same outcome: a failure said under them, and none
    /// asked for again from a server without them.
    func reloadNotificationsNow() async {
        guard notificationsAvailable else { return }
        do {
            try await reloadNotifications()
            notificationError = nil
        } catch ImmichError.http(404, _), ImmichError.http(403, _) {
            notificationsAvailable = false
        } catch {
            guard !error.isCancellation else { return }
            notificationError = error.localizedDescription
        }
    }
}

/// One row of the notifications: one of Verso's own or one of the server's.
private struct NotificationsEntry: Identifiable {
    enum Source { case verso, immich }
    /// A file an import did not bring in, and why.
    struct Line {
        let name: String
        let reason: String
    }

    let source: Source
    /// The notification's own id, Verso's or the server's.
    let key: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    let date: Date?
    let unread: Bool
    var lines: [Line] = []

    var id: String { (source == .verso ? "verso:" : "immich:") + key }

    /// One of Verso's: a tick for an import that came in, a warning for one that needs a look, with the files it did
    /// not bring in.
    init(_ notification: VersoNotification) {
        source = .verso
        key = notification.id.uuidString
        symbol = notification.needsLook ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        tint = notification.needsLook ? .orange : .green
        title = notification.title
        detail = notification.detail
        date = notification.createdAt
        unread = notification.readAt == nil
        lines = notification.files.map { Line(name: $0.name, reason: $0.reason) }
    }

    /// One of the server's, by its level.
    init(_ notification: AccountNotification) {
        source = .immich
        key = notification.id
        switch notification.level {
        case "success":
            symbol = "checkmark.circle.fill"
            tint = .green
        case "warning":
            symbol = "exclamationmark.triangle.fill"
            tint = .orange
        case "error":
            symbol = "xmark.octagon.fill"
            tint = .red
        default:
            symbol = "info.circle.fill"
            tint = .accentColor
        }
        title = notification.title
        detail = notification.description
        date = accountDateValue(notification.createdAt)
        unread = notification.readAt == nil
    }
}

/// Where a section's notifications come from: Verso's lens and this device, or a server and its address; never
/// Immich's logo (DESIGN.md).
private struct NotificationsSourceHeading: View {
    let source: NotificationsEntry.Source
    let place: String
    @ScaledMetric(relativeTo: .subheadline) private var lensSide: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            switch source {
            case .verso:
                Image("Lens")
                    .resizable()
                    .frame(width: lensSide, height: lensSide)
                Text(verbatim: "Verso").fontWeight(.semibold)
            case .immich:
                Image(systemName: "server.rack")
                Text(verbatim: "Immich").fontWeight(.semibold)
            }
            Text(place)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// An unread row shows a dot; a tap marks it read and opens the files an import did not bring in. Its × clears it, as a
/// swipe to the left does; Mark Read is a swipe to the right, and both are in its menu.
private struct NotificationsRow: View {
    let entry: NotificationsEntry
    let markRead: @MainActor (NotificationsEntry) -> Void
    let delete: @MainActor (NotificationsEntry) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.symbol)
                    .foregroundStyle(entry.tint)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .fontWeight(entry.unread ? .semibold : .regular)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let date = entry.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if entry.unread {
                        Circle()
                            .fill(.tint)
                            .frame(width: 9, height: 9)
                    }
                    if !entry.lines.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Button {
                        delete(entry)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.lines.indices, id: \.self) { index in
                        let line = entry.lines[index]
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(line.reason)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            if entry.unread { markRead(entry) }
            if !entry.lines.isEmpty { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
        }
        .swipeActions(edge: .leading) {
            if entry.unread {
                Button("Mark Read", systemImage: "envelope.open") { markRead(entry) }
                    .tint(.accentColor)
            }
        }
        .contextMenu {
            if entry.unread {
                Button("Mark Read", systemImage: "envelope.open") { markRead(entry) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.lines.isEmpty ? [] : .isButton)
        .accessibilityAction(named: "Delete") { delete(entry) }
        .accessibilityActions {
            if entry.unread {
                Button("Mark Read") { markRead(entry) }
            }
        }
    }
}
