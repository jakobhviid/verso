// The viewer's pages on iOS: the system's page view controller, one page a photo or video, swiped left and right
// through the grid's photos with a gap between them, as Photos pages. Pages are made as they are needed, from the photo
// beside the shown one (ViewerState.neighbour), so a library of any size pages without its months all loaded; a month
// that loads later makes the pager ask for the neighbours again. While a photo is zoomed in, it pans and does not page.
// On each page a tap hides and shows the controls; a drag up is the stage's scroll, which brings the details
// (ViewerStage), and a drag down from the photo alone takes it away, shrinking, and closes the viewer into its tile once
// let go far enough down (ViewerState.dragToClose). A photo turned or cropped in the editor
// shows its new picture in its page.

import SwiftUI
import UIKit

struct ViewerPager: UIViewControllerRepresentable {
    let state: ViewerState
    /// Changes as the model's months load or change, so the pages beside the shown one are asked for again.
    let modelRevision: Int
    /// Changes as edits change pictures (MetadataState.imageRevision), so the shown page loads its picture again.
    let imageRevision: Int

    func makeCoordinator() -> ViewerPagerCoordinator { ViewerPagerCoordinator(state: state) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: ViewerPagerCoordinator.pageSpacing])
        context.coordinator.attach(to: pager)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.modelChanged(modelRevision)
        context.coordinator.picturesChanged(imageRevision)
    }
}

