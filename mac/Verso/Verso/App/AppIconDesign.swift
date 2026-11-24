import Foundation

/// The app icon's seven designs, by the picture on its print (DESIGN.md, "The picture's designs"), as Linux offers
/// them in Preferences (`app.icon`): Mist, the app icon, first. Each build carries its own drawings of them, the
/// release's or Verso Dev's with the blue corner, named after its app icon (mac/Verso/make-icons.py): AppIcon is Mist,
/// AppIcon-Sand is Sand, and in Verso Dev AppIconDev and AppIconDev-Sand. On the iPhone and the iPad the six others
/// are the app's alternate icons (AccountAppIconPage.swift); on the Mac, the Dock's picture while Verso runs
/// (AppIconChoice.swift).
enum AppIconDesign: String, CaseIterable, Identifiable, Sendable {
    case mist, sand, dark, paper, frame, slate, sky

    var id: String { rawValue }

    /// The design's name, as Linux's Preferences name it.
    var title: String {
        switch self {
        case .mist: String(localized: "Mist")
        case .sand: String(localized: "Sand")
        case .dark: String(localized: "Dark")
        case .paper: String(localized: "Paper")
        case .frame: String(localized: "Frame")
        case .slate: String(localized: "Slate")
        case .sky: String(localized: "Sky")
        }
    }

    /// The build's app icon as its Info.plist names it (ASSETCATALOG_COMPILER_APPICON_NAME, `APP_ICON` in
    /// project.yml): AppIcon, or AppIconDev in Verso Dev. iOS keeps it under CFBundleIcons, the Mac at the top.
    static var buildIconName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        return primary?["CFBundleIconName"] as? String ?? info["CFBundleIconName"] as? String ?? "AppIcon"
    }

    /// The design's icon in a build whose app icon is `buildIcon`: the app icon itself for Mist, else the alternate
    /// with the design's name after it.
    func iconName(in buildIcon: String = AppIconDesign.buildIconName) -> String {
        self == .mist ? buildIcon : "\(buildIcon)-\(rawValue.prefix(1).uppercased())\(rawValue.dropFirst())"
    }

    /// The design an icon's name stands for, Mist for the app icon or a name it does not know.
    init(iconName: String?, in buildIcon: String = AppIconDesign.buildIconName) {
        self = Self.allCases.first { $0.iconName(in: buildIcon) == iconName } ?? .mist
    }
}
