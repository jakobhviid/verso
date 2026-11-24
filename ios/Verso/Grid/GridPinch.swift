// The pinch of the iOS grids, the photo grid's and the card pages', as Photos' grid pinches: the grid stays one grid of
// squares, which scales with the fingers about the photo or card under them, as if it went on without end, and each
// square fades from what it shows at the zoom level shown to what it shows at the next. The two levels' squares are
// made the same size and laid on each other at the item under the fingers, which is the same item at both; the next
// level's cells are the grid's own, under a picture of the level shown that scales with them and fades, so where the
// picture has shrunk from the edges the next level's items already fill the squares. Let go, the grid finishes the way
// or goes back, from where it is, in one motion, and one pinch goes on through as many levels as the fingers go; View
// Options' Zoom Out and Zoom In make the same motion about the middle of the view. The cells are not drawn again on the
// way: a layout keeps each the size its view was drawn at and scales it (TimelineCollectionLayout's `drawnSide`). The
// way between two levels and the settling are worked out in GridZoomTransition.swift, which the Mac's pinch shares.
// ARCHITECTURE.md, "Pinching between sizes".

import SwiftUI
import UIKit

/// A grid's layout as its pinch sees it: zoom levels by number, the items' places at each, and the way between two.
@MainActor protocol PinchZoomLayout: UICollectionViewLayout {
    /// The level the grid is at.
    var level: Int { get }
    var transition: GridZoomTransition? { get set }
    /// How far apart the squares are across at a level, from one to the next; nil past the last level either way.
    func pitch(atLevel level: Int) -> CGFloat?
    /// The item at a point of the content, the nearest where the point is between items, and how far down it the
    /// point is (0 its top, 1 its foot); none where nothing is to keep under the fingers (a header).
    func anchor(at point: CGPoint) -> (item: IndexPath, fraction: CGFloat)?
    /// Where an item is at a level, in the content.
    func frame(of item: IndexPath, atLevel level: Int) -> CGRect
    func contentHeight(atLevel level: Int) -> CGFloat
    /// The grid is at the level a pinch went to.
    func zoomed(toLevel level: Int)
    /// The height of the content at the top of the view at rest: 0, or below a search hidden above it (CardGrid).
    var restingTop: CGFloat { get }
}

extension PinchZoomLayout {
    var restingTop: CGFloat { 0 }
}

/// What a pinch tells the page its grid is on.
struct GridZoomActions {
    /// A pinch has begun: the grid stops landing at its end.
    var began: () -> Void = {}
    /// A pinch has settled on another level.
    var changed: (Int) -> Void
}

@MainActor final class GridPinch: NSObject, UIGestureRecognizerDelegate {
    weak var view: UICollectionView?
    var actions: GridZoomActions?
    /// Whether the grid scrolls when no pinch holds it.
    var scrollEnabled = true

    /// The level a pinch settled on, until the page shows it.
    private(set) var settledLevel: Int?
    /// From the fingers' touch to the end of the settling: the grid does not scroll meanwhile.
    private(set) var isActive = false
    /// The level the cells are on their way to, and the pinch's scale when they set out.
    private var target: Int?
    private var baseScale: CGFloat = 1
    /// Where the fingers are, in the view's frame (not its content).
    private var fingers: CGPoint = .zero
    /// The item under the fingers as the pinch began, and how far down it they were: the same item through every
    /// level one pinch goes through.
    private var held: (item: IndexPath, fraction: CGFloat)?
    /// Set when the grid was laid out anew under a pinch: it is ignored until it ends.
    private var abandoned = false
    /// The settling once let go (GridZoomSettle, the Mac's too).
    private var settle: GridZoomSettle?
    private var displayLink: CADisplayLink?
    /// The picture of the level shown, over the next level's cells, while they are on their way.
    private var picture: UIView?

    /// One pinch goes on through the levels past the next, as far as the fingers go.
    private static let goesThroughLevels = true

    private var layout: PinchZoomLayout? { view?.collectionViewLayout as? PinchZoomLayout }

