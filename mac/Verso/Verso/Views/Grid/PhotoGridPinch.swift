// The pinch of the Mac's photo grid, as the iPhone's grid pinches (ios/Verso/Grid/GridPinch.swift) and Photos' does:
// the grid stays one grid of squares, which scales with the fingers about the photo under them, and each square fades
// from what it shows at the size shown to what it shows at the next. The two sizes' squares are made the same size and
// laid on each other at the photo under the fingers (GridZoomTransition, which both apps compile). The next size's
// tiles are the grid's own, its scroll view magnified to lie where they show; over them, a picture of the size shown,
// a second collection view of the tiles in view (`PhotoGridPicture`), magnified with them and fading, so the months'
// headers keep their glass on the way. Let go, the grid finishes the way or goes back, from where it is and as fast as
// the fingers were going, in one motion of about half a second (GridZoomSettle), and one pinch goes on through as many
// sizes as the fingers go. ⌘+ and ⌘− make the same motion about the middle of the view. Nothing slides and nothing
// fades in as it loads: the motion is the fingers', or the keys'. ARCHITECTURE.md, "Pinching between sizes".

import AppKit
import QuartzCore

/// What a pinch moves: the grid at the sizes it goes between.
@MainActor protocol PhotoGridZoomStage: AnyObject {
    /// The size the grid shows at rest.
    var shownSize: Double { get }
    /// The size past `size` in the direction of `step` (1 larger tiles, -1 smaller) that shows another count of photos a
    /// row; nil past the last.
    func size(beyond size: Double, step: Int) -> Double?
    func pitch(forSize size: Double) -> CGFloat
    /// The photo at a point of the content, the nearest where the point is between photos, and how far down it the
    /// point is; none on the page's header.
    func anchor(at point: CGPoint) -> (place: PhotoGridGeometry.Place, fraction: CGFloat)?
    func frame(of place: PhotoGridGeometry.Place, forSize size: Double) -> CGRect
    func contentHeight(forSize size: Double) -> CGFloat
    /// The content's height at the view's top, the view's height and the bars over it.
    var offset: CGFloat { get }
    var viewHeight: CGFloat { get }
    var topInset: CGFloat { get }
    /// Sets out toward `size`: the grid at that size, under a picture of the size shown (taken unless kept).
    func setOut(toward size: Double, _ transition: GridZoomTransition, keepingPicture: Bool)
    func show(_ transition: GridZoomTransition)
    /// The grid at the size it was on its way to, at rest.
    func arrive(at size: Double, _ transition: GridZoomTransition)
    /// The grid back at the size shown, at rest.
    func goBack(to size: Double, _ transition: GridZoomTransition)
    /// The pinch is over, and the grid moves as it is told again.
    func zoomEnded()
}

@MainActor final class PhotoGridPinch: NSObject {
    weak var stage: PhotoGridZoomStage?
    /// The view whose display paces the settling.
    weak var view: NSView?

    /// The size a pinch settled on, until the page shows it.
    private(set) var settledSize: Double?
    /// From the fingers' touch to the end of the settling: the grid neither scrolls nor follows its page meanwhile.
    private(set) var isActive = false
    private var transition: GridZoomTransition?
    /// The size the grid is on its way to.
    private var target: Double?
    /// Where the grid rests at the size shown: the content's height at the view's top.
    private var restingOffset: CGFloat?
    private var hasPicture = false
    private var baseScale: CGFloat = 1
    /// The fingers' scale since they touched.
    private var fingersScale: CGFloat = 1
    /// Recent scales, for how fast the fingers were going as they let go.
    private var samples: [(time: TimeInterval, scale: CGFloat)] = []
    /// Where the fingers are, on the view (not its content).
    private var fingers: CGPoint = .zero
    /// The photo under the fingers as the pinch began, and how far down it they were: the same photo through every
    /// size one pinch goes through.
    private var held: (place: PhotoGridGeometry.Place, fraction: CGFloat)?
    /// Set when the grid was laid out anew under a pinch: the fingers are not followed until they lift.
    private var abandoned = false
    private var settle: GridZoomSettle?
    private var displayLink: CADisplayLink?

    /// The page shows `size`: a size the pinch settled on is no longer ahead of it.
    func shows(size: Double) {
        if settledSize == size { settledSize = nil }
    }

    /// The grid has to be laid out anew (its width changed): a pinch under way goes back to the size shown at once, and
    /// the fingers are not followed until they lift.
    func abandon() {
        guard isActive else { return }
        stopSettling()
        if let transition, let stage { stage.goBack(to: stage.shownSize, transition) }
        transition = nil
        target = nil
        held = nil
        hasPicture = false
        abandoned = true
        release()
    }

