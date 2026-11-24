import AppKit
import Sparkle

/// Updates on the Mac (ARCHITECTURE.md, "Verso on the Mac"): Sparkle reads the appcast on
/// Verso's page and replaces the app in place, checking the disk image against Verso's own key (`SUPublicEDKey`).
/// Only the release run from Applications updates itself; Verso Dev never does, so no release replaces it.
@MainActor
enum Updates {
    static var enabled: Bool {
        #if DEBUG
        return false
        #else
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/")
            || path.range(of: "^/Users/[^/]+/Applications/", options: .regularExpression) != nil
        #endif
    }

    static let controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil,
                                                         userDriverDelegate: nil)

    /// Starts the updater at launch, which then checks on Sparkle's schedule once the person has agreed to.
    static func start() { _ = controller }
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
                .disabled(!Updates.enabled)
        }
    }
}
