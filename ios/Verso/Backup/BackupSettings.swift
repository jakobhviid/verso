// Backing up's settings (SPEC.md, "Backing the iPhone up"), this device's own, in the app's defaults: Back Up
// This iPhone, off until switched on; Use Cellular for Photos and for Videos, each off; Only While Charging, for
// backing up on its own; Screenshots, which go unless switched off; Hidden Photos, into Immich's Locked Folder unless
// switched off; and Free Up Space's: Keep on This iPhone (Forever, the default, until the person chooses a period), and
// Always Keep, what stays whatever its age: the favourites, as Photos has them, the albums on this iPhone the person
// picks, and hidden photos where chosen. The Backup page shows them; the engine reads them as
// one value as each pass starts.

import Foundation

struct BackupSettings: Sendable, Equatable {
    var isOn = false
    var cellularPhotos = false
    var cellularVideos = false
    var onlyWhileCharging = false
    var screenshots = true
    /// Hidden photos go into Immich's Locked Folder.
    var hiddenPhotos = true
    /// Keep on This iPhone, in months; nil keeps everything (Forever).
    var keepMonths: Int?
    var keepFavorites = true
    var keepHidden = false
    /// The phone albums whose photos stay, by their local identifiers.
    var keepAlbums: [String] = []

    enum Key {
        static let isOn = "backup.on"
        static let cellularPhotos = "backup.cellularPhotos"
        static let cellularVideos = "backup.cellularVideos"
        static let onlyWhileCharging = "backup.onlyWhileCharging"
        static let screenshots = "backup.screenshots"
        static let hiddenPhotos = "backup.hiddenPhotos"
        /// The account (its API address and user) backing up was switched on for.
        static let account = "backup.account"
        static let keepMonths = "freeUp.keepMonths"
        static let keepFavorites = "freeUp.keepFavorites"
        static let keepHidden = "freeUp.keepHidden"
        static let keepAlbums = "freeUp.keepAlbums"
        /// The person said yes to what deleting means for iCloud Photos and a Shared Library.
        static let freeUpUnderstood = "freeUp.understood"
    }

    static var current: BackupSettings {
        let defaults = UserDefaults.standard
        return BackupSettings(isOn: defaults.bool(forKey: Key.isOn),
                              cellularPhotos: defaults.bool(forKey: Key.cellularPhotos),
                              cellularVideos: defaults.bool(forKey: Key.cellularVideos),
                              onlyWhileCharging: defaults.bool(forKey: Key.onlyWhileCharging),
                              screenshots: defaults.object(forKey: Key.screenshots) as? Bool ?? true,
                              hiddenPhotos: defaults.object(forKey: Key.hiddenPhotos) as? Bool ?? true,
                              keepMonths: defaults.object(forKey: Key.keepMonths) as? Int,
                              keepFavorites: defaults.object(forKey: Key.keepFavorites) as? Bool ?? true,
                              keepHidden: defaults.bool(forKey: Key.keepHidden),
                              keepAlbums: defaults.stringArray(forKey: Key.keepAlbums) ?? [])
    }

    /// Whether a part of this kind may go over cellular.
    func cellular(video: Bool) -> Bool { video ? cellularVideos : cellularPhotos }
}
