// The account's password, API keys and sessions on iOS, the Mac's Security tab (mac/Verso/Verso/Views/Account/
// AccountSecurityView.swift) as a list of iOS's own: a row for each key and each signed-in device, swiped to delete or
// log out, each asking first.

import SwiftUI
import UIKit

struct AccountSecurityPage: View {
    let services: AccountServices
    @State private var operation = AccountOperation()
    @State private var keys: [AccountAPIKey] = []
    @State private var devices: [AccountDevice] = []
    @State private var keysUnavailable = false
    @State private var devicesUnavailable = false
    @State private var keyEditor: AccountKeyEditorItem?
    @State private var password = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var logOutOthers = false
    @State private var pending: AccountRevocation?

    var body: some View {
        Form {
            if services.features.passwordLogin {
                passwordSection
            }
            if !keysUnavailable {
                keysSection
            }
            if !devicesUnavailable {
                devicesSection
            }
            AccountOperationMessage(operation: operation)
        }
        .navigationTitle("Password and Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $keyEditor) { item in
            AccountKeyEditor(services: services, key: item.key) {
                keys = try await services.client.accountKeys()
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { shown in if !shown { pending = nil } }), titleVisibility: .visible) {
            if let action = pending {
                Button(action.button, role: .destructive) {
                    pending = nil
                    operation.run(action.work)
                }
            }
        } message: {
            Text(pending?.message ?? "")
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Current Password", text: $password)
                .textContentType(.password)
            SecureField("New Password", text: $newPassword)
                .textContentType(.newPassword)
            SecureField("Confirm New Password", text: $confirmPassword)
                .textContentType(.newPassword)
            Toggle("Log Out of Other Devices", isOn: $logOutOthers)
            Button("Change Password") {
                let current = password
                let new = newPassword
                let invalidate = logOutOthers
                operation.run {
                    try await services.client.changeAccountPassword(current: current, new: new, invalidateSessions: invalidate)
                    password = ""
                    newPassword = ""
                    confirmPassword = ""
                    if let refreshed = try? await services.client.accountDevices() { devices = refreshed }
                    try? await services.refreshAccountUser()
                    operation.message = "Password changed."
                }
            }
            .disabled(password.isEmpty || newPassword.count < 8 || newPassword != confirmPassword || operation.busy)
        } header: {
            Text("Password")
        } footer: {
            Text("Use at least 8 characters.")
        }
    }

    private var keysSection: some View {
        Section {
            ForEach(keys) { key in
                Button {
                    keyEditor = AccountKeyEditorItem(key: key)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                            .foregroundStyle(.primary)
                        Text(permissionSummary(key))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { confirmDeleting(key) }
                }
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") { keyEditor = AccountKeyEditorItem(key: key) }
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirmDeleting(key) }
                }
            }
            Button("Create API Key") { keyEditor = AccountKeyEditorItem(key: nil) }
        } header: {
            Text("API Keys")
        } footer: {
            Text("A key lets an app or a script use your account with only the permissions you give it.")
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deviceTitle(device))
                        Text("Last active \(accountDate(device.updatedAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.current {
                        Text("This Device")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if !device.current {
                        Button("Log Out", role: .destructive) { confirmLoggingOut(device) }
                    }
                }
                .contextMenu {
                    if !device.current {
                        Button("Log Out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmLoggingOut(device)
                        }
                    }
                }
            }
            if case .accessToken = services.client.credential, devices.contains(where: { !$0.current }) {
                Button("Log Out All Other Devices", role: .destructive) {
                    pending = AccountRevocation(
                        title: "Log out all other devices?", button: "Log Out All",
                        message: "Every other device signed in to your account is signed out.") {
                        try await services.client.deleteOtherAccountDevices()
                        devices = try await services.client.accountDevices()
                    }
                }
            }
        } header: {
            Text("Sessions")
        } footer: {
            Text("The devices and apps signed in to your account, with a password or single sign-on.")
        }
    }

    private func load() async {
        do { keys = try await services.client.accountKeys() }
        catch ImmichError.http(404, _) { keysUnavailable = true }
        catch { operation.error = error.localizedDescription }
        do { devices = try await services.client.accountDevices() }
        catch ImmichError.http(404, _) { devicesUnavailable = true }
        catch { operation.error = error.localizedDescription }
    }

    private func confirmDeleting(_ key: AccountAPIKey) {
        pending = AccountRevocation(
            title: "Delete “\(key.name)”?", button: "Delete Key",
            message: "Apps and scripts that use this key can no longer reach your account.") {
            try await services.client.deleteAccountKey(key.id)
            keys = try await services.client.accountKeys()
        }
    }

    private func confirmLoggingOut(_ device: AccountDevice) {
        pending = AccountRevocation(
            title: "Log out \(deviceTitle(device))?", button: "Log Out",
            message: "This device is signed out of your account.") {
            try await services.client.deleteAccountDevice(device.id)
            devices = try await services.client.accountDevices()
        }
    }

    private func permissionSummary(_ key: AccountAPIKey) -> String {
        if key.permissions.contains("all") { return "All permissions" }
        return key.permissions.joined(separator: ", ")
    }

    private func deviceTitle(_ device: AccountDevice) -> String {
        let parts = [device.deviceType, device.deviceOS, device.appVersion ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown Device" : parts.joined(separator: " · ")
    }
}

