// The account's Immich features on iOS, the Mac's Preferences tab (mac/Verso/Verso/Views/Account/
// AccountPreferencesView.swift) as a form of iOS's own: memories, people, ratings, tags, folders and shared links,
// their settings, downloads, email notifications, and what Immich's web app shows. They are the account's, kept on the
// server for every app; a change is saved as it is made, as Settings saves on iOS.

import SwiftUI

struct AccountPreferencesPage: View {
    let services: AccountServices
    @State private var draft = AccountPreferences()
    @State private var operation = AccountOperation()
    @State private var loaded = false
    /// What the server last returned: saving sends what the draft changes from it.
    @State private var saved: AccountPreferences?
    @State private var pendingSave: Task<Void, Never>?

    /// The features, with what each one is.
    private var features: [AccountFeature] {
        [AccountFeature(title: "Memories", about: "Photos from this day in past years.", keyPath: \.memories),
         AccountFeature(title: "People", about: "The faces Immich recognises, and their pages.", keyPath: \.people),
         AccountFeature(title: "Ratings", about: "Stars from one to five on each photo.", keyPath: \.ratings),
         AccountFeature(title: "Tags", about: "Tags on photos, and a page for each.", keyPath: \.tags),
         AccountFeature(title: "Folders", about: "The library by the folders its files are in on the server.",
                        keyPath: \.folders),
         AccountFeature(title: "Shared Links", about: "Links that share albums and photos with anyone who has them.",
                        keyPath: \.sharedLinks)]
    }

