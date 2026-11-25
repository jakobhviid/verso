import AppKit
import SwiftUI

/// HDR photos (gain-map HEIC/JPEG/AVIF, HLG or PQ). Immich previews are SDR, so the viewer
/// decodes the original with ImageIO's HDR request and shows it in an EDR-enabled layer.
enum HDRPhotos {
    static let enabledKey = "viewer.showHDR"

    /// Formats ImageIO can decode to HDR. RAW originals are skipped: they're large and
    /// carry no gain map Immich could serve.
    static func mayContainHDR(mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return ["image/heic", "image/heif", "image/jpeg", "image/jpg", "image/avif", "image/jxl", "image/png"].contains(mimeType)
    }

    /// Only Macs with an EDR-capable display (Liquid Retina XDR, Pro Display XDR, HDR
    /// external monitors) download originals for HDR.
    @MainActor static var displaySupportsHDR: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    /// Longest side, in pixels, of the largest screen: enough for the fitted viewer.
    @MainActor static var screenPixelSize: Int {
        let side = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2048
        return min(8192, max(1024, Int(side)))
    }
}

/// Draws an HDR `CGImage` aspect-fit with extended dynamic range. SwiftUI's `Image` tone
/// maps CGImage content to SDR even with `allowedDynamicRange(.high)`, so this uses a layer.
/// It never takes mouse events; the SDR image underneath keeps the viewer's gestures.
struct HDRImageLayer: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        if let layer = view.layer {
            layer.contentsGravity = .resizeAspect
            layer.minificationFilter = .trilinear
            HDRLayers.showHigh(layer)
        }
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.layer?.contents = image
    }

    final class LayerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A layer that shows an HDR photo as bright as the display allows: macOS 26's dynamic range where there is one, the
/// extended range before it.
enum HDRLayers {
    static func showHigh(_ layer: CALayer) {
        if #available(macOS 26, *) {
            preferHigh(layer)
        } else {
            layer.wantsExtendedDynamicRangeContent = true
        }
    }

    /// Never inlined: `.high` is a constant macOS 15 does not have, and once inlined the optimiser read it ahead of
    /// the availability check, at address 0, which crashed opening any photo on macOS 15.
    @available(macOS 26, *) @inline(never)
    private static func preferHigh(_ layer: CALayer) {
        layer.preferredDynamicRange = .high
    }
}
