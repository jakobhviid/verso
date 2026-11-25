import AppKit
import SwiftUI

/// Verso's menu bar item, as its top bar icon on Linux (ARCHITECTURE.md, "Verso on the Mac"): the state at a glance,
/// and Verso, Verso Drive, Settings and Quit in its menu. The icon is the app icon's lens, as Finder's sidebar and
/// Messages show Verso, the same in the Dev build: in one colour, as menu bar icons are, or in its five colours where
/// Settings says so, as Linux offers its top bar icon (`tray.colour`).
struct VersoMenuBar: Scene {
    /// The menu bar icon in colour (Settings, General); off, in the menu bar's own black or white.
    static let colourKey = "menuBar.inColour"
    let app: AppModel

    var body: some Scene {
        MenuBarExtra {
            VersoMenu(app: app)
        } label: {
            VersoMenuBarIcon(app: app)
        }
    }
}

/// The Linux tray's states: signed out, the server out of reach, Verso Drive waiting to be switched on in Finder. In
/// one colour a template image, which macOS draws in the menu bar's own black or white; in colour, drawn as it is.
private struct VersoMenuBarIcon: View {
    let app: AppModel
    @AppStorage(VersoMenuBar.colourKey) private var inColour = false

    var body: some View {
        if inColour {
            Image(nsImage: NSImage(named: name + "Colour") ?? NSImage())
        } else {
            Image(name)
        }
    }

    private var name: String {
        let drive = VersoDrive.shared
        if case .signedOut = app.phase { return "MenuBarIconSignedOut" }
        if drive.isOn, drive.status?.online == false { return "MenuBarIconOffline" }
        if drive.isOn, drive.locationSwitchedOff { return "MenuBarIconUnmounted" }
        return "MenuBarIcon"
    }
}

private struct VersoMenu: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let drive = VersoDrive.shared
        Text(statusLine)
        Button("Open Verso") { openVerso() }
        Divider()
        if app.services != nil {
            if drive.isOn {
                Button("Show Verso Drive in Finder") { Task { await drive.showInFinder() } }
                Button("Turn Off Verso Drive") { Task { await drive.setOn(false) } }
            } else {
                Button("Turn On Verso Drive") { Task { await drive.setOn(true) } }
            }
            Divider()
        }
        SettingsLink { Text("Settings…") }
        Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
            .disabled(!Updates.enabled)
        Divider()
        Button("Quit Verso") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let services = app.services else { return String(localized: "Signed out") }
        let host = services.client.serverURL.host() ?? services.client.serverURL.absoluteString
        guard VersoDrive.shared.isOn, let status = VersoDrive.shared.status else { return String(localized: "Signed in to \(host)") }
        return status.online ? String(localized: "Connected to \(host)") : String(localized: "\(host) is not reachable")
    }

    /// The library window in front, or a new one when none is open.
    private func openVerso() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