    var body: some View {
        Form {
            if loaded && !operation.unavailable {
                featureSections
                detailSections
                webAppSection
            } else if operation.busy {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let error = operation.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Immich Features")
        .navigationBarTitleDisplayMode(.inline)
        // As on the Mac: a switch or a stepper saves after a brief pause, and anything still waiting as the page goes.
        .onChange(of: draft) {
            if loaded { scheduleSave() }
        }
        .onDisappear {
            pendingSave?.cancel()
            if loaded { save(draft) }
        }
        .alert("Couldn't Save Your Changes", isPresented: Binding(
            get: { loaded && services.preferencesSaveError != nil },
            set: { shown in if !shown { services.preferencesSaveError = nil } })) {
            Button("OK") { services.preferencesSaveError = nil }
        } message: {
            Text(services.preferencesSaveError ?? "")
        }
        .task {
            operation.run(probe: true) {
                // Waits for a save made as the page last closed, so this reads what it stored.
                let preferences = try await services.queuePreferences { try await services.client.accountPreferences() }
                saved = preferences
                draft = preferences
                services.setPreferences(preferences)
                loaded = true
            }
        }
    }

    @ViewBuilder
    private var featureSections: some View {
        let shown = features.filter { draft[keyPath: $0.keyPath]?.enabled != nil }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { feature in
                    Toggle(isOn: enabled(feature.keyPath)) {
                        Text(feature.title)
                        Text(feature.about)
                    }
                }
            } header: {
                Text("Features")
            } footer: {
                Text("They are your account's, on your Immich server: a feature turned off here is off in every app you use with it.")
            }
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        if draft.memories?.enabled != false, draft.memories?.duration != nil {
            Section("Memories") {
                Stepper("Memory Duration: \(draft.memories?.duration ?? 5) seconds", value: Binding(
                    get: { draft.memories?.duration ?? 5 }, set: { draft.memories?.duration = $0 }), in: 1...60)
            }
        }
        if draft.people != nil {
            Section {
                Stepper("Minimum Faces: \(draft.people?.minimumFaces ?? 1)", value: Binding(
                    get: { draft.people?.minimumFaces ?? 1 }, set: { draft.people?.minimumFaces = $0 }), in: 1...1000)
                Picker("Changes to a Person", selection: Binding(
                    get: { draft.people?.updateStrategy ?? "self" }, set: { draft.people?.updateStrategy = $0 })) {
                    Text("Only This Person").tag("self")
                    Text("Everyone").tag("everyone")
                }
            } header: {
                Text("People")
            } footer: {
                Text("A person is shown once Immich has found their face in this many photos.")
            }
        }
        if draft.albums != nil {
            Section("Albums") {
                Picker("Order of Photos", selection: Binding(
                    get: { draft.albums?.defaultAssetOrder ?? "desc" }, set: { draft.albums?.defaultAssetOrder = $0 })) {
                    Text("Newest First").tag("desc")
                    Text("Oldest First").tag("asc")
                }
            }
        }
        if draft.download != nil {
            Section {
                LabeledContent("Archive Size") {
                    TextField("GiB", value: archiveSize, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if draft.download?.includeEmbeddedVideos != nil {
                    Toggle("Include Embedded Videos", isOn: Binding(
                        get: { draft.download?.includeEmbeddedVideos ?? false },
                        set: { draft.download?.includeEmbeddedVideos = $0 }))
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("A download of many photos is split into archives of at most this many GiB.")
            }
        }
        if draft.emailNotifications != nil {
            Section("Email Notifications") {
                Toggle("Email Notifications", isOn: Binding(
                    get: { draft.emailNotifications?.enabled ?? false }, set: { draft.emailNotifications?.enabled = $0 }))
                Toggle("Album Invitations", isOn: Binding(
                    get: { draft.emailNotifications?.albumInvite ?? false }, set: { draft.emailNotifications?.albumInvite = $0 }))
                    .disabled(draft.emailNotifications?.enabled == false)
                Toggle("Album Updates", isOn: Binding(
                    get: { draft.emailNotifications?.albumUpdate ?? false }, set: { draft.emailNotifications?.albumUpdate = $0 }))
                    .disabled(draft.emailNotifications?.enabled == false)
            }
        }
    }

    /// What Immich's web app shows in its sidebar, and its other settings of its own.
    @ViewBuilder
    private var webAppSection: some View {
        let sidebar = features.filter { draft[keyPath: $0.keyPath]?.sidebarWeb != nil }
        let others = draft.recentlyAdded?.sidebarWeb != nil || draft.cast?.gCastEnabled != nil
            || draft.purchase?.showSupportBadge != nil
        if !sidebar.isEmpty || others {
            Section {
                ForEach(sidebar) { feature in
                    Toggle("\(feature.title) in the Sidebar", isOn: Binding(
                        get: { draft[keyPath: feature.keyPath]?.sidebarWeb ?? false },
                        set: { draft[keyPath: feature.keyPath]?.sidebarWeb = $0 }))
                }
                if draft.recentlyAdded?.sidebarWeb != nil {
                    Toggle("Recently Added in the Sidebar", isOn: Binding(
                        get: { draft.recentlyAdded?.sidebarWeb ?? false }, set: { draft.recentlyAdded?.sidebarWeb = $0 }))
                }
                if draft.cast?.gCastEnabled != nil {
                    Toggle("Google Cast", isOn: Binding(
                        get: { draft.cast?.gCastEnabled ?? false }, set: { draft.cast?.gCastEnabled = $0 }))
                }
                if draft.purchase?.showSupportBadge != nil {
                    Toggle("Show Support Badge", isOn: Binding(
                        get: { draft.purchase?.showSupportBadge ?? false }, set: { draft.purchase?.showSupportBadge = $0 }))
                }
            } header: {
                Text("Immich Web App")
            } footer: {
                Text("These change Immich's web app in your browser, not Verso.")
            }
        }
    }

    private func enabled(_ keyPath: WritableKeyPath<AccountPreferences, AccountPreferences.Feature?>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath]?.enabled ?? false },
                set: { draft[keyPath: keyPath]?.enabled = $0 })
    }

    /// The archive size in GiB, as Immich's web app asks for it; the server keeps bytes.
    private var archiveSize: Binding<Double> {
        let bytesPerGiB = 1_073_741_824.0
        return Binding(
            get: { Double(draft.download?.archiveSize ?? 4_294_967_296) / bytesPerGiB },
            set: { value in
                // Leaving the field commits the rounded number it shows; that isn't a change.
                let current = Double(draft.download?.archiveSize ?? 4_294_967_296) / bytesPerGiB
                guard value.isFinite, abs(value - current) > 0.001 else { return }
                draft.download?.archiveSize = Int64(min(max(value, 0.01), 8192) * bytesPerGiB)
            })
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(draft)
        }
    }

    /// Saves queue behind earlier ones and send only what `value` changes from what the server last returned, so
    /// switching something back while a save is in flight is saved too. A failed save puts back the server's values
    /// and says why.
    private func save(_ value: AccountPreferences) {
        let services = services
        Task {
            do {
                let stored = try await services.queuePreferences { () async throws -> AccountPreferences? in
                    guard let base = saved else { return nil }
                    let changes = value.changes(from: base)
                    guard changes != AccountPreferences() else { return nil }
                    return try await services.client.updateAccountPreferences(changes)
                }
                guard let stored else { return }
                services.setPreferences(stored)
                saved = stored
                // Later changes made while this was saving stay in the draft for their own save.
                if draft == value { draft = stored }
            } catch {
                services.handle(error)
                services.preferencesSaveError = error.localizedDescription
                if draft == value, let saved { draft = saved }
            }
        }
    }
}

/// One of the account's Immich features: its name, what it is, and where the preferences keep it.
private struct AccountFeature: Identifiable {
    let title: String
    let about: String
    let keyPath: WritableKeyPath<AccountPreferences, AccountPreferences.Feature?>
    var id: String { title }
}
