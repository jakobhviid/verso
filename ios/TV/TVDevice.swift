import Foundation

/// Which Apple TV this is, as far as the TV's interface needs to know: an older box (the Apple TV 4K of the 1st and 2nd
/// generation, A10X and A12 with 3 GB, and the Apple TV HD) gets the simpler interface, which leaves out what costs it
/// most: the viewer's zoom and slide, the focused tile's lift and shadow (its outline stays), and most of the picture
/// cache. A model Verso does not know counts as new unless it has less than 4 GB, so a later box is never held back.
enum TVDevice {
    /// The older boxes, by model: the Apple TV HD, the Apple TV 4K (1st generation) and (2nd generation).
    private static let older: Set<String> = ["AppleTV5,3", "AppleTV6,2", "AppleTV11,1"]

    /// The simpler interface. A development build takes `-tvSimpler YES` or `NO` to look at either.
    static let simpler: Bool = {
        #if DEBUG
        if let said = UserDefaults.standard.object(forKey: "tvSimpler") as? Bool { return said }
        #endif
        if older.contains(model) { return true }
        if model.hasPrefix("AppleTV") { return false }
        return ProcessInfo.processInfo.physicalMemory < 3_500_000_000
    }()

    /// The model's identifier (`AppleTV11,1`); the Simulator's says which TV it plays.
    static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// How much of the decoded pictures to keep in memory, and how many to load at once.
    static var pictureCache: Int { simpler ? 160 << 20 : 512 << 20 }
    static var picturesAtOnce: Int { simpler ? 3 : 6 }
}
