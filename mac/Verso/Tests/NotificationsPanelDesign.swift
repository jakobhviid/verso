// Offline presentation check of the bell's list, in a hidden window: Verso's own notifications and the server's under
// their headings, light and dark, and the empty list. Writes build/notifications-design/*.png to look at.
import AppKit
import SwiftUI

@main private struct NotificationsPanelDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let now = Date()
        let verso = [
            NotificationEntry(source: .verso, key: "1", symbol: "exclamationmark.triangle.fill", tint: .orange,
                              title: "Imported 10", detail: "1 not imported, 1 cancelled", date: now.addingTimeInterval(-90), unread: true,
                              lines: [.init(name: "IMG_2041.HEIC", reason: "Immich does not take this file"), .init(name: "IMG_2042.HEIC", reason: "Cancelled")]),
            NotificationEntry(source: .verso, key: "2", symbol: "checkmark.circle.fill", tint: .green,
                              title: "Imported 16", detail: nil, date: now.addingTimeInterval(-3600), unread: false),
            NotificationEntry(source: .verso, key: "3", symbol: "checkmark.circle.fill", tint: .green,
                              title: "Nothing new", detail: "16 already in the library", date: now.addingTimeInterval(-7200), unread: false),
        ]
        let immich = [
            NotificationEntry(source: .immich, key: "a", symbol: "info.circle.fill", tint: .accentColor,
                              title: "Sam shared “Holiday Mix” with you", detail: "You can now see the album and add to it.", date: now.addingTimeInterval(-86400), unread: true),
            NotificationEntry(source: .immich, key: "b", symbol: "xmark.octagon.fill", tint: .red,
                              title: "Thumbnail job failed", detail: "3 files could not be read.", date: now.addingTimeInterval(-3 * 86400), unread: false),
        ]
        let output = URL(fileURLWithPath: "build/notifications-design", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for (name, panel) in [("panel", NotificationsPanel(verso: verso, immich: immich, server: "photos.example.org")),
                                  ("empty", NotificationsPanel(verso: [], immich: [], server: "photos.example.org"))] {
                let content = panel
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        print("PASS: the bell's list rendered, light and dark, with both sources and empty; build/notifications-design/ has them")
    }
}
