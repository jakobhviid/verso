// Administration on iOS, for an admin, in the account's sheet (ROADMAP.md, M10): the Mac's Administration window
// (mac/Verso/Verso/Views/Admin/AdminWindow.swift) as pages of iOS's own over the same AdminModel. The server's
// statistics, storage and version; its jobs, each started and paused from its menu; its users, made, changed, deleted
// and restored; its external libraries, scanned or deleted; and its settings, read only. Changing a library's paths
// is left to the Mac and Immich's web app.

import SwiftUI

struct AccountAdministrationPage: View {
    let services: AccountServices
    @State private var model: AdminModel?

    var body: some View {
        Group {
            if let model {
                if model.authorized {
                    List {
                        ForEach(AdminModel.Section.allCases.filter { !model.unavailable.contains($0) }) { section in
                            NavigationLink {
                                AccountAdminSectionPage(model: model, section: section)
                            } label: {
                                Label(String(localized: section.title), systemImage: section.icon)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Administrator Access Required", systemImage: "lock.shield")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Administration")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = AdminModel(session: services) }
        }
    }
}

/// One of Administration's pages, loading its part of the server as it shows; Jobs again every 10 seconds, as on the
/// Mac.
private struct AccountAdminSectionPage: View {
    let model: AdminModel
    let section: AdminModel.Section
    @State private var pending: AccountAdminConfirmation?
    @State private var userEditor: AccountAdminUserItem?

    var body: some View {
        content
            .navigationTitle(String(localized: section.title))
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.busy)
            .refreshable { await model.refresh() }
            .toolbar {
                if model.busy {
                    ToolbarItem(placement: .primaryAction) { ProgressView() }
                }
                if !model.busy && section == .users {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New User", systemImage: "person.badge.plus") {
                            model.error = nil
                            userEditor = AccountAdminUserItem(user: nil)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if userEditor == nil, let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.error = nil }
                            .font(.footnote)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .task(id: section) {
                model.section = section
                await model.refresh()
                while !Task.isCancelled && section == .queues && model.authorized && !model.unavailable.contains(.queues) {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await model.refresh(polling: true)
                }
            }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(
                get: { pending != nil }, set: { shown in if !shown { pending = nil } }), titleVisibility: .visible) {
                if let action = pending {
                    Button(action.button, role: .destructive) {
                        pending = nil
                        Task { _ = await model.perform(action.work) }
                    }
                }
            } message: {
                Text(pending?.message ?? "")
            }
            .sheet(item: $userEditor, onDismiss: { model.error = nil }) { item in
                AccountAdminUserEditor(model: model, user: item.user)
            }
            .alert("Administration", isPresented: Binding(
                get: { model.notice != nil }, set: { shown in if !shown { model.notice = nil } })) {
                Button("OK") { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.unavailable.contains(section) {
            ContentUnavailableView("Unavailable on This Server", systemImage: "server.rack")
        } else {
            switch section {
            case .overview: overview
            case .queues: queues
            case .users: users
            case .libraries: libraries
            case .settings: settings
            }
        }
    }

    // MARK: The server

    private var overview: some View {
        List {
            if let statistics = model.overview["Statistics"] {
                Section("Library") {
                    LabeledContent("Photos", value: count(statistics["photos"]))
                    LabeledContent("Videos", value: count(statistics["videos"]))
                    LabeledContent("Storage Used", value: bytes(statistics["usage"]))
                }
                if case .array(let users)? = statistics["usageByUser"], !users.isEmpty {
                    Section("By User") {
                        ForEach(users.indices, id: \.self) { index in
                            let user = users[index]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user["userName"]?.display ?? "")
                                Text("\(count(user["photos"])) photos, \(count(user["videos"])) videos, \(bytes(user["usage"]))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let storage = model.overview["Storage"] {
                Section("Disk") {
                    if case .number(let percentage)? = storage["diskUsagePercentage"] {
                        ProgressView(value: min(max(percentage, 0), 100), total: 100)
                            .tint(percentage > 90 ? .orange : .accentColor)
                    }
                    LabeledContent("Used", value: storage["diskUse"]?.display ?? "")
                    LabeledContent("Available", value: storage["diskAvailable"]?.display ?? "")
                    LabeledContent("Size", value: storage["diskSize"]?.display ?? "")
                }
            }
            if let version = model.overview["Version"] {
                Section("Immich") {
                    LabeledContent("Version", value: versionText(version))
                    if let check = model.overview["Version Check"], let release = check["releaseVersion"]?.display {
                        LabeledContent("Latest Release", value: release)
                    }
                }
            }
        }
    }

    private func count(_ value: AdminValue?) -> String {
        if case .number(let number)? = value { return Int(number).formatted() }
        return value?.display ?? ""
    }

    private func bytes(_ value: AdminValue?) -> String {
        if case .number(let number)? = value, number.isFinite, number >= 0, number < Double(Int64.max) {
            return Int64(number).formatted(.byteCount(style: .file))
        }
        return value?.display ?? ""
    }

    private func versionText(_ version: AdminValue) -> String {
        let parts = ["major", "minor", "patch"].map { count(version[$0]) }
        return parts.contains("") ? version.display : parts.joined(separator: ".")
    }

    // MARK: Jobs

    private var queues: some View {
        List {
            Section {
                ForEach(AdminQueue.managedNames.compactMap { name in model.queues.first { $0.name == name } }) { queue in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(queue.title)
                                if queue.isPaused {
                                    Text("Paused")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                } else if queue.statistics.active > 0 {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            Text(queueCounts(queue))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        queueMenu(queue)
                    }
                }
            } footer: {
                Text(model.pollingError ?? "Read again every 10 seconds while this page shows.")
            }
        }
    }

    private func queueCounts(_ queue: AdminQueue) -> String {
        let statistics = queue.statistics
        var parts = ["\(statistics.active) active", "\(statistics.waiting) waiting"]
        if statistics.failed > 0 { parts.append("\(statistics.failed) failed") }
        if statistics.delayed > 0 { parts.append("\(statistics.delayed) delayed") }
        if statistics.paused > 0 { parts.append("\(statistics.paused) paused") }
        return parts.joined(separator: ", ")
    }

    private func queueMenu(_ queue: AdminQueue) -> some View {
        Menu {
            Button(queue.isPaused ? "Resume" : "Pause", systemImage: queue.isPaused ? "play" : "pause") {
                command(queue, queue.isPaused ? "resume" : "pause")
            }
            if model.canStart(queue) {
                Button(queue.startTitle, systemImage: "play.circle") { command(queue, "start") }
                if queue.name == "faceDetection" {
                    Button("Refresh Faces", systemImage: "arrow.clockwise") {
                        Task { _ = await model.perform { try await model.client.adminQueueCommand(queue.name, command: "start", force: nil) } }
                    }
                }
                if queue.canStartAll {
                    Button(queue.allTitle, systemImage: "arrow.trianglehead.2.clockwise") {
                        pending = AccountAdminConfirmation(
                            title: "Process all assets again?", button: "Process All",
                            message: "This can take a long time. Face detection and recognition reset the faces found so far; sidecar jobs sync the metadata.") {
                            try await model.client.adminQueueCommand(queue.name, command: "start", force: true)
                        }
                    }
                }
            }
            Divider()
            Button("Clear Failed Jobs", systemImage: "xmark.circle", role: .destructive) { command(queue, "clear-failed") }
                .disabled(queue.statistics.failed == 0)
            Button("Clear Queue…", systemImage: "trash", role: .destructive) {
                pending = AccountAdminConfirmation(
                    title: "Clear \(queue.title)?", button: "Clear Queue",
                    message: "Waiting jobs are removed. Failed jobs are kept, and active ones may finish.") {
                    try await model.client.adminQueueCommand(queue.name, command: "empty")
                }
            }
        } label: {
            Image(systemName: queue.isPaused ? "pause.circle.fill" : "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(queue.isPaused ? .orange : .accentColor)
        }
        .accessibilityLabel("Actions for \(queue.title)")
    }

    private func command(_ queue: AdminQueue, _ command: String) {
        Task { _ = await model.perform { try await model.client.adminQueueCommand(queue.name, command: command) } }
    }

    // MARK: Users

    private var users: some View {
        List(model.users) { user in
            Button {
                guard !user.isDeleted else { return }
                model.error = nil
                userEditor = AccountAdminUserItem(user: user)
            } label: {
                HStack(spacing: 12) {
                    AccountCircle(name: user.name, email: user.email, avatarColor: nil, size: 36)
                        .opacity(user.isDeleted ? 0.5 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .foregroundStyle(.primary)
                        Text(user.email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(userLine(user))
                            .font(.footnote)
                            .foregroundStyle(user.isDeleted ? Color.red : Color.secondary)
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                if user.isDeleted {
                    Button("Restore") { restore(user) }
                        .tint(.accentColor)
                        .disabled(user.status == "removing")
                } else if user.id != model.session.user?.id {
                    Button("Delete", role: .destructive) { delete(user, force: false) }
                }
            }
            .contextMenu {
                if user.isDeleted {
                    Button("Restore User", systemImage: "arrow.uturn.backward") { restore(user) }
                        .disabled(user.status == "removing")
                } else {
                    Button("Edit User…", systemImage: "pencil") {
                        model.error = nil
                        userEditor = AccountAdminUserItem(user: user)
                    }
                    if user.id != model.session.user?.id {
                        Button("Delete User…", systemImage: "trash", role: .destructive) { delete(user, force: false) }
                        Button("Delete User and Photos…", systemImage: "trash.slash", role: .destructive) { delete(user, force: true) }
                    }
                }
            }
        }
    }

    private func userLine(_ user: AdminUser) -> String {
        if user.isDeleted { return "Deleted, \(user.status ?? "pending removal")" }
        let used = (user.quotaUsageInBytes ?? 0).formatted(.byteCount(style: .file))
        let quota = user.quotaSizeInBytes.map { "of \($0.formatted(.byteCount(style: .file)))" } ?? "used, no quota"
        let role = user.isAdmin ? "Administrator, " : ""
        return "\(role)\(used) \(quota)"
    }

    private func restore(_ user: AdminUser) {
        Task { _ = await model.perform { try await model.client.adminRestoreUser(user.id) } }
    }

    private func delete(_ user: AdminUser, force: Bool) {
        pending = AccountAdminConfirmation(
            title: "Delete \(user.name)?", button: force ? "Delete User and Photos" : "Delete User",
            message: force
                ? "The user and their photos and videos are removed for good. This cannot be undone once removal starts."
                : "The user is scheduled for deletion, and can be restored until the server removes the account.") {
            try await model.client.adminDeleteUser(user.id, force: force)
        }
    }

    // MARK: External libraries

    private var libraries: some View {
        List {
            if model.libraries.isEmpty {
                Text("No external libraries.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.libraries) { library in
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.name)
                    Text("\(library.assetCount.formatted()) items, \(model.users.first { $0.id == library.ownerId }?.name ?? library.ownerId)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(library.importPaths.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { deleteLibrary(library) }
                    Button("Scan") { scan(library) }
                        .tint(.accentColor)
                }
                .contextMenu {
                    Button("Scan Library", systemImage: "arrow.clockwise") { scan(library) }
                    Button("Delete Library…", systemImage: "trash", role: .destructive) { deleteLibrary(library) }
                }
            }
        }
    }

    private func scan(_ library: AdminLibrary) {
        Task {
            _ = await model.perform {
                try await model.client.adminScanLibrary(library.id)
                model.notice = "The library's scan is queued. Jobs shows how it goes."
            }
        }
    }

    private func deleteLibrary(_ library: AdminLibrary) {
        pending = AccountAdminConfirmation(
            title: "Delete \(library.name)?", button: "Delete Library",
            message: "Immich removes this library's photos and videos from itself. The files on the server's disk are kept.") {
            try await model.client.adminDeleteLibrary(library.id)
        }
    }

    // MARK: Server settings

    private var settings: some View {
        List {
            Section {
                if let settings = model.settings {
                    AccountAdminValueRows(value: settings)
                }
            } footer: {
                Text("The server's settings are read only here. Change them in Immich's web app.")
            }
        }
    }
}

/// An administrative change that is asked about first.
private struct AccountAdminConfirmation {
    let title: String
    let button: String
    let message: String
    let work: () async throws -> Void
}

private struct AccountAdminUserItem: Identifiable {
    let id = UUID()
    let user: AdminUser?
}

/// The server's settings as rows: each value with its name, and each group of them opening out.
private struct AccountAdminValueRows: View {
    let value: AdminValue

    var body: some View {
        switch value {
        case .object(let fields):
            ForEach(fields.keys.sorted(), id: \.self) { key in
                if let field = fields[key] {
                    switch field {
                    case .object, .array:
                        DisclosureGroup(key) { AccountAdminValueRows(value: field) }
                    default:
                        LabeledContent(key, value: field.display(forKey: key))
                            .textSelection(.enabled)
                    }
                }
            }
        case .array(let values):
            ForEach(values.indices, id: \.self) { index in
                AccountAdminValueRows(value: values[index])
            }
        default:
            Text(value.display)
                .textSelection(.enabled)
        }
    }
}

/// A new user, or a user's name, email, password, quota and role.
private struct AccountAdminUserEditor: View {
    let model: AdminModel
    let user: AdminUser?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var email: String
    @State private var password = ""
    @State private var quota: String
    @State private var isAdmin: Bool
    @State private var shouldChangePassword: Bool

    init(model: AdminModel, user: AdminUser?) {
        self.model = model
        self.user = user
        _name = State(initialValue: user?.name ?? "")
        _email = State(initialValue: user?.email ?? "")
        _quota = State(initialValue: AdminQuota.text(from: user?.quotaSizeInBytes))
        _isAdmin = State(initialValue: user?.isAdmin ?? false)
        _shouldChangePassword = State(initialValue: user?.shouldChangePassword ?? true)
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && email.contains("@")
            && (user != nil || !password.isEmpty)
            && (quota.isEmpty || AdminQuota.bytes(from: quota) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if user?.id != model.session.user?.id {
                        SecureField(user == nil ? "Password" : "New Password", text: $password)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    if user != nil && user?.id != model.session.user?.id {
                        Text("Leave the password empty to keep it.")
                    }
                }
                Section {
                    LabeledContent("Quota") {
                        TextField("Unlimited", text: $quota)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("In GiB. Empty for no quota.")
                }
                Section {
                    Toggle("Administrator", isOn: $isAdmin)
                    Toggle("Change Password at Next Sign-In", isOn: $shouldChangePassword)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(user == nil ? "New User" : "Edit User")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(model.busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!valid)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.busy)
    }

    private func save() {
        let input = AdminUserInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            isAdmin: isAdmin, password: password.isEmpty ? nil : password,
            shouldChangePassword: shouldChangePassword, quotaSizeInBytes: AdminQuota.bytes(from: quota))
        let id = user?.id
        Task {
            if await model.perform({ try await model.client.adminSaveUser(id: id, input: input) }) { dismiss() }
        }
    }
}
