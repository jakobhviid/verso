// The account's sheet on iOS, opened from its picture in Collections' toolbar (ROADMAP.md, M10: Preferences live
// here): first the notifications while there are any (AccountNotifications.swift), where the Mac and Linux have the
// bell; then the profile with its picture, name and email, the storage used and the server (with the certificate
// trusted for it, and Forget), the account's Immich features, its password, API keys and sessions, Administration for
// an admin, backing this iPhone up (BackupSettingsSection), what Verso keeps on this device (Verso Drive in the Files
// app, the app icon, and Look Up Place Names with Apple Maps, Verso Drive and Look Up off until switched on, and the
// image cache), About Verso, and Sign Out. A list of iOS's own, as Settings has the Apple Account; what each page does
// is the Mac's Settings'. The server's notifications and the account are read again as it opens and on a pull.

import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccountSheet: View {
    let services: AccountServices
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var forgettingCertificate = false
    /// The files in Verso Drive's Upload that have not reached Immich, which signing out removes with the drive.
    @State private var filesWaitingInUpload = 0
    @State private var cacheSize: Int64 = 0
    /// The viewer's place names from Apple's maps (ViewerPlaceNames), a choice of this device's alone.
    @AppStorage(ViewerPlaceNames.appleMapsKey) private var looksUpPlaceNames = false

    var body: some View {
        NavigationStack {
            List {
                AccountNotificationsSections(services: services)
                Section {
                    AccountProfileHeader(services: services)
                        .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink {
                        AccountNamePage(services: services)
                    } label: {
                        LabeledContent("Name", value: services.user?.name ?? "")
                    }
                    LabeledContent("Email") {
                        Text(services.user?.email ?? "").textSelection(.enabled)
                    }
                    storage
                }
                Section("Server") {
                    LabeledContent("Address") {
                        Text(services.client.serverURL.absoluteString).textSelection(.enabled)
                    }
                    LabeledContent("Immich", value: services.version?.description ?? "Unknown")
                    // A session from a password and one from a browser look the same afterwards, so only a key is said.
                    if case .apiKey = services.client.credential {
                        LabeledContent("Signed In With", value: "API Key")
                    }
                    // The certificate trusted for the server where this device does not trust its own (ARCHITECTURE.md,
                    // "A certificate of the server's own"), and forgetting it, which closes the sheet: the question
                    // about the server's certificate then comes over the library.
                    if let certificate = services.trustedCertificate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Trusted Certificate (SHA-256)")
                            Text(CertificateQuestion.lines(certificate, pairs: 8))
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("trustedCertificate")
                        Button("Forget Certificate…", role: .destructive) { forgettingCertificate = true }
                            .confirmationDialog("Forget the Certificate?", isPresented: $forgettingCertificate,
                                                titleVisibility: .visible) {
                                Button("Forget", role: .destructive) {
                                    dismiss()
                                    services.forgetCertificate()
                                }
                            } message: {
                                Text("Verso stops trusting this certificate and connects again, asking about the server's certificate, unless this \(UIDevice.current.model) trusts it.")
                            }
                    }
                }
                Section {
                    NavigationLink {
                        AccountPreferencesPage(services: services)
                    } label: {
                        Label("Immich Features", systemImage: "switch.2")
                    }
                    NavigationLink {
                        AccountSecurityPage(services: services)
                    } label: {
                        Label("Password and Security", systemImage: "lock")
                    }
                    NavigationLink {
                        AccountAppleTVPage(services: services)
                    } label: {
                        Label("Set Up Apple TV", systemImage: "appletv")
                    }
                    if services.user?.isAdmin == true {
                        NavigationLink {
                            AccountAdministrationPage(services: services)
                        } label: {
                            Label("Administration", systemImage: "server.rack")
                        }
                    }
                }
                BackupSettingsSection(services: services)
                Section {
                    // Verso Drive belongs to this device: its location is in this device's Files app, and its switch
                    // and settings are kept here, not on the server.
                    NavigationLink {
                        AccountDrivePage(services: services)
                    } label: {
                        LabeledContent("Verso Drive",
                                       value: VersoDrive.shared.isOn ? String(localized: "On") : String(localized: "Off"))
                    }
                    // The Home Screen's icon is this device's too (AccountAppIconPage).
                    AccountAppIconRow()
                    Toggle("Look Up Place Names with Apple Maps", isOn: $looksUpPlaceNames)
                } header: {
                    Text("On This \(UIDevice.current.model)")
                } footer: {
                    Text("A photo's title names the landmark or park where it was taken, as Photos does. Verso sends the photo's location to Apple to look it up. Off, places are named from your Immich server alone.")
                }
                Section {
                    LabeledContent("Image Cache", value: cacheSize.formatted(.byteCount(style: .file)))
                    Button("Clear Image Cache", action: clearCache)
                        .disabled(cacheSize == 0)
                } footer: {
                    Text("Thumbnails and photos Verso keeps to show them again quickly. Cleared, they are read from your server again as they are shown.")
                }
                Section {
                    NavigationLink {
                        AccountAboutPage()
                    } label: {
                        Label("About Verso", systemImage: "info.circle")
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            filesWaitingInUpload = await VersoDrive.shared.filesWaitingInUpload()
                            confirmingSignOut = true
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .disabled(app.switching)
                        .confirmationDialog("Sign out of \(serverName)?", isPresented: $confirmingSignOut,
                                            titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) {
                                Task { await app.signOut() }
                            }
                        } message: {
                            Text(signOutMessage)
                        }
                }
            }
            .refreshable { await reload() }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task {
            cacheSize = currentCacheSize
            await reload()
        }
    }

    /// The server's notifications, then the storage used and the picture, as they are now.
    private func reload() async {
        await services.reloadNotificationsNow()
        try? await services.refreshAccountUser()
    }

    @ViewBuilder
    private var storage: some View {
        if let used = services.user?.quotaUsageInBytes {
            if let quota = services.user?.quotaSizeInBytes, quota > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Storage",
                                   value: "\(used.formatted(.byteCount(style: .file))) of \(quota.formatted(.byteCount(style: .file)))")
                    ProgressView(value: Double(min(max(used, 0), quota)), total: Double(quota))
                        .tint(Double(used) / Double(quota) > 0.9 ? .orange : .accentColor)
                }
            } else {
                LabeledContent("Storage", value: "\(used.formatted(.byteCount(style: .file))) used")
            }
        }
    }

    private var serverName: String {
        services.client.serverURL.host() ?? services.client.serverURL.absoluteString
    }

    private var signOutMessage: String {
        let forgets = "Verso forgets this account on this \(UIDevice.current.model). Your photos and videos stay in your Immich library."
        let importing = services.upload.isRunning ? " The import under way stops." : ""
        let waiting = AccountDrivePage.waitingMessage(filesWaitingInUpload)
        return forgets + importing + (waiting.isEmpty ? "" : " " + waiting)
    }

    private var currentCacheSize: Int64 {
        Int64(services.client.session.configuration.urlCache?.currentDiskUsage ?? 0)
    }

    /// As the Mac's Clear Cache: the images go, and every grid reads its own again.
    private func clearCache() {
        services.pipeline.removeAll()
        services.client.session.configuration.urlCache?.removeAllCachedResponses()
        services.metadata.imageRevision += 1
        services.invalidateGrids()
        cacheSize = currentCacheSize
    }
}

