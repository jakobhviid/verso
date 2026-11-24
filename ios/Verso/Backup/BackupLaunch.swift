// Backing up as Verso launches on iOS: the background tasks registered before launching ends, the engine made so the
// background session's answers find it, and the system's wake-ups for that session handed to it (BackupTransport),
// whose completion is called once every answer is recorded and the uploads are topped up (BackupScheduler.sessionWoke).
// It is also the notifications' delegate: backing up's open the Backup page (Free Up Space's reminder, its review), and
// Ready to back up's Start Backup starts the first run there. The app's delegate is iOS's own; the engine knows nothing of it.

import UIKit
import UserNotifications

final class VersoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackupScheduler.register()
        BackupCenter.shared.launch()
        UNUserNotificationCenter.current().delegate = self
        BackupNotifications.registerCategories()
        return true
    }

    /// A tap on one of backing up's notifications, or its action: the Backup page, with the first run started for
    /// Start Backup, or Free Up Space's review for its reminder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        if BackupNotifications.isBackup(identifier) {
            Task { @MainActor in
                if action == BackupNotifications.startAction { BackupCenter.shared.startFirstRun() }
                if identifier == BackupNotifications.freeUpIdentifier { BackupCenter.shared.showFreeUp() }
                else { BackupCenter.shared.showPage() }
            }
        }
        completionHandler()
    }

    /// In the foreground the account's notifications hold them, and the Library's line says what matters: no banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let center = BackupCenter.shared
        center.launch()
        guard let transport = center.transport, identifier == BackupTransport.identifier(bundle: Bundle.main.bundleIdentifier ?? "") else {
            completionHandler()
            return
        }
        transport.handleEvents(completion: completionHandler)
        Task { await center.accountForBackground() }
    }
}