@MainActor
final class ViewerPagerCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    /// The gap between photos while they slide, as in Photos.
    static let pageSpacing: CGFloat = 20
    /// Pages kept for a swipe back: the shown one and the ones just beside it.
    private static let keptPages = 5

    private let state: ViewerState
    private weak var pager: UIPageViewController?
    private var pages: [String: ViewerPage] = [:]
    /// The pages' photos, the most recently asked for last.
    private var pageOrder: [String] = []
    /// A neighbour of the shown photo was asked for before its month had loaded.
    private var neighbourMissing = false
    private var lastRevision: Int?
    private var lastImageRevision: Int?
    /// The page a swipe is bringing in, and the swipe's place, read as it moves.
    private var incoming: ViewerPage?
    private var swipeObservation: NSKeyValueObservation?
    /// How far across the incoming page is when its Live Photo starts moving, as Photos' do (at 60% to 71%).
    private static let glimpseAcross: CGFloat = 0.65

    init(state: ViewerState) {
        self.state = state
    }

    /// The page view controller's own scroll view, which pages.
    private var pagingScrollView: UIScrollView? {
        pager?.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }

    private var currentPage: ViewerPage? { pager?.viewControllers?.first as? ViewerPage }

    func attach(to pager: UIPageViewController) {
        self.pager = pager
        pager.dataSource = self
        pager.delegate = self
        pager.view.backgroundColor = .clear
        state.showPage = { [weak self] item, step, animated in self?.show(item, step: step, animated: animated) }
        state.playLivePhoto = { [weak self] in self?.currentPage?.playLivePhoto() }
        state.stopLivePhoto = { [weak self] in self?.currentPage?.stopLivePhoto() }
        state.loadLivePhoto = { [weak self] in self?.currentPage?.loadLivePhoto() }
        swipeObservation = pagingScrollView?.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.swipeMoved(scrollView) }
        }
        state.pictureFrame = { [weak self] in self?.currentPage?.pictureFrame(in: nil) }
        state.closingZoom = { [weak self] closing in self?.currentPage?.closingZoom(closing) }
        showFirstPage()
    }

    private func showFirstPage() {
        guard let pager, pager.viewControllers?.isEmpty ?? true, let item = state.currentItem else { return }
        let page = page(for: item)
        pager.setViewControllers([page], direction: .forward, animated: false)
        page.setCurrent(true)
        state.settle(on: item)
        prepareNeighbours(of: item)
    }

    /// A swipe's place: the incoming page, once 65% across, has its Live Photo move.
    private func swipeMoved(_ scrollView: UIScrollView) {
        guard let incoming, scrollView.bounds.width > 0 else { return }
        let across = abs(scrollView.contentOffset.x - scrollView.bounds.width) / scrollView.bounds.width
        if across >= Self.glimpseAcross { incoming.beginGlimpse() }
    }

    /// The motions of the Live Photos beside the shown one, fetched ahead, so a swipe to one finds it ready.
    private func prepareNeighbours(of item: AssetItem) {
        let client = state.session.client
        guard state.glimpsesPlay else { return }
        for step in [-1, 1] {
            guard let neighbour = state.neighbour(of: item.id, step: step),
                  let videoID = neighbour.livePhotoVideoID else { continue }
            let request = client.originalRequest(videoID)
            Task { _ = try? await LiveMotions.shared.motion(videoID, request: request) }
        }
    }

    private func page(for item: AssetItem) -> ViewerPage {
        pageOrder.removeAll { $0 == item.id }
        pageOrder.append(item.id)
        if let page = pages[item.id] { return page }
        let page: ViewerPage = item.isVideo ? ViewerVideoPage(item: item, state: state) : ViewerPhotoPage(item: item, state: state)
        page.onZoomChange = { [weak self] zoomed in self?.zoomChanged(zoomed) }
        pages[item.id] = page
        while pageOrder.count > Self.keptPages,
              let oldest = pageOrder.first(where: { $0 != state.currentID && $0 != item.id }) {
            pageOrder.removeAll { $0 == oldest }
            pages[oldest] = nil
        }
        return page
    }

    /// Sends the pager to a photo: after a delete, or when the shown one is taken away.
    private func show(_ item: AssetItem, step: Int, animated: Bool) {
        guard let pager else { return }
        let page = page(for: item)
        let previous = currentPage
        pager.setViewControllers([page], direction: step < 0 ? .reverse : .forward, animated: animated) { [weak self] _ in
            guard animated else { return }
            // A page view controller keeps the neighbours it had before an animated change: setting the page again,
            // without the animation, makes it ask for the new ones.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.setAgain(page) }
            }
        }
        if previous !== page { previous?.setCurrent(false) }
        page.setCurrent(true)
        state.settle(on: item)
    }

    private func setAgain(_ page: ViewerPage) {
        guard let pager, pager.viewControllers?.first === page else { return }
        pager.setViewControllers([page], direction: .forward, animated: false)
    }

    /// The model's months changed: a neighbour that was missing may be there now, and the shown photo may need
    /// finding again after the model read itself anew.
    func modelChanged(_ revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        guard let pager else { return }
        if pager.viewControllers?.isEmpty ?? true {
            showFirstPage()
            return
        }
        if state.model.order(of: state.currentID) == nil { state.relocateCurrent() }
        refreshNeighbours()
    }

    /// An edit changed a picture, which the editor over the viewer makes only of the shown photo: its page loads it
    /// again.
    func picturesChanged(_ revision: Int) {
        guard revision != lastImageRevision else { return }
        let first = lastImageRevision == nil
        lastImageRevision = revision
        if !first { currentPage?.reloadPicture() }
    }

    /// Sets the shown page again, so the pager asks for a neighbour it was told was not there.
    private func refreshNeighbours() {
        guard neighbourMissing, let pager, let current = currentPage else { return }
        // Not in the middle of a swipe, which setting the page would cut short: once it has ended.
        if let scrollView = pagingScrollView, scrollView.isDragging || scrollView.isDecelerating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.refreshNeighbours() }
            }
            return
        }
        neighbourMissing = false
        pager.setViewControllers([current], direction: .forward, animated: false)
    }

    private func zoomChanged(_ zoomed: Bool) {
        pagingScrollView?.isScrollEnabled = !zoomed
        state.zoomChanged(zoomed)
    }

    // MARK: UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbourPage(of: viewController, step: -1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbourPage(of: viewController, step: 1)
    }

    private func neighbourPage(of controller: UIViewController, step: Int) -> UIViewController? {
        guard let page = controller as? ViewerPage else { return nil }
        guard let item = state.neighbour(of: page.item.id, step: step) else {
            if page.item.id == state.currentID { neighbourMissing = true }
            return nil
        }
        return self.page(for: item)
    }

    // MARK: UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        incoming = pendingViewControllers.first as? ViewerPage
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        // Let go, the swipe goes back: what it was bringing in stops.
        if !completed { incoming?.withdrawGlimpse() }
        incoming = nil
        guard completed, let page = pageViewController.viewControllers?.first as? ViewerPage else { return }
        for previous in previousViewControllers where previous !== page {
            (previous as? ViewerPage)?.setCurrent(false)
        }
        page.setCurrent(true)
        state.settle(on: page.item)
        prepareNeighbours(of: page.item)
    }
}

