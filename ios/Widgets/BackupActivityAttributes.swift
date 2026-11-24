// What backing up's Live Activity shows (ARCHITECTURE.md, "Backing the iPhone up"), shared by the app, which starts and
// updates it (BackupLiveActivity), and the widget extension, which draws it on the Lock Screen and in the Dynamic
// Island (VersoWidgets). The app writes its words, in the person's language; the extension only lays them out.

import ActivityKit
import Foundation

struct BackupActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Stage: String, Codable, Hashable {
            /// The first run's check.
            case checking
            /// Uploads on their way.
            case backingUp
            /// Waiting for Wi-Fi, a connection, Immich or free space, which Verso goes on from by itself.
            case waiting
            /// The run ended: backed up, ready for Start, or with photos that need a look.
            case done
            /// Something only the person can put right, said on the Backup page.
            case stopped
        }

        var stage: Stage
        /// "Checking with Immich", "Backing up to Immich", "Backed up 69 items".
        var title: String
        /// "1,205 of 3,523 checked", "34 to go · 210 MB", "Waiting for Wi-Fi".
        var detail: String
        /// How far, for the bar and the ring: done of total.
        var done: Int
        var total: Int

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }
}
