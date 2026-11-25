import SwiftUI
import VersoCore

/// Settings ▸ Verso Drive: the switch, the drive's status, and its settings from the core's settings table, as Verso's
/// Preferences on Linux have them (ARCHITECTURE.md, "Verso on the Mac").
struct VersoDriveSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var drive = VersoDrive.shared
    @State private var panes: SettingsPanes?

    @AppStorage(VersoDrive.disconnectOnQuitKey) private var disconnectOnQuit = true

    var body: some View {
        Form {
            Section {
                Toggle("Verso Drive", isOn: Binding(get: { drive.isOn }, set: { on in Task { await drive.setOn(on) } }))
                    .disabled(app.services == nil || drive.busy)
                if drive.isOn {
                    Toggle("Disconnect When Verso Quits", isOn: $disconnectOnQuit)
                }
            } footer: {
                Text("Your library as a location in Finder's sidebar, and in every app's Open and Save dialogs. Photos download only when you open them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if app.services == nil {
                Section { Text("Sign in to use Verso Drive.").foregroundStyle(.secondary) }
            } else if drive.isOn {
                Section("Status") {
                    LabeledContent("Server", value: serverLine)
                    if let version = drive.status?.version { LabeledContent("Immich", value: version) }
                    if drive.locationSwitchedOff {
                        Label("Switch it on with Enable at the top of its Finder window, or in System Settings ▸ General ▸ Login Items & Extensions ▸ File Providers.",
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Button("Show in Finder") { Task { await drive.showInFinder() } }
                }
                if let panes {
                    Section("Folders") {
                        ForEach(panes.sections, id: \.name) { section in
                            row(section.shown, title: section.name)
                            if let dateFolders = section.dateFolders { row(dateFolders) }
                        }
                    }
                    Section("Names and Uploads") {
                        row(panes.albumLayout)
                        row(panes.fileNaming)
                        row(panes.uploadFolders)
                        row(panes.webLinks)
                    }
                }
            }
            if let error = drive.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task {
            panes = try? DriveCore.panes()
            await drive.refreshState()
        }
    }

    private var serverLine: String {
        let host = app.services?.client.serverURL.host() ?? ""
        guard let status = drive.status else { return host }
        return status.online ? String(localized: "Connected to \(host)") : (status.problem ?? String(localized: "\(host) is not reachable"))
    }

    /// One setting: a switch, or a menu of its choices.
    @ViewBuilder
    private func row(_ preference: Preference, title: String? = nil) -> some View {
        switch preference.kind {
        case .toggle:
            Toggle(title ?? preference.title, isOn: Binding(get: { preference.value == "true" },
                                                           set: { on in change(preference, to: on ? "true" : "false") }))
        case .choice(let options):
            Picker(title ?? preference.title, selection: Binding(get: { preference.value }, set: { change(preference, to: $0) })) {
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
        }
    }

    private func change(_ preference: Preference, to value: String) {
        Task {
            await drive.setPreference(preference.key, to: value)
            panes = try? DriveCore.panes()
        }
    }
}
