import Foundation
import VersoCore

// Duplicates: the server sends every group at once, so the app can sort them. Immich's web app keeps the
// server's order; the other orders put the groups worth reviewing first. The shared core sorts them and picks what
// each group keeps at first (`duplicatesOrder`, `duplicatesKeptAtFirst`), as on Linux.

/// The Duplicates page's order, kept in the settings by its code, the same as Linux's.
enum DuplicatesSortBy: String, CaseIterable, Identifiable {
    case server = "Default", itemCount = "ItemCount", totalSize = "TotalSize"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .server: "Default Order"
        case .itemCount: "Most Items"
        case .totalSize: "Largest Size"
        }
    }

    /// The groups in this order: most items or largest first, ties keeping the server's order.
    func sorted(_ groups: [AssetsDuplicate]) -> [AssetsDuplicate] {
        duplicatesOrder(groups: groups.map(DuplicatesGroup.init), sortBy: rawValue).map { groups[Int($0)] }
    }
}

extension AssetsDuplicate {
    /// The photos the group keeps at first: those Immich suggests that are in it, or else its first.
    var keptAtFirst: Set<String> { Set(duplicatesKeptAtFirst(group: DuplicatesGroup(self))) }
}

extension DuplicatesGroup {
    /// What the core reads of a group: its photos with their sizes, and Immich's suggestion.
    init(_ group: AssetsDuplicate) {
        self.init(photos: group.assets.map { DuplicatesPhoto(id: $0.id, size: $0.exifInfo?.fileSizeInByte.map { UInt64(clamping: $0) }) },
                  suggestedKeep: group.suggestedKeepAssetIds ?? [])
    }
}
