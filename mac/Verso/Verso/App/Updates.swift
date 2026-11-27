import AppKit
import Sparkle
import SwiftUI

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

    static let controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: channel,
                                                         userDriverDelegate: nil)
    /// Kept here: the controller holds its delegate weakly.
    private static let channel = UpdateChannel()

    /// Starts the updater at launch, which then checks on Sparkle's schedule once the person has agreed to.
    static func start() { _ = controller }
}

/// The channel a build updates on (AGENTS.md, "Versioning"; PRINCIPLES.md, 15): a beta's build, from `develop`, takes the
/// feed's beta items as well as its releases; a release's takes releases alone, Sparkle's default channel.
final class UpdateChannel: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Bundle.main.object(forInfoDictionaryKey: "VersoUpdateChannel") as? String == "beta" ? ["beta"] : []
    }
}

/// ⌘Q closes Verso's windows and leaves the menu bar icon running, Verso Drive's account with it, as Immich Mount's app
/// does; Quit Verso in the icon's menu quits it all. The system's own quits (logging out, an update) still quit.
struct QuitCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Verso Gallery") {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) { window.close() }
                // No window left: the Dock icon goes too, until a window opens again (MacIntegrationLifecycle).
                NSApp.setActivationPolicy(.accessory)
            }
            .keyboardShortcut("q")
        }
    }
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
                .disabled(!Updates.enabled)
        }
    }
}
