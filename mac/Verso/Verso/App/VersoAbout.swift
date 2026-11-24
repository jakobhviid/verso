import AppKit
import SwiftUI

/// About Verso: the standard About panel with what Verso is, the credits and the AI disclosure. The non-affiliation
/// notice is its copyright line (Info.plist), which the panel always shows.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Verso") { showAbout() }
        }
    }
}

@MainActor
private func showAbout() {
    let credits = NSMutableAttributedString()
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                               .foregroundColor: NSColor.labelColor]
    let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                                                  .foregroundColor: NSColor.labelColor]
    func add(_ text: String, _ attributes: [NSAttributedString.Key: Any], link: String? = nil) {
        var attributes = attributes
        if let link { attributes[.link] = URL(string: link) }
        credits.append(NSAttributedString(string: text, attributes: attributes))
    }
    add(String(localized: "Your Immich photos and videos, on your Mac. By Jakob Hviid, under the MIT license.") + "\n\n", body)
    add(String(localized: "Built from Immich Gallery") + "\n", heading)
    add(String(localized: "Immich Gallery for the Mac, by Alessandro Craciun, with contributions by Jakob Hviid"), body,
        link: "https://github.com/IGOLz/ImmichGallery")
    add("\n\n" + String(localized: "The drive and the Immich API layer") + "\n", heading)
    add("Immich Mount", body, link: "https://jakob.hviid.phd/immich-mount/")
    add(String(localized: ", whose API layer started from "), body)
    add("immich-rs", body, link: "https://github.com/boul2gom/immich-rs")
    add("\n\n" + String(localized: "AI disclosure") + "\n", heading)
    add(String(localized: "Parts of this project were written with the assistance of AI coding agents. All changes are reviewed by the maintainer."), body)
    NSApplication.shared.activate()
    NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
}
