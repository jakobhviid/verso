// How Verso names the device it runs on in its words, as Apple's own do ("Back Up This iPad" in Settings): "iPhone"
// on an iPhone, "iPad" on an iPad, so backing up, Free Up Space and the photos on their way never say iPhone on an
// iPad. From the hardware's identifier, not UIDevice, so the backup engine can say it off the main actor too.

import Foundation

enum DeviceWords {
    /// "iPhone" or "iPad".
    nonisolated static let model: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        // The Simulator runs on the Mac's own hardware, and names the device it plays.
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return identifier.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()
}
