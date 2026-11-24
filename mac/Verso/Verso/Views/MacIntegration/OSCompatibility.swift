import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// macOS 15 fallbacks for the few macOS 26 APIs the app uses.
// On macOS 26+ every helper calls the original API, so behavior there is unchanged.

extension View {
    /// Liquid Glass on macOS 26+, a regular material on earlier systems.
    @ViewBuilder
    func adaptiveGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Standalone original drag (no container). Both branches keep a stable view
    /// identity when `isEnabled` flips, so zooming doesn't recreate the view.
    @ViewBuilder
    func macOriginalDraggable(_ item: OriginalTransfer, isEnabled: Bool) -> some View {
        if #available(macOS 26, *) {
            draggable(OriginalTransfer.self, item: isEnabled ? item : nil)
        } else {
            // Parent gestures use their own content shape, so they still get events.
            legacyAssetDrag(original: item).allowsHitTesting(isEnabled)
        }
    }
}

extension AssetGridModel {
    var macOrderedSelection: [String] {
        sections.flatMap { $0.assets ?? [] }.filter { selection.contains($0.id) }.map(\.id)
    }

    /// The selection as a drag brings it: in the grid's order, then any selected photo not loaded. Sorted by each
    /// photo's place, so it costs the selection's size, not the library's.
    var macDragSelection: [String] {
        let placed = selection.compactMap { id in order(of: id).map { (id: id, order: $0) } }
            .sorted { ($0.order.section, $0.order.item) < ($1.order.section, $1.order.item) }
        return placed.map(\.id) + selection.filter { order(of: $0) == nil }.sorted()
    }
}

extension View {
    /// The viewer's drag on macOS 15, where a `Transferable` with a file representation is exported as a file promise
    /// only, without the in-app marker: this provider carries the photo's original (for the Finder), downloaded on
    /// demand, and the marker.
    func legacyAssetDrag(original: OriginalTransfer) -> some View {
        onDrag {
            let provider = NSItemProvider()
            // The Finder names the file when the drag starts, before the original is downloaded.
            let file = original.file.resolved
            provider.suggestedName = file.name
            // The original first: the Finder takes the first representation it can save.
            provider.registerFileRepresentation(forTypeIdentifier: file.type.identifier, fileOptions: [], visibility: .all) { completion in
                Task {
                    do { completion(try await original.client.macIntegrationOriginal(original.id), false, nil) }
                    catch { completion(nil, false, error) }
                }
                return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: UTType.immichOriginalDrag.identifier, visibility: .all) { completion in
                completion(try? JSONEncoder().encode(OriginalDragMarker()), nil)
                return nil
            }
            return provider
        }
    }
}

/// Album sidebar rows accept file drops (upload into the album) and asset drops (add to the
/// album). macOS 26 keeps the two original drop modifiers. On macOS 15 only the innermost drop
/// target of a view receives drops, and SwiftUI misses the asset-ID type because AppKit
/// lowercases it on the drag pasteboard; so one handler there reads the IDs from the
/// pasteboard itself and otherwise falls back to the file upload.
struct AlbumRowUploadDrop: ViewModifier {
    let queue: UploadQueue
    let albumID: String
    /// The album's name, when the account may only view it (see `UploadDropModifier`).
    var viewOnly: String?
    let addAssets: ([String]) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.modifier(UploadDropModifier(queue: queue, albumID: albumID, viewOnly: viewOnly))
        } else {
            content
                .onDrop(of: [.data], isTargeted: $targeted) { providers in
                    let ids = Self.draggedAssetIDs()
                    if !ids.isEmpty { return addAssets(ids) }
                    let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                    guard !files.isEmpty else { return false }
                    return UploadDropModifier.enqueue(files, queue: queue, albumID: albumID, viewOnly: viewOnly)
                }
                .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        }
    }

    /// Asset IDs from an in-app grid drag, matched case-insensitively (see above).
    private static func draggedAssetIDs() -> [String] {
        let identifier = UTType.albumAssetIDs.identifier.lowercased()
        return (NSPasteboard(name: .drag).pasteboardItems ?? []).flatMap { item -> [String] in
            guard let type = item.types.first(where: { $0.rawValue.lowercased() == identifier }),
                  let data = item.data(forType: type),
                  let transfer = try? JSONDecoder().decode(AlbumAssetTransfer.self, from: data) else { return [] }
            return transfer.ids
        }
    }
}

/// The original asset drop target, macOS 26+ only (handled by `AlbumRowUploadDrop` earlier).
struct AlbumRowAssetDrop: ViewModifier {
    let addAssets: ([String]) -> Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.dropDestination(for: AlbumAssetTransfer.self) { (values: [AlbumAssetTransfer], _: CGPoint) -> Bool in
                return addAssets(AlbumAssetTransfer.mergedIDs(values))
            }
        } else {
            content
        }
    }
}

import MapKit

extension MKMapItem {
    /// `location` on macOS 26+, the (since deprecated) placemark on earlier systems.
    var adaptiveCoordinate: CLLocationCoordinate2D {
        if #available(macOS 26, *) { location.coordinate } else { placemark.coordinate }
    }
}
