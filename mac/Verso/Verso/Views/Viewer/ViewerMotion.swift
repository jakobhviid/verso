import AppKit
import SwiftUI

/// The grid squares' places on the page, for the open photo to fly out of and back into. Not observed: only the motion
/// reads them. The grid works a square's place out when asked (`locate`).
final class ViewerCellFrames {
    static let space = "viewerMotion"
    var locate: ((String) -> CGRect?)?

    func frame(of id: String) -> CGRect? {
        locate?(id)
    }
}

/// The open photo's zoom out of its grid square into the viewer and back, as Photos has it. It runs once, from its
/// start to `done`. Sliding to the next photo is `ViewerSlider`'s.
struct ViewerMotion: Equatable {
    enum Kind: Equatable {
        /// The photo flies from `from` to `to`, opening (out of its square) or closing (back into it). Closing, the grid
        /// starts dimmed by `dim`: less after a pinch has let it show through.
        case flight(from: CGRect, to: CGRect, opening: Bool, dim: Double)
    }

    let id: String
    let kind: Kind
    let generation: Int
    var done = false

    var isFlight: Bool { true }
}

/// Sliding from one photo to the next, as in Photos, in Core Animation: pictures of the two photos move on layers of
/// one AppKit view that stays for as long as a photo is open, while SwiftUI swaps the photo underneath without
/// animating. Nothing is laid out while they move. Sliding SwiftUI views instead, while the photo underneath was
/// replaced, made AppKit's layout loop (an endless Update Constraints pass) and throw. A trackpad swipe moves the same
/// layers with the fingers, then finishes the step or springs back. A Live Photo's motion (`LivePhotoMotion.slideLayer`)
/// lies over its picture, so one that moves as the step brings it, or as it leaves, moves as it slides.
@MainActor final class ViewerSlider {
    fileprivate weak var view: ViewerSlideLayerView?
    /// A swipe has finished its step on the layers: the photo it swaps to doesn't slide again.
    private var swipedTo: String?
    /// How far across the photo a swipe brings in is when its Live Photo starts moving, as on the iPhone (60% to 71%
    /// in Photos).
    static let glimpseAcross: CGFloat = 0.65

    /// The next photo comes in from the side of `direction` (1: the right) as `outgoing` leaves the other way, each with
    /// its Live Photo's motion over it, if it has one.
    func slide(from outgoing: CGImage, outgoingMotion: CALayer?, to incoming: CGImage, incomingMotion: CALayer?,
               direction: Int, toID: String) {
        if swipedTo == toID { swipedTo = nil; return }
        view?.slide(from: outgoing, outgoingMotion: outgoingMotion, to: incoming, incomingMotion: incomingMotion,
                    direction: direction)
    }

    /// The photos follow a swipe `width` across: the open one, and its neighbour on the side it uncovers. Returns how far
    /// across that neighbour has come, from 0 to 1 (0 while none shows).
    func drag(_ width: CGFloat, current: CGImage, currentMotion: CALayer?, previous: ViewerSlideNeighbour,
              next: ViewerSlideNeighbour) -> CGFloat {
        view?.drag(width, current: current, currentMotion: currentMotion, previous: previous, next: next) ?? 0
    }

    /// The swipe ended: the step to `toID` in `direction`, sliding the rest of the way, or at once when the photo
    /// coming in had no picture to show; or back to the photo.
    func endDrag(direction: Int?, toID: String?) {
        swipedTo = direction == nil ? nil : toID
        view?.endDrag(direction: direction)
    }
}

/// A swipe's neighbour on one side: its picture, to slide in, with its Live Photo's motion over it if it has one; a
/// photo whose picture isn't ready, or that isn't known yet, which the photos move toward without showing it; or none,
/// past the first or last photo.
enum ViewerSlideNeighbour {
    case picture(CGImage, motion: CALayer?)
    case pending
    case end
}

/// `ViewerSlider`'s view: hidden, and passing clicks through, but while photos slide.
struct ViewerSlideLayer: NSViewRepresentable {
    let slider: ViewerSlider

    func makeNSView(context: Context) -> ViewerSlideLayerView {
        let view = ViewerSlideLayerView()
        slider.view = view
        return view
    }