    func attach(to view: UICollectionView) {
        self.view = view
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    /// The page shows `level`: a level the pinch settled on is no longer ahead of it.
    func shows(level: Int) {
        if settledLevel == level { settledLevel = nil }
    }

    /// The grid was laid out anew (its items or its width changed): a pinch under way lets go of it, and the fingers
    /// are not followed until they lift. A level it settled on stays the grid's.
    func abandon() {
        guard isActive else { return }
        stopSettling()
        layout?.transition = nil
        target = nil
        held = nil
        dropPicture()
        abandoned = true
        release()
    }

    /// Zooms one level in (`step` -1, larger items) or out (1) about a point of the view's frame, in the motion a pinch
    /// lets go in, as View Options' Zoom In and Zoom Out do; false where there is no such level or a pinch is under way.
    @discardableResult
    func zoom(by step: Int, about point: CGPoint) -> Bool {
        guard !isActive, let layout, settledLevel == nil, layout.pitch(atLevel: layout.level + step) != nil else {
            return false
        }
        fingers = point
        held = nil
        isActive = true
        view?.isScrollEnabled = false
        target = layout.level + step
        setOut(toward: layout.level + step)
        startSettling(from: 0, to: 1, velocity: 0)
        return true
    }

    // MARK: The fingers

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let view, let layout else { return }
        switch recognizer.state {
        case .began:
            abandoned = false
            fingers = screenPoint(recognizer.location(in: view))
            if let transition = layout.transition, settle != nil {
                // Caught while settling: the pinch goes on from where the cells are.
                stopSettling()
                baseScale = 1 / transition.scale
            } else {
                target = nil
                held = nil
                baseScale = 1
                actions?.began()
            }
            isActive = true
            view.isScrollEnabled = false
        case .changed:
            guard !abandoned else { return }
            fingers = screenPoint(recognizer.location(in: view))
            follow(scale: recognizer.scale / baseScale)
        case .ended, .cancelled, .failed:
            guard !abandoned else {
                abandoned = false
                release()
                return
            }
            letGo(velocity: recognizer.velocity / baseScale, cancelled: recognizer.state != .ended)
        default:
            break
        }
    }

