// The app the targets serve, Verso (ARCHITECTURE.md, "Verso on the Mac"): its log's subsystem, and the bridge's log
// started as a target starts.

import Foundation

enum ThisApp {
    /// The unified log's subsystem: `log stream --predicate 'subsystem == "dev.hviid.Verso"'`.
    static let subsystem = "dev.hviid.Verso"

    /// Send the bridge's log to the unified log: first thing as a target starts.
    static func start() {
        startLogging()
    }
}
