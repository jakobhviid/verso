import AppKit
import SwiftUI

/// One row of the bell's list: one of Verso's own notifications (an import that ended) or one of the server's.
struct NotificationEntry: Identifiable, Equatable {
    enum Source { case verso, immich }
    /// A file an import did not bring in, and why.
    struct Line: Equatable {
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
}

/// The bell's list, in two sections that say where each notification comes from: Verso's own, kept on this Mac (the
/// imports, read once seen, unread when one needs a look), and the server's, from Immich (album invites, failed jobs,
/// messages from its admin). Each section is headed by its source: Verso's icon and "On this Mac", or a server and the
/// server's address, as on Linux, with Clear All at its end where it holds more than one, as on the iPhone.
struct NotificationsPanel: View {
    let verso: [NotificationEntry]
    /// The server's, or nil when the server keeps none for this account (an older server, or a key without the right).
    let immich: [NotificationEntry]?
    /// The server's address, under Immich's heading.
    let server: String
    var busy = false
    var error: String?
    var markRead: (NotificationEntry) -> Void = { _ in }
    var delete: (NotificationEntry) -> Void = { _ in }
    var markAllRead: () -> Void = {}
    /// Clears a section: every notification of the source.
    var clearAll: (NotificationEntry.Source) -> Void = { _ in }

    private var serverEntries: [NotificationEntry] { immich ?? [] }
    private var empty: Bool { verso.isEmpty && serverEntries.isEmpty }
    private var anyUnread: Bool { (verso + serverEntries).contains(where: \.unread) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Notifications").font(.headline)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if anyUnread { Button("Mark All Read", action: markAllRead).buttonStyle(.borderless) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if empty {
                ContentUnavailableView("No Notifications", systemImage: "bell")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !verso.isEmpty {
                        Section {
                            ForEach(verso) { NotificationRow(entry: $0, markRead: markRead, delete: delete) }
                        } header: {
                            SourceHeading(source: .verso, place: String(localized: "On this Mac"),
                                          clearAll: verso.count > 1 ? { clearAll(.verso) } : nil)
                        }
                    }
                    if !serverEntries.isEmpty {
                        Section {
                            ForEach(serverEntries) { NotificationRow(entry: $0, markRead: markRead, delete: delete) }
                        } header: {
                            SourceHeading(source: .immich, place: server,
                                          clearAll: serverEntries.count > 1 ? { clearAll(.immich) } : nil)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if let error {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 360, height: empty ? 200 : 420)
    }
}

/// A section's heading: where its notifications come from, and Clear All where the section holds more than one.
private struct SourceHeading: View {
    let source: NotificationEntry.Source
    let place: String
    var clearAll: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                switch source {
                case .verso:
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 16, height: 16)
                    Text(verbatim: "Verso").fontWeight(.semibold).foregroundStyle(.primary)
                case .immich:
                    Image(systemName: "server.rack").frame(width: 16, height: 16)
                    Text(verbatim: "Immich").fontWeight(.semibold).foregroundStyle(.primary)
                }
                Text(place).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let clearAll { Button("Clear All", action: clearAll).buttonStyle(.borderless) }
        }
        .font(.subheadline)
    }
}

/// Unread rows show a dot; clicking one marks it read, and opens the files an import did not bring in. Delete shows
/// on hover, and both are also in the context menu, as swipe actions and as accessibility actions.
private struct NotificationRow: View {
    let entry: NotificationEntry
    let markRead: (NotificationEntry) -> Void
    let delete: (NotificationEntry) -> Void
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.symbol).foregroundStyle(entry.tint).font(.title3).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).fontWeight(entry.unread ? .semibold : .regular)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let date = entry.date {
                        Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ZStack {
                        if hovering {
                            Button { delete(entry) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
                        } else if entry.unread {
                            Circle().fill(.tint).frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 16, height: 16)
                    if !entry.lines.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(line.reason).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if entry.unread { markRead(entry) }
            if !entry.lines.isEmpty { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
        }
        .contextMenu {
            if entry.unread { Button("Mark Read") { markRead(entry) } }
            Button("Delete", role: .destructive) { delete(entry) }
        }
        .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { delete(entry) } }
        .swipeActions(edge: .leading) {
            if entry.unread { Button("Mark Read") { markRead(entry) }.tint(.accentColor) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Delete") { delete(entry) }
        .modifier(MarkReadAccessibilityAction(enabled: entry.unread) { markRead(entry) })
    }
}

private struct MarkReadAccessibilityAction: ViewModifier {
    let enabled: Bool
    let markRead: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: "Mark Read", markRead) } else { content }
    }
}