    func updateNSView(_ view: ViewerSlideLayerView, context: Context) { slider.view = view }
}

final class ViewerSlideLayerView: NSView {
    private let backdrop = CALayer()
    /// The photo leaving, or the open one under a swipe.
    private let currentLayer = CALayer()
    /// The photo coming in.
    private let incomingLayer = CALayer()
    private var generation = 0
    private var dragging = false
    /// The side the swipe's neighbour comes from: 1 the right (the next photo), -1 the left.
    private var dragSide = 0
    /// The gap between two photos as they slide, as in Photos.
    private static let gap: CGFloat = 40
    private static let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1)
    /// A step by the keys or the arrows, and the rest of a swipe once the fingers lift.
    private static let slideDuration: CFTimeInterval = 0.36
    private static let swipeDuration: CFTimeInterval = 0.3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for photo in [currentLayer, incomingLayer] {
            photo.contentsGravity = .resizeAspect
            photo.minificationFilter = .trilinear
            // As `HDRImageLayer`: an HDR photo slides as bright as the viewer shows it.
            HDRLayers.showHigh(photo)
        }
        layer?.addSublayer(backdrop)
        layer?.addSublayer(currentLayer)
        layer?.addSublayer(incomingLayer)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var middle: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    /// How far one photo is from the next as they slide: the window's width and the gap, as in Photos, so a photo
    /// leaving under the see-through sidebar goes on until it's past the window's edge.
    private var span: CGFloat { max(bounds.width, window?.contentView?.bounds.width ?? 0) + Self.gap }

    func slide(from outgoing: CGImage, outgoingMotion: CALayer?, to incoming: CGImage, incomingMotion: CALayer?,
               direction: Int) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        dragging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        show(current: outgoing)
        finish()
        incomingLayer.contents = incoming
        incomingLayer.isHidden = false
        overlay(outgoingMotion, on: currentLayer, picture: outgoing)
        overlay(incomingMotion, on: incomingLayer, picture: incoming)
        let distance = span * CGFloat(direction)
        move(currentLayer, from: middle, to: CGPoint(x: middle.x - distance, y: middle.y), duration: Self.slideDuration)
        move(incomingLayer, from: CGPoint(x: middle.x + distance, y: middle.y), to: middle, duration: Self.slideDuration)
        CATransaction.commit()
    }

    func drag(_ width: CGFloat, current: CGImage, currentMotion: CALayer?, previous: ViewerSlideNeighbour,
              next: ViewerSlideNeighbour) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !dragging {
            dragging = true
            show(current: current)
            overlay(currentMotion, on: currentLayer, picture: current)
        }
        // Moving right uncovers the previous photo, on the left; moving left the next one.
        let side = width > 0 ? -1 : 1
        let neighbour = side < 0 ? previous : next
        let (picture, motion): (CGImage?, CALayer?) = if case .picture(let picture, motion: let motion) = neighbour {
            (picture, motion)
        } else {
            (nil, nil)
        }
        let pastTheEnd = if case .end = neighbour { true } else { false }
        // Past the first or the last photo, the photo gives a little and springs back.
        let offset = pastTheEnd ? width / 3 : width
        currentLayer.removeAllAnimations()
        incomingLayer.removeAllAnimations()
        currentLayer.position = CGPoint(x: middle.x + offset, y: middle.y)
        dragSide = pastTheEnd ? 0 : side
        // A neighbour without a picture yet leaves its place empty.
        incomingLayer.isHidden = picture == nil
        if let picture {
            incomingLayer.contents = picture
            incomingLayer.position = CGPoint(x: middle.x + offset + span * CGFloat(side), y: middle.y)
        }
        overlay(motion, on: incomingLayer, picture: picture)
        CATransaction.commit()
        guard picture != nil, !pastTheEnd else { return 0 }
        return min(1, abs(offset) / span)
    }

    func endDrag(direction: Int?) {
        guard dragging else { return }
        dragging = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let direction, direction == dragSide, incomingLayer.isHidden {
            // The photo coming in had no picture to slide: the viewer shows it at once.
            generation += 1
            isHidden = true
            currentLayer.contents = nil
            removeMotions()
            CATransaction.commit()
            return
        }
        finish()
        let current = currentLayer.presentation()?.position ?? currentLayer.position
        let incoming = incomingLayer.presentation()?.position ?? incomingLayer.position
        if let direction, direction == dragSide {
            let distance = span * CGFloat(direction)
            move(currentLayer, from: current, to: CGPoint(x: middle.x - distance, y: middle.y), duration: Self.swipeDuration)
            move(incomingLayer, from: incoming, to: middle, duration: Self.swipeDuration)
        } else {
            move(currentLayer, from: current, to: middle, duration: Self.swipeDuration)
            move(incomingLayer, from: incoming, to: CGPoint(x: middle.x + span * CGFloat(dragSide), y: middle.y), duration: Self.swipeDuration)
        }
        CATransaction.commit()
    }

    /// Over the photo underneath, the open photo where it is.
    private func show(current: CGImage) {
        generation += 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backdrop.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        backdrop.frame = bounds
        for photo in [currentLayer, incomingLayer] {
            photo.removeAllAnimations()
            photo.bounds = CGRect(origin: .zero, size: bounds.size)
            photo.position = middle
        }
        currentLayer.contents = current
        incomingLayer.isHidden = true
        removeMotions()
        isHidden = false
    }

    /// A Live Photo's motion over `photo`'s picture, where the picture lies in the layer, so it slides with it; any other
    /// goes. Without a picture, none.
    private func overlay(_ motion: CALayer?, on photo: CALayer, picture: CGImage?) {
        let shown = picture == nil ? nil : motion
        for sublayer in photo.sublayers ?? [] where sublayer !== shown { sublayer.removeFromSuperlayer() }
        guard let shown, let picture, picture.height > 0 else { return }
        if shown.superlayer !== photo { photo.addSublayer(shown) }
        shown.frame = ViewerMotionLayout.fitted(Double(picture.width) / Double(picture.height), in: photo.bounds)
    }

    /// The motions over the pictures go; each plays on in its photo's viewer.
    private func removeMotions() {
        for photo in [currentLayer, incomingLayer] {
            for sublayer in photo.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        }
    }

    /// Hides the layers when the animations added after it end, unless something newer has started. Set before the
    /// animations: Core Animation calls it at once when none are added after it, which hid the slide as it began.
    private func finish() {
        let current = generation
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current, !self.dragging else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.isHidden = true
            self.currentLayer.contents = nil
            self.incomingLayer.contents = nil
            self.removeMotions()
            CATransaction.commit()
        }
    }

    private func move(_ photo: CALayer, from start: CGPoint, to end: CGPoint, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: start)
        animation.toValue = NSValue(point: end)
        animation.duration = duration
        animation.timingFunction = Self.timing
        photo.position = end
        photo.add(animation, forKey: "slide")
    }
}

