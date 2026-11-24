// Verso Drive on iOS, a page of the account's sheet under "On This iPhone" (AccountSheet.swift): the library as folders
// in the Files app, through the Mac's File Provider extension (ARCHITECTURE.md, "Verso Drive on the Mac"). The switch,
// off until the person switches it on; while on, the status, Show in Files, and the drive's settings from the core's
// settings table, as the Mac's Settings, Verso Drive (VersoDriveSettingsView.swift), without Open in Immich and Copy
// Immich Link, which Files does not offer. A new location waits, as on the Mac, until the person turns it on in Files,
// which asks as it is first opened there; the page says how meanwhile. iOS removes a location whole, so switching off
// while files wait in Upload asks first (VersoDrive.filesWaitingInUpload).

import SwiftUI
import UIKit
import VersoCore

struct AccountDrivePage: View {
    let services: AccountServices
    @State private var drive = VersoDrive.shared
    @State private var panes: SettingsPanes?
    /// The files in Upload that have not reached Immich, while switching off waits for the person's answer.
    @State private var waitingFiles = 0
    @State private var confirmingOff = false

    var body: some View {
        Form {
            Section {
                Toggle("Verso Drive", isOn: Binding(get: { drive.isOn }, set: { on in switchTo(on) }))
                    .disabled(drive.busy)
            } footer: {
                Text("Your library as folders in the Files app and in every app that opens files. Photos download only when you open them, and what you copy into Upload is added to your library.")
            }
            if drive.isOn {
                Section("Status") {
                    LabeledContent("Server", value: serverLine)
                    if let version = drive.status?.version { LabeledContent("Immich", value: version) }
                    if drive.locationSwitchedOff {
                        // Files names the location after the app, and shows its contents only once turned on.
                        Label("Turn it on in the Files app: under Browse, tap \(locationName), then Turn On.",
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Show in Files") { Task { await drive.showInFiles() } }
                    }
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
                    }
                }
            }
            if let error = drive.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Verso Drive")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Turn Off Verso Drive?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                Task { await drive.setOn(false) }
            }
        } message: {
            Text(AccountDrivePage.waitingMessage(waitingFiles))
        }
        .task {
            panes = try? DriveCore.panes()
            await drive.refreshState()
        }
        // Back from Files, where the location may have been turned on.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await drive.refreshState() }
        }
    }

    /// The location's name in Files: the app's.
    private var locationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Verso"
    }

    /// What signing out or switching off costs while files wait in Upload; empty while none do.
    static func waitingMessage(_ files: Int) -> String {
        switch files {
        case 0: ""
        case 1: String(localized: "A file in Verso Drive's Upload folder has not reached Immich yet, and goes with the drive.")
        default: String(localized: "\(files) files in Verso Drive's Upload folder have not reached Immich yet, and go with the drive.")
        }
    }

    private var serverLine: String {
        let host = services.client.serverURL.host() ?? ""
        guard let status = drive.status else { return host }
        return status.online ? String(localized: "Connected to \(host)") : (status.problem ?? String(localized: "\(host) is not reachable"))
    }

    /// Switching on goes at once; switching off asks first while files wait in Upload.
    private func switchTo(_ on: Bool) {
        Task {
            if !on {
                waitingFiles = await drive.filesWaitingInUpload()
                if waitingFiles > 0 {
                    confirmingOff = true
                    return
                }
            }
            await drive.setOn(on)
            panes = try? DriveCore.panes()
        }
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
