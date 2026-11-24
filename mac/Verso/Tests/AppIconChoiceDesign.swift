// Offline check of the app icon's choice: every design's icon is where the apps look for it, in the release and in
// Verso Dev (the Mac's PNG set for the Dock, the iOS app's alternate icon set and its picture), each name stands for its
// design again, and both projects compile the six other designs as alternate icons. Then the Mac's section in
// Settings, General, in a hidden window, light and dark, with Mist and with Sand chosen: it fails when the seven do not
// fit the Settings window's width, and writes build/app-icon-design/*.png to look at.
import AppKit
import SwiftUI

@main private struct AppIconChoiceDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let macCatalog = URL(fileURLWithPath: "Verso/Assets.xcassets", isDirectory: true)
        let iosCatalog = URL(fileURLWithPath: "../../ios/Verso/Assets.xcassets", isDirectory: true)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        for build in ["AppIcon", "AppIconDev"] {
            for design in AppIconDesign.allCases {
                let name = design.iconName(in: build)
                precondition(AppIconDesign(iconName: name, in: build) == design, "\(name) must stand for \(design)")
                precondition(exists(macCatalog.appendingPathComponent("\(name).appiconset")), "the Mac's \(name) is missing")
                precondition(exists(iosCatalog.appendingPathComponent("\(name)Image.imageset")), "\(name)Image is missing")
                if design != .mist {
                    precondition(exists(iosCatalog.appendingPathComponent("\(name).appiconset")), "iOS's \(name) is missing")
                }
            }
            precondition(AppIconDesign(iconName: nil, in: build) == .mist, "no alternate icon is Mist")
        }
        let alternates = AppIconDesign.allCases.filter { $0 != .mist }.map { $0.iconName(in: "$(APP_ICON)") }
        for project in ["project.yml", "../../ios/project.yml"] {
            let text = try String(contentsOf: URL(fileURLWithPath: project), encoding: .utf8)
            precondition(text.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: " + alternates.joined(separator: " ")),
                         "\(project) must compile the six other designs as alternate icons")
        }

        // The section's pictures from the PNG sets, as the build's catalog has them.
        let picture: (AppIconDesign) -> NSImage? = { design in
            NSImage(contentsOf: macCatalog.appendingPathComponent("\(design.iconName(in: "AppIcon")).appiconset/icon_128x128@2x.png"))
        }
        let output = URL(fileURLWithPath: "build/app-icon-design", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The Settings window is 640 wide; the grouped form's row has its margins inside that.
        let width: CGFloat = 640
        for chosen in [AppIconDesign.mist, .sand] {
            // The registration domain, which is not written anywhere, so the check leaves no defaults behind.
            UserDefaults.standard.register(defaults: [AppIconChoice.designKey: chosen.rawValue])
            for dark in [false, true] {
                let content = Form { AppIconChoiceSection(picture: picture) }
                    .formStyle(.grouped)
                    .frame(width: width, height: 170)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 170), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.setFrameSize(NSSize(width: width, height: 170))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "app-icon-\(chosen.rawValue)-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
        // The row: its title and the seven, which must leave the grouped form's margins (about 20 each side, and the
        // row's own 10) free.
        let row = NSHostingView(rootView: LabeledContent("App Icon") {
            HStack(alignment: .top, spacing: 4) { ForEach(AppIconDesign.allCases) { Text($0.title).frame(width: 54) } }
        }.fixedSize())
        precondition(row.fittingSize.width <= width - 60, "the seven designs must fit the Settings window's row")
        print("PASS: every design's icon is where the Mac and the iPhone look for it, release and Dev, both projects compile the six as alternates, and the Mac's row fits; build/app-icon-design/ has it, light and dark")
    }
}
