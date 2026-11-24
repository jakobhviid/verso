// A page of the viewer on iOS whose picture zooms as Photos' do, a photo's (ViewerPhotoPage) and a video's
// (ViewerVideoPage) alike: the picture fitted to the screen in a zooming scroll view, so a pinch zooms it, a double tap
// zooms in where it lands and back out, and a zoomed picture pans with the finger. Pinched below its fitted size, it
// shrinks with the grid showing through and, let go below 0.8 of it, closes the viewer into its tile from there
// (ViewerState.pinchToClose). A video is drawn inside the picture, over its poster, so it zooms and closes as a photo
// does (ARCHITECTURE.md, "The viewer on the iPhone").

import UIKit

class ViewerZoomPage: ViewerPage, UIScrollViewDelegate {
    /// How far a picture zooms, as on the Mac.
    static let maximumZoom: CGFloat = 8

    let scrollView = UIScrollView()
    /// The picture the scroll view zooms: a photo, or a video's poster with the video drawn over it.
    let pictureView = UIImageView()
    /// The picture's width over its height, from the server until an image says otherwise.
    private(set) var aspectRatio: CGFloat
    /// The bounds and aspect ratio the picture was last fitted to.
    private var fittedFor: (bounds: CGSize, aspectRatio: CGFloat)?
    /// Zoomed in past its fitted size.
    private(set) var zoomedIn = false

    override init(item: AssetItem, state: ViewerState) {
        aspectRatio = item.ratio > 0 ? CGFloat(item.ratio) : 1
        super.init(item: item, state: state)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        // Below its fitted size, a pinch takes the picture away to close the viewer (ViewerState.pinchToClose).
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = Self.maximumZoom
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.bouncesZoom = true
        view.addSubview(scrollView)

        pictureView.contentMode = .scaleAspectFit
        pictureView.clipsToBounds = true
        pictureView.isAccessibilityElement = true
        pictureView.accessibilityTraits = .image
        scrollView.addSubview(pictureView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        installGestures(on: scrollView, after: doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if fittedFor?.bounds != scrollView.bounds.size { fitPicture() }
    }

    override func setCurrent(_ current: Bool) {
        super.setCurrent(current)
        // A picture slid away from comes back fitted, as in Photos.
        if !current { resetZoom() }
    }

    override var allowsCloseDrag: Bool { scrollView.zoomScale <= 1.01 }

    /// The picture as it is drawn, zoomed in, fitted or pinched smaller.
    override func pictureFrame(in other: UIView?) -> CGRect? {
        guard isViewLoaded, fittedFor != nil, pictureView.bounds.width > 0 else { return nil }
        return pictureView.convert(pictureView.bounds, to: other)
    }

    /// Back to the fitted size, at once.
    func resetZoom() {
        if scrollView.zoomScale != 1 { scrollView.setZoomScale(1, animated: false) }
    }

    /// Shows `image` as the picture. An image of the picture's own shape (not a ThumbHash's, which is only near it)
    /// fits the picture anew to that shape, unless it is zoomed in.
    func showPicture(_ image: CGImage, ownShape: Bool) {
        pictureView.image = UIImage(cgImage: image)
        guard ownShape, image.height > 0 else { return }
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        guard abs(ratio - aspectRatio) > 0.01 else { return }
        aspectRatio = ratio
        if !zoomedIn { fitPicture() }
    }

    /// The picture has been fitted anew: what a page draws over it takes its size.
    func pictureFitted() {}

    // MARK: Zoom

    /// The picture fitted inside the page at zoom 1, in the middle.
    private func fitPicture() {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let ratio = max(0.01, aspectRatio)
        var fitted = CGSize(width: bounds.width, height: bounds.width / ratio)
        if fitted.height > bounds.height { fitted = CGSize(width: bounds.height * ratio, height: bounds.height) }
        resetZoom()
        pictureView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        fittedFor = (bounds, aspectRatio)
        centrePicture()
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
        pictureFitted()
    }

    /// Keeps a picture smaller than the page in its middle as it zooms.
    private func centrePicture() {
        let bounds = scrollView.bounds.size
        let content = pictureView.frame.size
        let horizontal = max(0, (bounds.width - content.width) / 2)
        let vertical = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pictureView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centrePicture()
        let zoomed = scrollView.zoomScale > 1.01
        if zoomed != zoomedIn {
            zoomedIn = zoomed
            onZoomChange?(zoomed)
        }
        if scrollView.zoomScale < 0.99, scrollView.isZooming { state?.pinchToClose(scrollView.zoomScale) }
    }

    /// A pinch below the fitted size let go: the viewer closes from there, or the picture grows back.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scale < 0.99 else { return }
        if state?.endPinchToClose(scale) != true { scrollView.setZoomScale(1, animated: true) }
    }

    /// In where it lands, enough to fill the screen and at least twice; or back to fitted.
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        let bounds = scrollView.bounds.size
        let fitted = pictureView.bounds.size
        guard fitted.width > 0, fitted.height > 0 else { return }
        let fill = max(bounds.width / fitted.width, bounds.height / fitted.height)
        let scale = min(scrollView.maximumZoomScale, max(2, min(4, fill)))
        let point = recognizer.location(in: pictureView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
    }
}
