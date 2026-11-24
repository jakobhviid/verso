import CoreGraphics

/// A photo grid's tiles at one zoom level and width, on the Mac and the iPhone alike: how many a row holds, their side,
/// and a row's height with the space after it. The iPhone counts its levels in tiles a row (`GridZoom`), the Mac in the
/// tiles' least side (`GridMetrics.steps`, through `PhotoGridGeometry.columns`); both lay a row out the same way.
struct GridTileMetrics: Equatable {
    let columns: Int
    let side: CGFloat
    let spacing: CGFloat
    var pitch: CGFloat { side + spacing }

    init(columns: Int, width: CGFloat, spacing: CGFloat) {
        self.columns = max(1, columns)
        self.spacing = spacing
        side = max(1, (width - spacing * CGFloat(self.columns - 1)) / CGFloat(self.columns))
    }
}
