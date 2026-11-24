// How many notifications wait unread, Verso's own and Immich's, as the Mac's bell and the iPhone's account picture and
// Collections tab's badge show them; whether any are kept at all, read or not, for the ring round the iPhone's account
// picture, until they are cleared; and whether one asks something of the person, which turns the ring and the Mac's
// bell orange. The Mac and the iPhone both compile it, so they count alike.

import Foundation

extension AccountServices {
    var unreadNotificationCount: Int {
        notifications.filter { $0.readAt == nil }.count + versoNotifications.unreadCount
    }

    /// Every notification the account's sheet or the bell's list holds, read or not.
    var notificationCount: Int {
        (notificationsAvailable ? notifications.count : 0) + versoNotifications.items.count
    }

    /// One of them asks something of the person: Verso's that need a look, Immich's warnings and errors.
    var notificationNeedsLook: Bool {
        versoNotifications.items.contains(where: \.needsLook)
            || (notificationsAvailable && notifications.contains { $0.level == "warning" || $0.level == "error" })
    }
}
