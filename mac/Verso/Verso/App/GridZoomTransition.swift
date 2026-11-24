// The arithmetic of a photo grid's pinch between zoom levels, on the iPhone (ios/Verso/Grid/GridPinch.swift) and the
// Mac (PhotoGridPinch) alike, as Photos' grid pinches: the grid stays one grid of squares, which scales with the fingers
// about the photo under them, and each square fades from what it shows at the level shown to what it shows at the
// next. Let go, it finishes the way or goes back from where it is, in one motion of about half a second. Each platform
// draws it with its own views. ARCHITECTURE.md, "Pinching between sizes".

import CoreGraphics
import Foundation

/// A pinch between two zoom levels under way, `progress` of the way: the grid on the screen is one grid of squares,
/// the level shown's and the next's made the same size and laid on each other at the item under the fingers, which
/// scales with the fingers about that item and slides it from its place at the level shown to its place at the next.
/// The cells are the next level's, under a picture of the level shown that fades. Points are on the screen, in the
/// view's frame; the view stays at `fromOffset` meanwhile, and the next level is at `toOffset`.
struct GridZoomTransition {
    let fromLevel: Int
    let toLevel: Int
    let fromPitch: CGFloat
    let toPitch: CGFloat
    let fromOffset: CGFloat
    let toOffset: CGFloat
    /// The middle of the item under the fingers at the level shown and at the next.
    let fromAnchor: CGPoint
    let toAnchor: CGPoint
    var progress: CGFloat

    /// How much larger the next level's squares are, from one to the next.
    var ratio: CGFloat { toPitch / fromPitch }
    /// The level shown's squares' scale, from 1 to `ratio`, as the fingers' is.
    var scale: CGFloat { 1 + progress * (ratio - 1) }
    /// Where the item under the fingers is.
    var anchor: CGPoint {
        CGPoint(x: fromAnchor.x + (toAnchor.x - fromAnchor.x) * progress,
                y: fromAnchor.y + (toAnchor.y - fromAnchor.y) * progress)
    }

    /// Where a rectangle of the next level, at its place on the screen, shows.
    func shown(next rect: CGRect) -> CGRect {
        let scale = scale / ratio
        return CGRect(x: anchor.x + (rect.minX - toAnchor.x) * scale, y: anchor.y + (rect.minY - toAnchor.y) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// The height on the screen at the next level of a height on the screen as it shows.
    func next(height: CGFloat) -> CGFloat {
        toAnchor.y + (height - anchor.y) * ratio / scale
    }

    /// The content's rectangle at the next level that shows in a rectangle of the content as it shows.
    func nextContent(of rect: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        (next(height: rect.minY - fromOffset) + toOffset, next(height: rect.maxY - fromOffset) + toOffset)
    }

    /// Where a rectangle of the content at the next level shows, in the content as it shows.
    func shown(nextContent rect: CGRect) -> CGRect {
        shown(next: rect.offsetBy(dx: 0, dy: -toOffset)).offsetBy(dx: 0, dy: fromOffset)
    }

    /// The picture of the level shown, which is the view's size, scaled and moved so its squares lie on the next's.
    func pictureTransform(size: CGSize) -> CGAffineTransform {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let anchor = anchor
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: anchor.x - middle.x - scale * (fromAnchor.x - middle.x),
                                 ty: anchor.y - middle.y - scale * (fromAnchor.y - middle.y))
    }

    /// The next level as a scroll view magnified to show it where it shows: by how much, and the content's point at the
    /// view's top left (the Mac's, whose scroll view magnifies its content: `NSScrollView.magnification`).
    var nextMagnified: (magnification: CGFloat, origin: CGPoint) {
        let magnification = scale / ratio
        let anchor = anchor
        return (magnification, CGPoint(x: toAnchor.x - anchor.x / magnification, y: toOffset + toAnchor.y - anchor.y / magnification))
    }

    /// The level shown as a magnified scroll view, as `pictureTransform` moves its picture.
    var pictureMagnified: (magnification: CGFloat, origin: CGPoint) {
        let anchor = anchor
        return (scale, CGPoint(x: fromAnchor.x - anchor.x / scale, y: fromOffset + fromAnchor.y - anchor.y / scale))
    }
}

/// Settling once the fingers let go: from where the grid is to the next level (1) or back (0), as fast as the fingers
/// were going, a critically damped spring done in about half a second, as Photos' grid settles.
struct GridZoomSettle {
    /// How quickly it settles.
    static let stiffness: CGFloat = 14
    /// How far beyond the last level the squares give way, as a fraction of a level.
    static let giveBeyond: CGFloat = 0.08

    let from: CGFloat
    let to: CGFloat
    /// In levels a second.
    let velocity: CGFloat
    let start: TimeInterval

    /// Where the fingers let go and how fast they were going (scale a second): whether the grid goes on to the next
    /// level, as a flick goes on, once past half of the way; and the settling from there.
    static func letGo(progress: CGFloat, scaleVelocity: CGFloat, ratio: CGFloat, cancelled: Bool,
                      at time: TimeInterval) -> GridZoomSettle {
        let velocity = min(max(scaleVelocity / (ratio - 1), -8), 8)
        let finishes = !cancelled && progress + velocity * 0.12 > 0.5
        return GridZoomSettle(from: progress, to: finishes ? 1 : 0, velocity: velocity, start: time)
    }

    /// The progress past the next level as the fingers go on beyond the last: a little give, no further.
    static func given(_ progress: CGFloat) -> CGFloat {
        progress > 1 ? 1 + min(giveBeyond, (progress - 1) / 4) : progress
    }

    /// The progress at `time`, and whether the settling is over.
    func progress(at time: TimeInterval) -> (progress: CGFloat, done: Bool) {
        let elapsed = CGFloat(time - start)
        let away = from - to
        let remaining = (away + (velocity + Self.stiffness * away) * elapsed) * exp(-Self.stiffness * elapsed)
        if elapsed > 0.8 || (elapsed > 0.05 && abs(remaining) < 0.002) { return (to, true) }
        return (min(max(to + remaining, 0), max(1, from)), false)
    }
}