/// The top of the account's sheet: the picture large, with Edit under it to choose another or remove it, then the
/// name and email.
private struct AccountProfileHeader: View {
    let services: AccountServices
    @State private var operation = AccountOperation()
    @State private var choosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 8) {
            AccountCircle(user: services.user, picture: services.profilePicture, size: 88)
                .overlay {
                    if operation.busy {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().tint(.white)
                    }
                }
            Menu {
                Button("Choose Photo…", systemImage: "photo.on.rectangle") { choosingPicture = true }
                if services.user?.profileImagePath?.isEmpty == false {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        operation.run {
                            try await services.client.removeAccountPicture()
                            try await services.refreshAccountUser()
                        }
                    }
                }
            } label: {
                Text("Edit")
                    .font(.footnote.weight(.semibold))
            }
            .disabled(operation.busy)
            if let user = services.user {
                Text(user.name.isEmpty ? user.email : user.name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !user.name.isEmpty {
                    Text(user.email)
                        .foregroundStyle(.secondary)
                }
                if user.isAdmin == true {
                    Text("Administrator")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = operation.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .photosPicker(isPresented: $choosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            pickedPicture = nil
            operation.run {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImmichError.http(400, "The photo could not be read.")
                }
                let jpeg = try await Task.detached(priority: .userInitiated) {
                    try accountPictureJPEG(from: data)
                }.value
                try await services.client.uploadAccountPicture(jpeg)
                try await services.refreshAccountUser()
            }
        }
    }
}

/// The account's name, as Immich shows it to the people albums are shared with.
private struct AccountNamePage: View {
    let services: AccountServices
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var operation = AccountOperation()
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
            } footer: {
                if let error = operation.error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("The name people see when you share albums with them.")
                }
            }
        }
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if operation.busy {
                    ProgressView()
                } else {
                    Button("Save", action: save)
                        .disabled(trimmed.isEmpty || trimmed == services.user?.name)
                }
            }
        }
        .onAppear {
            name = services.user?.name ?? ""
            focused = true
        }
    }

    private func save() {
        guard !trimmed.isEmpty, trimmed != services.user?.name else { return }
        let newName = trimmed
        operation.run {
            _ = try await services.client.updateAccountName(newName)
            try await services.refreshAccountUser()
            dismiss()
        }
    }
}

/// A square JPEG of at most 512 pixels from the chosen photo, as the Mac makes a profile picture.
nonisolated private func accountPictureJPEG(from data: Data) throws -> Data {
    guard data.count <= 50 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 512,
          ] as CFDictionary) else {
        throw ImmichError.http(400, "Choose a supported photo smaller than 50 MB.")
    }
    let side = min(image.width, image.height)
    let square = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    let output = NSMutableData()
    guard let cropped = image.cropping(to: square),
          let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ImmichError.http(400, "The profile picture could not be made.")
    }
    CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ImmichError.http(400, "The profile picture could not be made.")
    }
    return output as Data
}

/// What an account operation came to, under the form that ran it: a spinner while it runs, then its message or error.
struct AccountOperationMessage: View {
    let operation: AccountOperation

    var body: some View {
        if operation.busy {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
        if let error = operation.error {
            Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let message = operation.message {
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}