/// Whether the pointer is over the page, for the open photo's side arrows: an AppKit tracking area on a view that stays
/// while photos change. SwiftUI's hover, on each photo's viewer, started out as not over it until the pointer moved,
/// and missed some moves. This one also asks where the pointer is whenever its area changes.
struct ViewerPointerTracking: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var isInside: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                                  .inVisibleRect], owner: self))
            locatePointer()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            locatePointer()
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseMoved(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        /// Where the pointer is, without waiting for it to move. After the layout pass that asked: the page's state
        /// can't change during one.
        private func locatePointer() {
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                self.report(self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
            }
        }

        private func report(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onChange?(inside)
        }
    }
}

/// A two-finger double-tap on the trackpad, Photos' smart zoom. It arrives as an AppKit event, not a SwiftUI gesture.
struct ViewerSmartZoom: NSViewRepresentable {
    let onSmartZoom: () -> Void

    func makeNSView(context: Context) -> SmartZoomView { SmartZoomView() }

    func updateNSView(_ view: SmartZoomView, context: Context) { view.onSmartZoom = onSmartZoom }

    static func dismantleNSView(_ view: SmartZoomView, coordinator: ()) { view.stopMonitoring() }

    final class SmartZoomView: NSView {
        var onSmartZoom: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .smartMagnify) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onSmartZoom?()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