    /// A point of the view's content, in the view's frame.
    private func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y - (view?.contentOffset.y ?? 0))
    }

    /// The cells `scale` of the way the fingers have gone since they set out toward the next level.
    private func follow(scale: CGFloat) {
        guard let layout, scale.isFinite, scale > 0 else { return }
        // Closing the fingers zooms out: more, smaller items.
        let step = scale < 1 ? 1 : -1
        let next = layout.level + step
        guard abs(scale - 1) > 0.001, let fromPitch = layout.pitch(atLevel: layout.level),
              let toPitch = layout.pitch(atLevel: next), abs(toPitch - fromPitch) > 0.5 else {
            if layout.transition != nil { layout.transition?.progress = 0 }
            showPicture()
            return
        }
        if target != next {
            target = next
            setOut(toward: next)
        }
        guard let ratio = layout.transition?.ratio else { return }
        let progress = (scale - 1) / (ratio - 1)
        if progress >= 1, Self.goesThroughLevels, layout.pitch(atLevel: next + step) != nil {
            // On past this level: it is the grid's now, and the cells set out from it toward the one after.
            arrive()
            baseScale *= ratio
            follow(scale: scale / ratio)
            return
        }
        layout.transition?.progress = GridZoomSettle.given(progress)
        showPicture()
    }

    /// The grid sets out from the level shown toward `level`, the next level keeping the item under the fingers under
    /// them, and a picture of the level shown taken to lie over it, unless one is there already (the fingers turned
    /// back toward the other level).
    private func setOut(toward level: Int) {
        guard let view, let layout, let fromPitch = layout.pitch(atLevel: layout.level),
              let toPitch = layout.pitch(atLevel: level) else { return }
        takePicture()
        let from = view.contentOffset.y
        let point = CGPoint(x: fingers.x, y: fingers.y + from)
        var to = from
        var fromAnchor = fingers
        var toAnchor = fingers
        let insets = view.adjustedContentInset
        // As high as the top at rest, or as the view is, where it shows more (a search pulled into view).
        let lowest = max(-insets.top, min(from, layout.restingTop - insets.top))
        let highest = max(lowest, layout.contentHeight(atLevel: level) + insets.bottom - view.bounds.height)
        if let anchor = held ?? layout.anchor(at: point) {
            held = anchor
            let here = layout.frame(of: anchor.item, atLevel: layout.level)
            let there = layout.frame(of: anchor.item, atLevel: level)
            to = min(max(there.minY + anchor.fraction * there.height - fingers.y, lowest), highest)
            fromAnchor = CGPoint(x: here.midX, y: here.midY - from)
            toAnchor = CGPoint(x: there.midX, y: there.midY - to)
        } else {
            to = min(max(from, lowest), highest)
        }
        layout.transition = GridZoomTransition(fromLevel: layout.level, toLevel: level, fromPitch: fromPitch,
                                               toPitch: toPitch, fromOffset: from, toOffset: to,
                                               fromAnchor: fromAnchor, toAnchor: toAnchor, progress: 0)
        showPicture()
    }

    /// A picture of the grid as it shows, its cells on the page's background: the level shown, which lies over the
    /// next level's cells while they are on their way.
    private func takePicture() {
        guard picture == nil, let view else { return }
        let frame = CGRect(x: 0, y: view.contentOffset.y, width: view.bounds.width, height: view.bounds.height)
        let picture = UIView(frame: frame)
        picture.backgroundColor = .systemBackground
        picture.isUserInteractionEnabled = false
        // Over the cells, which a pinch puts deeper (`GridPinch.cellDepth`), and under the views of the scroll edge
        // effect, which blur what is under the bars.
        picture.layer.zPosition = -0.5
        for cell in view.visibleCells {
            guard let snapshot = cell.snapshotView(afterScreenUpdates: false) else { continue }
            snapshot.bounds = cell.bounds
            snapshot.center = CGPoint(x: cell.center.x, y: cell.center.y - frame.minY)
            snapshot.transform = cell.transform
            picture.addSubview(snapshot)
        }
        view.addSubview(picture)
        self.picture = picture
    }

    /// How deep a layout puts its items while a pinch is under way, and its headers: under the picture of the level
    /// shown, the headers over the items, all of them under the views of the scroll edge effect.
    static let cellDepth = -2
    static let headerDepth = -1

    /// The picture scaled and moved with the grid, and as faded as the cells are far on their way.
    private func showPicture() {
        guard let picture else { return }
        guard let transition = layout?.transition else {
            picture.transform = .identity
            picture.alpha = 1
            return
        }
        picture.transform = transition.pictureTransform(size: picture.bounds.size)
        picture.alpha = 1 - min(max(transition.progress, 0), 1)
    }

    private func dropPicture() {
        picture?.removeFromSuperview()
        picture = nil
    }

    /// The cells are at their places at the level they were on their way to: the grid is at that level.
    private func arrive() {
        guard let view, let layout, let transition = layout.transition, let target else { return }
        dropPicture()
        layout.zoomed(toLevel: transition.toLevel)
        view.contentOffset.y = transition.toOffset
        view.layoutIfNeeded()
        self.target = nil
        settledLevel = target
        actions?.changed(target)
    }

    // MARK: Letting go

    private func letGo(velocity scaleVelocity: CGFloat, cancelled: Bool) {
        guard let layout, let transition = layout.transition else {
            dropPicture()
            release()
            return
        }
        // On where the fingers were going, as a flick goes on: the cells finish the way once past half of it.
        startSettling(GridZoomSettle.letGo(progress: transition.progress, scaleVelocity: scaleVelocity, ratio: transition.ratio,
                                           cancelled: cancelled, at: CACurrentMediaTime()))
    }

    private func startSettling(from: CGFloat, to: CGFloat, velocity: CGFloat) {
        startSettling(GridZoomSettle(from: from, to: to, velocity: velocity, start: CACurrentMediaTime()))
    }

    private func startSettling(_ settle: GridZoomSettle) {
        self.settle = settle
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let settle, let layout, layout.transition != nil else {
            stopSettling()
            dropPicture()
            release()
            return
        }
        let now = settle.progress(at: link.targetTimestamp)
        if now.done {
            stopSettling()
            if settle.to == 1 { arrive() } else { goBack() }
            release()
            return
        }
        layout.transition?.progress = now.progress
        showPicture()
    }

    /// The grid back at the level shown, as its picture shows it, and the picture gone.
    private func goBack() {
        layout?.transition = nil
        target = nil
        view?.layoutIfNeeded()
        dropPicture()
    }

    private func stopSettling() {
        displayLink?.invalidate()
        displayLink = nil
        settle = nil
    }

    /// The grid scrolls again.
    private func release() {
        isActive = false
        view?.isScrollEnabled = scrollEnabled
    }

    // MARK: Alongside the scrolling

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === view?.panGestureRecognizer
    }
}
