// Offline check of the app icon's choice: every look's icon is where the apps look for it, in the release and in
// Verso Dev (the Mac's PNG set of each of the 28 for the Dock; the iOS app's set of each design and lens, Day and
// Night, and its picture), each name stands for its look again, and both projects compile the others as alternate
// icons. Then the Mac's section in Settings, General, in a hidden window, light and dark, with the defaults and with
// two other looks chosen: it fails when a row does not fit the Settings window's width, and writes
// build/app-icon-design/*.png to look at.
import AppKit
import SwiftUI

@main private struct AppIconChoiceDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let macCatalog = URL(fileURLWithPath: "Verso/Assets.xcassets", isDirectory: true)
        let iosCatalog = URL(fileURLWithPath: "../../ios/Verso/Assets.xcassets", isDirectory: true)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        precondition(AppIconLook.all.count == 28 && Set(AppIconLook.all).count == 28, "seven designs in four looks")
        for build in ["AppIcon", "AppIconDev"] {
            for look in AppIconLook.all {
                let name = look.iconName(in: build)
                precondition(AppIconLook(rawValue: look.rawValue) == look, "\(look.rawValue) must read back")
                precondition(AppIconLook(iconName: name, in: build) == look, "\(name) must stand for \(look.rawValue)")
                precondition(exists(macCatalog.appendingPathComponent("\(name).appiconset")), "the Mac's \(name) is missing")
                // The iPhone's sets are each design and lens, named as the Day look, with the Night look in them.
                if look.paper == .day {
                    precondition(exists(iosCatalog.appendingPathComponent("\(name)Image.imageset")), "\(name)Image is missing")
                    if look != .mist {
                        precondition(exists(iosCatalog.appendingPathComponent("\(name).appiconset")), "iOS's \(name) is missing")
                    }
                }
            }
            precondition(AppIconLook(iconName: nil, in: build) == .mist, "no alternate icon is Mist")
        }
        let macAlternates = AppIconLook.all.filter { $0 != .mist }.map { $0.iconName(in: "$(APP_ICON)") }
        let iosAlternates = AppIconLook.all.filter { $0.paper == .day && $0 != .mist }.map { $0.iconName(in: "$(APP_ICON)") }
        for (project, alternates) in [("project.yml", macAlternates), ("../../ios/project.yml", iosAlternates)] {
            let text = try String(contentsOf: URL(fileURLWithPath: project), encoding: .utf8)
            precondition(text.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: " + alternates.joined(separator: " ")),
                         "\(project) must compile the other \(alternates.count) as alternate icons")
        }

        // The section's pictures from the PNG sets, as the build's catalog has them.
        let picture: (AppIconLook) -> NSImage? = { look in
            NSImage(contentsOf: macCatalog.appendingPathComponent("\(look.iconName(in: "AppIcon")).appiconset/icon_128x128@2x.png"))
        }
        let output = URL(fileURLWithPath: "build/app-icon-design", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The Settings window is 640 wide; the grouped form's row has its margins inside that.
        let width: CGFloat = 640, height: CGFloat = 330
        let choices: [(String, AppIconLook, AppIconLook)] = [
            ("defaults", .mist, .mistNight),
            ("chosen", AppIconLook(design: .sand, lens: .graphite), AppIconLook(design: .sky, paper: .night)),
        ]
        for (name, light, dark) in choices {
            // The registration domain, which is not written anywhere, so the check leaves no defaults behind.
            UserDefaults.standard.register(defaults: [AppIconChoice.lightKey: light.rawValue,
                                                      AppIconChoice.darkKey: dark.rawValue])
            for darkMode in [false, true] {
                let content = Form { AppIconChoiceSection(picture: picture) }
                    .formStyle(.grouped)
                    .frame(width: width, height: height)
                    .environment(\.colorScheme, darkMode ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
                window.contentView = host
                host.setFrameSize(NSSize(width: width, height: height))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = "app-icon-\(name)-\(darkMode ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(file))
            }
        }
        // A row: its title and the seven, with the two controls under them, which must leave the grouped form's
        // margins (about 20 each side, and the row's own 10) free.
        let row = NSHostingView(rootView: LabeledContent("Light Mode") {
            VStack(alignment: .trailing) {
                HStack(alignment: .top, spacing: 4) { ForEach(AppIconDesign.allCases) { Text($0.title).frame(width: 54) } }
                HStack(spacing: 8) {
                    Picker("Paper", selection: .constant(AppIconPaper.day)) {
                        ForEach(AppIconPaper.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Lens", selection: .constant(AppIconLens.colour)) {
                        ForEach(AppIconLens.allCases) { Text($0.title).tag($0) }
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
        }.fixedSize())
        precondition(row.fittingSize.width <= width - 60, "a mode's row must fit the Settings window's row")
        print("PASS: every look's icon is where the Mac and the iPhone look for it, release and Dev, both projects compile the others as alternates, and the Mac's rows fit; build/app-icon-design/ has them, light and dark")
    }
}
