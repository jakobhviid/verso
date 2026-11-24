// Offline presentation check of the import at the sidebar's foot, in a hidden window: every state, light and dark, at
// the sidebar's width, above a stand-in for the account row it lines up with. Writes build/import-design/*.png to look
// at, and fails when a state does not fit the sidebar's width.
import AppKit
import SwiftUI

@main private struct ImportStatusDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let states: [ImportStatus] = [
            ImportStatus(phase: .working, title: "Looking for files…"),
            ImportStatus(phase: .working, title: "Importing 3 of 16", progress: 0.3),
            ImportStatus(phase: .done, title: "Imported 12", detail: "2 already in the library"),
            ImportStatus(phase: .done, title: "Nothing new", detail: "16 already in the library"),
            ImportStatus(phase: .attention, title: "Imported 10", detail: "1 not imported, 1 cancelled", canRetry: true),
            ImportStatus(phase: .attention, title: "Nothing imported", detail: "You can view “Holiday Mix” but not add to it."),
        ]
        let output = URL(fileURLWithPath: "build/import-design", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let width: CGFloat = 240
            let content = VStack(spacing: 0) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, status in
                    Divider()
                    ImportStatusRow(status: status)
                }
                Divider()
                // The account row's layout (AccountMenuLabel in AccountSidebarFooter), to line up with.
                HStack(spacing: 8) {
                    Circle().fill(.gray).frame(width: 28, height: 28).overlay { Text("LA").font(.caption).foregroundStyle(.white) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lab Admin")
                        Text("127.0.0.1").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.width <= width + 1, "The import's states must fit the sidebar's width")
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(dark ? "import-status-dark.png" : "import-status-light.png"))
        }
        print("PASS: the import's states at the sidebar's foot fit its width; build/import-design/ has them, light and dark")
    }
}
