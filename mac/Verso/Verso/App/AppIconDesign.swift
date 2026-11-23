import Foundation

/// The app icon's seven designs, by the picture on its print (DESIGN.md, "The picture's designs"), as Linux offers
/// them in Preferences (`app.icon`): Mist, the app icon, first.
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
}

/// The paper the print is on: Day, white, or Night, charcoal, its picture a darker shade of the design's own.
enum AppIconPaper: String, CaseIterable, Identifiable, Sendable {
    case day, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: String(localized: "Day")
        case .night: String(localized: "Night")
        }
    }
}

/// The lens: its ring in Immich's five colors, or Graphite, the ring in five grays and the glass a neutral gray.
enum AppIconLens: String, CaseIterable, Identifiable, Sendable {
    case colour, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colour: String(localized: "Color")
        case .graphite: String(localized: "Graphite")
        }
    }
}

/// One of the app icon's 28 looks: a design on Day or Night paper, its lens in color or in graphite, named as Linux's
/// `app.icon` names it (`sand`, `sand-night`, `sand-graphite`, `sand-night-graphite`). Each build carries its own
/// drawings of them, the release's or Verso Dev's with the blue corner, named after its app icon
/// (mac/Verso/make-icons.py): AppIcon is Mist on Day paper in color, AppIcon-SandNightGraphite is that look, and in
/// Verso Dev AppIconDev and AppIconDev-SandNightGraphite. On the Mac every look is a picture the Dock can show
/// (AppIconChoice.swift). On the iPhone and the iPad an icon set is a design and its lens, named as its Day look, with
/// the Night look as its dark appearance; all but Mist in color are the app's alternate icons
/// (AccountAppIconPage.swift).
struct AppIconLook: RawRepresentable, Hashable, Identifiable, Sendable {
    var design: AppIconDesign
    var paper: AppIconPaper
    var lens: AppIconLens

    /// The app icon: Mist on Day paper, in color.
    static let mist = AppIconLook(design: .mist, paper: .day, lens: .colour)
    /// Its Night look, the dark appearance of the app icon itself.
    static let mistNight = AppIconLook(design: .mist, paper: .night, lens: .colour)

    /// Every look, design by design.
    static let all: [AppIconLook] = AppIconDesign.allCases.flatMap { design in
        AppIconLens.allCases.flatMap { lens in
            AppIconPaper.allCases.map { paper in AppIconLook(design: design, paper: paper, lens: lens) }
        }
    }

    init(design: AppIconDesign, paper: AppIconPaper = .day, lens: AppIconLens = .colour) {
        self.design = design
        self.paper = paper
        self.lens = lens
    }

    init?(rawValue: String) {
        guard let look = Self.all.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = look
    }

    var rawValue: String {
        design.rawValue + (paper == .night ? "-night" : "") + (lens == .graphite ? "-graphite" : "")
    }

    var id: String { rawValue }

    /// The look's icon in a build whose app icon is `buildIcon`: the app icon itself for Mist on Day paper in color,
    /// else its name's words after it, AppIcon-SandNightGraphite.
    func iconName(in buildIcon: String = AppIconDesign.buildIconName) -> String {
        guard self != .mist else { return buildIcon }
        let words = rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return "\(buildIcon)-\(words.joined())"
    }

    /// The look an icon's name stands for: Mist for the app icon or a name it does not know.
    init(iconName: String?, in buildIcon: String = AppIconDesign.buildIconName) {
        self = Self.all.first { $0.iconName(in: buildIcon) == iconName } ?? .mist
    }

    /// The look in a few words, as a row's value shows it: the design, then what is not the default ("Sand, Night,
    /// Graphite").
    var title: String {
        ([design.title] + (paper == .night ? [paper.title] : []) + (lens == .graphite ? [lens.title] : []))
            .joined(separator: ", ")
    }
}
