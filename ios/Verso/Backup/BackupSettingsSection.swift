// Backing up's row in the account's sheet (SPEC.md, "Backing the iPhone up"): how it stands ("Off", "Checking
// with Immich…", "Up to Date"), opening the Backup page, where everything about backing up happens: switching it on
// and off, Start, and its options.

import SwiftUI

struct BackupSettingsSection: View {
    let services: AccountServices

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        Section {
            NavigationLink {
                BackupPage(services: services)
            } label: {
                LabeledContent("Backup", value: Self.state(center))
            }
            .accessibilityIdentifier("Backup Page")
        } footer: {
            Text("Sends the photos and videos on this \(DeviceWords.model) to your Immich server, each once, and keeps them backed up.")
        }
    }

    private static func state(_ center: BackupCenter) -> String {
        guard center.settings.isOn else { return String(localized: "Off") }
        if let line = BackupLibraryLine.line(center.snapshot) { return line }
        return center.snapshot.phase == .upToDate ? String(localized: "Up to Date") : String(localized: "On")
    }
}
