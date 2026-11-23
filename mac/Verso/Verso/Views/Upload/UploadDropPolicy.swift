import AppKit
import CoreTransferable
import UniformTypeIdentifiers

enum UploadDropPolicy {
    static func isInternal(_ providers: [NSItemProvider], pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        // AppKit can lowercase custom types on the drag pasteboard.
        let internalTypes = Set([UTType.immichOriginalDrag.identifier.lowercased(), UTType.albumAssetIDs.identifier.lowercased()])
        let types = providers.flatMap(\.registeredTypeIdentifiers) + (pasteboard.types ?? []).map(\.rawValue)
        return types.contains { internalTypes.contains($0.lowercased()) }
    }
}