/// One page of the viewer: a photo or a video. A tap hides and shows the controls, or brings the photo back from its
/// details, and a vertical drag pulls the details up or down.
class ViewerPage: UIViewController, UIGestureRecognizerDelegate {
    let item: AssetItem
    weak var state: ViewerState?
    /// Called as the page zooms in from fitted, and back.
    var onZoomChange: ((Bool) -> Void)?
    /// Whether the page is the one shown.
    private(set) var isCurrent = false
    private var closePan: UIPanGestureRecognizer?

    init(item: AssetItem, state: ViewerState) {
        self.item = item
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// The page is shown, or another one is: a video plays only while its page is shown.
    func setCurrent(_ current: Bool) {
        isCurrent = current
    }

    /// The Live badge: a Live Photo plays once.
    func playLivePhoto() {}

    /// The Live badge: a Live Photo switched off stops, and one switched on loads its motion.
    func stopLivePhoto() {}
    func loadLivePhoto() {}

    /// Swiped toward, the page is 65% across: a Live Photo moves as it comes in, as Photos' do (not as the viewer
    /// opens); and the swipe let go, it stops.
    func beginGlimpse() {}
    func withdrawGlimpse() {}

    /// An edit changed the picture: the page shows it again.
    func reloadPicture() {}

    /// Where the page draws its picture, in another view's coordinates (nil: its window's), once it has been laid out.
    func pictureFrame(in other: UIView?) -> CGRect? { nil }

    /// The viewer is closing into the grid (true), or a drag that began it was let go (false): what plays stops, or
    /// plays again.
    func closingZoom(_ closing: Bool) {}

    /// A drag down closes the viewer, unless the page is panning a zoomed photo.
    var allowsCloseDrag: Bool { true }

    /// The tap that hides and shows the controls, after a double tap has had its chance, and the drag down from the
    /// photo alone that closes the viewer.
    func installGestures(on target: UIView, after doubleTap: UIGestureRecognizer?) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        if let doubleTap { tap.require(toFail: doubleTap) }
        tap.cancelsTouchesInView = false
        tap.delegate = self
        target.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        target.addGestureRecognizer(pan)
        closePan = pan
        // With the details in a panel (an iPad), a swipe up brings them and a swipe down takes them away, as the
        // stage's scroll does on a phone.
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            target.addGestureRecognizer(swipe)
        }
    }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        guard let state, state.detailsInPanel, !state.isZoomed else { return }
        if recognizer.direction == .up { state.showDetails() } else { state.hideDetails() }
    }

    @objc private func tapped() {
        state?.photoTapped()
    }

    /// Measured in the window, as the photo itself moves and shrinks under the finger.
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let state else { return }
        let translation = recognizer.translation(in: nil)
        let moved = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began:
            holdPagerStill()
            state.dragToClose(moved)
        case .changed:
            state.dragToClose(moved)
        case .ended:
            state.endDragToClose(moved, velocity: recognizer.velocity(in: nil))
        case .cancelled, .failed:
            state.endDragToClose(.zero, velocity: .zero)
        default:
            break
        }
    }

    /// The pager's own drag, which began with this one, gives way, so the photo does not page while the finger takes it
    /// down: switching its recognizer off and on again cancels it for this touch alone.
    private func holdPagerStill() {
        var ancestor = view.superview
        while let current = ancestor {
            if let pagingScrollView = current as? UIScrollView {
                pagingScrollView.panGestureRecognizer.isEnabled = false
                pagingScrollView.panGestureRecognizer.isEnabled = true
                return
            }
            ancestor = current.superview
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Down from the photo alone, to close; up is the stage's scroll, and sideways the pager's.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if let swipe = recognizer as? UISwipeGestureRecognizer, let state {
            return state.detailsInPanel && !state.isZoomed && state.showsDetails == (swipe.direction == .down)
        }
        guard recognizer === closePan, let pan = recognizer as? UIPanGestureRecognizer, let state else { return true }
        let velocity = pan.velocity(in: nil)
        guard allowsCloseDrag, velocity.y > 0, abs(velocity.y) > abs(velocity.x) * 1.5 else { return false }
        return state.allowsDragToClose(velocity: CGVector(dx: velocity.x, dy: velocity.y))
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