    /// Zooms to `size` about a point of the view in the motion a pinch lets go in, as ⌘+ and ⌘− do; false where it
    /// would show as many photos a row, or a pinch is under way.
    @discardableResult
    func zoom(to size: Double, about point: CGPoint) -> Bool {
        guard !isActive, settledSize == nil, let stage, size != stage.shownSize,
              abs(stage.pitch(forSize: size) - stage.pitch(forSize: stage.shownSize)) > 0.5 else { return false }
        fingers = point
        held = nil
        isActive = true
        restingOffset = stage.offset
        target = size
        setOut(toward: size)
        startSettling(GridZoomSettle(from: 0, to: 1, velocity: 0, start: CACurrentMediaTime()))
        return true
    }

    // MARK: The fingers

    /// A magnify event at a point of the view.
    func magnify(_ event: NSEvent, at point: CGPoint) {
        guard let stage else { return }
        switch event.phase {
        case .began:
            abandoned = false
            fingers = point
            fingersScale = 1
            samples = []
            if let transition, settle != nil {
                // Caught while settling: the pinch goes on from where the grid is.
                stopSettling()
                baseScale = 1 / transition.scale
            } else {
                target = nil
                held = nil
                baseScale = 1
                restingOffset = stage.offset
            }
            isActive = true
        case .changed:
            guard isActive, !abandoned else { return }
            fingers = point
            fingersScale *= 1 + event.magnification
            samples.append((event.timestamp, fingersScale))
            samples.removeAll { event.timestamp - $0.time > 0.1 }
            follow(scale: fingersScale / baseScale)
        case .ended, .cancelled:
            guard isActive else { return }
            guard !abandoned else {
                abandoned = false
                release()
                return
            }
            letGo(velocity: velocity / baseScale, cancelled: event.phase == .cancelled)
        default:
            break
        }
    }

    /// How fast the fingers' scale was changing, a second, over the last moment.
    private var velocity: CGFloat {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return 0 }
        return (last.scale - first.scale) / CGFloat(last.time - first.time)
    }

    /// The grid `scale` of the way the fingers have gone since they set out toward the next size.
    private func follow(scale: CGFloat) {
        guard let stage, scale.isFinite, scale > 0 else { return }
        // Opening the fingers zooms in: fewer, larger photos.
        let step = scale < 1 ? -1 : 1
        let shown = stage.shownSize
        guard abs(scale - 1) > 0.001, let next = stage.size(beyond: shown, step: step) else {
            if var transition {
                transition.progress = 0
                self.transition = transition
                stage.show(transition)
            }
            return
        }
        if target != next {
            target = next
            setOut(toward: next)
        }
        guard let ratio = transition?.ratio else { return }
        let progress = (scale - 1) / (ratio - 1)
        if progress >= 1, stage.size(beyond: next, step: step) != nil {
            // On past this size: it is the grid's now, and the grid sets out from it toward the one after.
            arrive()
            baseScale *= ratio
            follow(scale: scale / ratio)
            return
        }
        transition?.progress = GridZoomSettle.given(progress)
        if let transition { stage.show(transition) }
    }

    /// The grid sets out from the size shown toward `size`, the next size keeping the photo under the fingers under
    /// them, and a picture of the size shown taken to lie over it, unless one is there already (the fingers turned back
    /// toward the other size).
    private func setOut(toward size: Double) {
        guard let stage else { return }
        let shown = stage.shownSize
        let from = restingOffset ?? stage.offset
        let point = CGPoint(x: fingers.x, y: fingers.y + from)
        var to = from
        var fromAnchor = fingers
        var toAnchor = fingers
        let lowest = -stage.topInset
        let highest = max(lowest, stage.contentHeight(forSize: size) - stage.viewHeight)
        if let anchor = held ?? stage.anchor(at: point) {
            held = anchor
            let here = stage.frame(of: anchor.place, forSize: shown)
            let there = stage.frame(of: anchor.place, forSize: size)
            to = min(max(there.minY + anchor.fraction * there.height - fingers.y, lowest), highest)
            fromAnchor = CGPoint(x: here.midX, y: here.midY - from)
            toAnchor = CGPoint(x: there.midX, y: there.midY - to)
        } else {
            to = min(max(from, lowest), highest)
        }
        let transition = GridZoomTransition(fromLevel: Self.level(shown), toLevel: Self.level(size),
                                            fromPitch: stage.pitch(forSize: shown), toPitch: stage.pitch(forSize: size),
                                            fromOffset: from, toOffset: to, fromAnchor: fromAnchor, toAnchor: toAnchor,
                                            progress: 0)
        self.transition = transition
        stage.setOut(toward: size, transition, keepingPicture: hasPicture)
        hasPicture = true
    }

    /// A size's zoom level: its place among the grid's sizes.
    private static func level(_ size: Double) -> Int {
        GridMetrics.steps.firstIndex { abs($0 - size) < 0.5 } ?? 0
    }

    /// The grid is at the size it was on its way to.
    private func arrive() {
        guard let stage, let transition, let target else { return }
        stage.arrive(at: target, transition)
        hasPicture = false
        restingOffset = transition.toOffset
        self.transition = nil
        self.target = nil
        settledSize = target
    }

    // MARK: Letting go

    private func letGo(velocity scaleVelocity: CGFloat, cancelled: Bool) {
        guard let transition else {
            release()
            return
        }
        startSettling(GridZoomSettle.letGo(progress: transition.progress, scaleVelocity: scaleVelocity, ratio: transition.ratio,
                                           cancelled: cancelled, at: CACurrentMediaTime()))
    }

    private func startSettling(_ settle: GridZoomSettle) {
        self.settle = settle
        guard let view else {
            // No display to pace it: straight to where it goes.
            finishSettling(settle)
            return
        }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let settle, var transition, let stage else {
            stopSettling()
            release()
            return
        }
        let now = settle.progress(at: link.targetTimestamp)
        if now.done {
            finishSettling(settle)
            return
        }
        transition.progress = now.progress
        self.transition = transition
        stage.show(transition)
    }

    private func finishSettling(_ settle: GridZoomSettle) {
        stopSettling()
        if settle.to == 1 { arrive() } else { goBack() }
        release()
    }

    /// The grid back at the size shown, as its picture shows it, and the picture gone.
    private func goBack() {
        if let transition, let stage { stage.goBack(to: stage.shownSize, transition) }
        transition = nil
        target = nil
        hasPicture = false
    }

    private func stopSettling() {
        displayLink?.invalidate()
        displayLink = nil
        settle = nil
    }

    /// The grid follows its page again.
    private func release() {
        isActive = false
        restingOffset = nil
        stage?.zoomEnded()
    }
}