/// Something that takes away access, asked about first.
private struct AccountRevocation {
    let title: String
    let button: String
    let message: String
    let work: @MainActor () async throws -> Void
}

private struct AccountKeyEditorItem: Identifiable {
    let id = UUID()
    let key: AccountAPIKey?
}

/// Creating an API key, with its name and permissions, or renaming one. A new key's secret is shown once, to copy.
private struct AccountKeyEditor: View {
    let services: AccountServices
    let key: AccountAPIKey?
    let onSave: @MainActor () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var permissions: Set<String> = ["asset.read"]
    @State private var secret: String?
    @State private var copied = false
    @State private var operation = AccountOperation()

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let secret {
                    Section {
                        Text(secret)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = secret
                            copied = true
                        }
                    } header: {
                        Text(trimmed)
                    } footer: {
                        Text("Copy this key now. It cannot be shown again.")
                    }
                } else {
                    Section {
                        TextField("Name", text: $name)
                    }
                    if key == nil {
                        Section {
                            NavigationLink {
                                AccountKeyPermissionsPage(permissions: $permissions)
                            } label: {
                                LabeledContent("Permissions", value: permissionsSummary)
                            }
                        } footer: {
                            Text("Choose only the permissions this key needs.")
                        }
                    }
                    AccountOperationMessage(operation: operation)
                }
            }
            .navigationTitle(key == nil ? "New API Key" : "Rename API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if secret != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                if secret == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(key == nil ? "Create" : "Save", action: save)
                            .disabled(trimmed.isEmpty || trimmed == key?.name || permissions.isEmpty || operation.busy)
                    }
                }
            }
        }
        .interactiveDismissDisabled(secret != nil || operation.busy)
        .onAppear { name = key?.name ?? "" }
    }

    private var permissionsSummary: String {
        if permissions.contains("all") { return "All" }
        return permissions.count == 1 ? permissions.first ?? "" : "\(permissions.count)"
    }

    private func save() {
        let newName = trimmed
        let chosen = permissions.sorted()
        operation.run {
            if let key {
                try await services.client.renameAccountKey(id: key.id, name: newName)
                try await onSave()
                dismiss()
            } else {
                let created = try await services.client.createAccountKey(name: newName, permissions: chosen)
                secret = created.secret
                try await onSave()
            }
        }
    }
}

/// A new key's permissions, Immich's names for them, found by searching.
private struct AccountKeyPermissionsPage: View {
    @Binding var permissions: Set<String>
    @State private var search = ""

    var body: some View {
        let shown = AccountPermissions.all.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        List {
            Section {
                ForEach(shown, id: \.self) { permission in
                    Toggle(permission, isOn: Binding(
                        get: { permissions.contains(permission) },
                        set: { chosen in
                            if chosen { permissions.insert(permission) } else { permissions.remove(permission) }
                        }))
                        .font(.system(.body, design: .monospaced))
                }
            } footer: {
                Text("“all” gives the key everything your account can do.")
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Permissions")
    }
}