/// The scroll view's clip view, which a pinch moves to any place, past the content's edges too, while it magnifies
/// the grid.
final class PhotoGridClipView: NSClipView {
    var movesFreely = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        movesFreely ? proposedBounds : super.constrainBoundsRect(proposedBounds)
    }
}

/// The picture of the size shown, while a pinch is under way: a collection view of the tiles in view at the size
/// shown, the months' headers and the page's with them, on the page's background, magnified as the grid's squares go
/// and fading. It takes no clicks.
@MainActor final class PhotoGridPicture {
    let scrollView = PhotoGridPictureScrollView()
    private let clipView = PhotoGridClipView()
    let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let layout = PhotoGridLayout()
    private let backdrop = PhotoGridBackdrop()

    init(source: NSCollectionViewDataSource & NSCollectionViewDelegate) {
        clipView.movesFreely = true
        scrollView.contentView = clipView
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = source
        collectionView.delegate = source
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(PhotoGridTileItem.self, forItemWithIdentifier: PhotoGridTileItem.identifier)
        collectionView.register(PhotoGridMonthHeader.self, forSupplementaryViewOfKind: PhotoGridLayout.monthHeaderKind,
                                withIdentifier: PhotoGridMonthHeader.identifier)
        collectionView.register(PhotoGridPageHeader.self, forSupplementaryViewOfKind: PhotoGridLayout.pageHeaderKind,
                                withIdentifier: PhotoGridPageHeader.identifier)
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 20
        scrollView.isHidden = true
        collectionView.addSubview(backdrop)
    }

    /// The grid as it shows at rest: these months at this size and width, the view's top at `offset`.
    func take(_ inputs: PhotoGridGeometry.Inputs, hasPageHeader: Bool, width: CGFloat, topInset: CGFloat, offset: CGFloat,
              viewHeight: CGFloat) {
        layout.fixedWidth = width
        layout.hasPageHeader = hasPageHeader
        layout.inputs = inputs
        layout.topInset = topInset
        layout.frozenTop = offset + topInset
        let rect = CGRect(x: 0, y: offset, width: width, height: viewHeight)
        layout.limit = rect
        layout.invalidateLayout()
        collectionView.setFrameSize(NSSize(width: width, height: max(layout.geometry.contentHeight, offset + viewHeight)))
        backdrop.frame = rect
        collectionView.reloadData()
        scrollView.magnification = 1
        clipView.setBoundsOrigin(CGPoint(x: 0, y: offset))
        scrollView.alphaValue = 1
        scrollView.isHidden = false
        // Its tiles made now, so it shows in the same frame as the grid goes to the next size under it.
        scrollView.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
    }

    func place(_ magnified: (magnification: CGFloat, origin: CGPoint), alpha: CGFloat) {
        scrollView.magnification = magnified.magnification
        clipView.setBoundsOrigin(magnified.origin)
        scrollView.reflectScrolledClipView(clipView)
        scrollView.alphaValue = alpha
    }

    func drop() {
        scrollView.isHidden = true
    }
}

final class PhotoGridPictureScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) {}
}

/// The page's background behind the picture's tiles, so the next size shows only where the picture has shrunk away.
private final class PhotoGridBackdrop: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = -1
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
