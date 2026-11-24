import AppKit
import QuartzCore

/// What a tile of the Mac's photo grid shows besides its photo, the same for every tile of a grid.
struct PhotoGridTileLook: Equatable {
    /// The thumbnail asked for: Immich's preview for the large sizes.
    var size: ImmichClient.ThumbnailSize = .thumbnail
    /// The whole photo inside its square, as Photos' Aspect Ratio grid, instead of the square filled.
    var fit = false
    /// Changes as edits change pictures (MetadataState.imageRevision), so a photo cropped or turned loads again.
    var revision = 0
    /// Large Files: each photo's size at its top left.
    var showsFileSize = false
    /// Assign Location: each photo's place at its foot, as on Linux: its city, "GPS" for coordinates without one, or
    /// "No GPS".
    var showsLocation = false
}

/// A tile's item in the collection view.
final class PhotoGridTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridTile")

    var tile: PhotoGridTileView { view as! PhotoGridTileView }

    override func loadView() {
        view = PhotoGridTileView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.prepareForReuse()
    }
}

/// One square of the Mac's photo grid: the thumbnail filling the square edge to edge, or whole inside it with rounded
/// corners in the Aspect Ratio grid, its ThumbHash until the thumbnail comes, a favorite's heart, a stack's count, LIVE
/// and a video's length at its foot on a soft shade, and the selection's frame and tint (a ring just outside a whole
/// photo). Drawn in layers, so a tile shows the picture already in memory
/// for its photo from its first frame, as the iPhone's tiles do (`GridTile.thumbnailAtHand`): no grey square flashes
/// on a fast scroll or a zoom. Nothing fades in as it loads.
final class PhotoGridTileView: NSView {
    private let picture = CALayer()
    private let ring = CALayer()
    private let tint = CALayer()
    private var badges: PhotoGridBadges?
    private var fileSize: PhotoGridPlate?
    private var location: PhotoGridPlate?
    private var failedSymbol: NSImageView?

    private(set) var asset: AssetItem?
    private var look = PhotoGridTileLook()
    private(set) var isSelected = false
    /// The picture shown, and whether it is the thumbnail asked for (not a stand-in).
    private(set) var image: CGImage?
    private var isFinal = false
    private var loading: Task<Void, Never>?
    /// What `loading` was started for: a tile given the same again keeps what it has.
    private var loadKey: LoadKey?

    private struct LoadKey: Equatable {
        let id: String
        let size: ImmichClient.ThumbnailSize
        let revision: Int
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        ring.borderWidth = 3
        for sublayer in [picture, tint, ring] {
            sublayer.isHidden = sublayer !== picture
            layer?.addSublayer(sublayer)
        }
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The colours, in the window's appearance, which this is called again for as it changes.
    override func updateLayer() {
        let fill = NSColor.quaternaryLabelColor.withAlphaComponent(NSColor.quaternaryLabelColor.alphaComponent * 0.5)
        picture.backgroundColor = fill.cgColor
        ring.borderColor = NSColor.controlAccentColor.cgColor
        tint.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    /// The tiles take no clicks of their own: the grid works out which photo a click is on (`PhotoGridCollectionView`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        loadKey = nil
        asset = nil
        setImage(nil, final: false)
        failedSymbol?.isHidden = true
    }

    /// The photo, as the model has it now, and how the grid shows its tiles. A photo the tile shows already keeps its
    /// picture; another shows what is already in memory for it at once, and loads the rest.
    func show(_ asset: AssetItem?, look: PhotoGridTileLook, selected: Bool, pipeline: ImagePipeline, animated: Bool = false) {
        let reshaped = look.fit != self.look.fit || asset?.ratio != self.asset?.ratio
        self.asset = asset
        self.look = look
        isSelected = selected
        updateBadges()
        load(pipeline)
        if reshaped { needsLayout = true }
        if animated {
            // A direct action on the photos shown (Show Aspect Ratio): their frames and crops change shape together.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            placeLayers(animated: true)
            CATransaction.commit()
        } else {
            placeLayers(animated: false)
        }
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        placeLayers(animated: false)
    }

    /// Stops loading as the tile leaves the view; it loads again if it comes back before it is reused.
    func stopLoading() {
        guard loading != nil else { return }
        loading?.cancel()
        loading = nil
        if !isFinal { loadKey = nil }
    }

    // MARK: Loading

    private func load(_ pipeline: ImagePipeline) {
        guard let asset else {
            loading?.cancel()
            loading = nil
            loadKey = nil
            setImage(nil, final: false)
            return
        }
        let key = LoadKey(id: asset.id, size: look.size, revision: look.revision)
        guard key != loadKey else { return }
        let sameAsset = loadKey?.id == asset.id
        loadKey = key
        loading?.cancel()
        loading = nil
        failedSymbol?.isHidden = true
        if let atHand = pipeline.cachedThumbnail(asset.id, size: look.size) {
            setImage(atHand, final: true)
            return
        }
        // What is at hand stands in while the thumbnail asked for loads: the other size, what the tile showed of this
        // photo, or its ThumbHash already decoded.
        let other: ImmichClient.ThumbnailSize = look.size == .preview ? .thumbnail : .preview
        let standIn = pipeline.cachedThumbnail(asset.id, size: other)
            ?? (sameAsset ? image : nil)
            ?? asset.thumbhash.flatMap { ThumbHash.cachedImage(base64: $0) }
        setImage(standIn, final: false)
        let hash = standIn == nil ? asset.thumbhash : nil
        loading = Task { [weak self] in
            if let hash {
                let decoded = await ThumbHash.placeholder(base64: hash)
                guard !Task.isCancelled, let self, self.loadKey == key else { return }
                if self.image == nil { self.setImage(decoded, final: false) }
            }
            let loaded = await pipeline.gridThumbnail(key.id, size: key.size)
            guard !Task.isCancelled, let self, self.loadKey == key else { return }
            self.loading = nil
            if let loaded {
                self.setImage(loaded, final: true)
            } else if self.image == nil {
                self.showFailed()
            }
        }
    }

    private func setImage(_ image: CGImage?, final: Bool) {
        self.image = image
        isFinal = final && image != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    private func showFailed() {
        let symbol = failedSymbol ?? {
            let view = NSImageView()
            view.contentTintColor = .tertiaryLabelColor
            view.symbolConfiguration = .init(textStyle: .title2)
            addSubview(view)
            failedSymbol = view
            return view
        }()
        symbol.image = NSImage(systemSymbolName: asset?.isVideo == true ? "video.slash" : "photo", accessibilityDescription: nil)
        symbol.isHidden = false
        needsLayout = true
    }

    // MARK: Layout

    /// The photo's rectangle: the square, or the whole photo inside it with room around it.
    private var pictureFrame: CGRect {
        guard look.fit else { return bounds }
        let ratio = max(0.2, min(5, asset?.ratio ?? 1))
        return ViewerMotionLayout.fitted(ratio, in: bounds.insetBy(dx: 5, dy: 5))
    }

    override func layout() {
        super.layout()
        placeLayers(animated: false)
    }

    private func placeLayers(animated: Bool) {
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        let frame = pictureFrame
        let corner: CGFloat = look.fit ? 6 : 0
        picture.frame = frame
        picture.cornerRadius = corner
        picture.contentsGravity = look.fit ? .resizeAspect : .resizeAspectFill
        // Fitted photos get Photos' ring just outside them; squares a frame and a tint.
        ring.isHidden = !isSelected
        ring.frame = look.fit ? frame.insetBy(dx: -4, dy: -4) : bounds
        ring.cornerRadius = look.fit ? corner + 3 : 0
        tint.isHidden = !isSelected || look.fit
        tint.frame = bounds
        if !animated { CATransaction.commit() }
        if let badges, !badges.isHidden {
            let height = badges.fittingHeight
            badges.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(height, frame.height))
            badges.cornerRadius = corner
        }
        if let fileSize, !fileSize.isHidden {
            let size = fileSize.fittingSize
            fileSize.frame = CGRect(x: frame.minX + 5, y: frame.maxY - 5 - size.height, width: min(size.width, frame.width - 10),
                                    height: size.height)
        }
        if let location, !location.isHidden {
            let size = location.fittingSize
            let width = min(size.width, frame.width - 10)
            location.frame = CGRect(x: frame.midX - width / 2, y: frame.minY + 5, width: width, height: size.height)
        }
        if let failedSymbol, !failedSymbol.isHidden {
            let size = failedSymbol.fittingSize
            failedSymbol.frame = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    // MARK: Badges

    private func updateBadges() {
        let content = asset.map(PhotoGridBadges.Content.init)
        if let content, content.isShown {
            let badges = self.badges ?? {
                let view = PhotoGridBadges()
                addSubview(view)
                self.badges = view
                return view
            }()
            badges.show(content)
            badges.isHidden = false
        } else {
            badges?.isHidden = true
        }
        let bytes = look.showsFileSize ? asset?.fileSizeInBytes : nil
        if let bytes {
            plate(\.fileSize).text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        fileSize?.isHidden = bytes == nil
        let place: String? = look.showsLocation ? asset.map { asset in
            if !asset.hasLocation { return String(localized: "No GPS") }
            if let city = asset.city, !city.isEmpty { return city }
            return String(localized: "GPS")
        } : nil
        if let place {
            plate(\.location, alpha: 0.55, weight: .medium).text = place
        }
        location?.isHidden = place == nil
        needsLayout = true
    }

    private func plate(_ keyPath: ReferenceWritableKeyPath<PhotoGridTileView, PhotoGridPlate?>, alpha: CGFloat = 0.65,
                       weight: NSFont.Weight = .regular) -> PhotoGridPlate {
        if let plate = self[keyPath: keyPath] { return plate }
        let plate = PhotoGridPlate(alpha: alpha, weight: weight)
        addSubview(plate)
        self[keyPath: keyPath] = plate
        return plate
    }
}

/// A tile's marks at its foot, as `ThumbnailCell`'s: a favorite's heart on a dark plate at the left; a stack's count,
/// LIVE and a video's length and symbol at the right; white with a shadow over a shade that keeps them readable on snow
/// and sky.
final class PhotoGridBadges: NSView {
    struct Content: Equatable {
        let favorite: Bool
        let stack: Int?
        let live: Bool
        let duration: String?
        let video: Bool

        init(_ asset: AssetItem) {
            favorite = asset.isFavorite
            stack = asset.stackCount
            live = asset.livePhotoVideoID != nil
            video = asset.isVideo
            duration = asset.isVideo ? asset.durationMS.map(Duration.formatMilliseconds) : nil
        }

        var isShown: Bool { favorite || stack != nil || live || video }
    }

    private let shade = PhotoGridShade()
    private let marks = NSView()
    private let heartPlate = NSView()
    private let heart = PhotoGridBadges.symbol("heart.fill")
    private let stackSymbol = PhotoGridBadges.symbol("square.stack.3d.up.fill")
    private let stackCount = PhotoGridBadges.label(monospaced: false)
    private let liveSymbol = PhotoGridBadges.symbol("livephoto")
    private let durationLabel = PhotoGridBadges.label(monospaced: true)
    private let videoSymbol = PhotoGridBadges.symbol("video.fill")
    private var content: Content?

    static let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)

    private static func symbol(_ name: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = .init(pointSize: font.pointSize, weight: .semibold)
        view.contentTintColor = .white
        return view
    }

    private static func label(monospaced: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monospaced ? .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold) : font
        label.textColor = .white
        return label
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(shade)
        addSubview(marks)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        marks.shadow = shadow
        heartPlate.wantsLayer = true
        heartPlate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        heartPlate.layer?.cornerRadius = 4
        heartPlate.addSubview(heart)
        for view in [heartPlate, stackSymbol, stackCount, liveSymbol, durationLabel, videoSymbol] { marks.addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    /// A whole photo's rounded corners, at its foot (not flipped: the corners at the least y).
    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
    }

    /// As tall as its marks with their padding.
    var fittingHeight: CGFloat { ceil(Self.font.boundingRectForFont.height) + 6 + 10 }

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        heartPlate.isHidden = !content.favorite
        stackSymbol.isHidden = content.stack == nil
        stackCount.isHidden = content.stack == nil
        stackCount.stringValue = content.stack.map { "\($0)" } ?? ""
        liveSymbol.isHidden = !content.live
        durationLabel.isHidden = !content.video
        durationLabel.stringValue = content.duration ?? ""
        videoSymbol.isHidden = !content.video
        needsLayout = true
    }

    override func layout() {
        super.layout()
        shade.frame = bounds
        marks.frame = bounds
        // Non-flipped: the marks sit 5 points above the foot, 6 in from the sides.
        let middle = bounds.minY + 5 + (bounds.height - 10) / 2
        func place(_ view: NSView, x: CGFloat) -> CGFloat {
            let size = view.fittingSize
            view.frame = CGRect(x: x, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
            return size.width
        }
        if !heartPlate.isHidden {
            let size = heart.fittingSize
            heartPlate.frame = CGRect(x: 6, y: (middle - size.height / 2 - 3).rounded(), width: size.width + 6, height: size.height + 6)
            heart.frame = CGRect(x: 3, y: 3, width: size.width, height: size.height)
        }
        // From the right edge in: the video's symbol and length, LIVE, then the stack's count and symbol.
        // Each with the room before the next one to its left: 4 points between marks, 3 inside the stack's label.
        let fromRight: [(view: NSView, gap: CGFloat)] = [(videoSymbol, 4), (durationLabel, 4), (liveSymbol, 4), (stackCount, 3),
                                                         (stackSymbol, 4)]
        var x = bounds.maxX - 6
        for mark in fromRight where !mark.view.isHidden {
            x -= place(mark.view, x: x - mark.view.fittingSize.width) + mark.gap
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The shade under a tile's marks: clear at its top, darker at the photo's foot.
final class PhotoGridShade: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Not flipped: 90 degrees runs from the foot up.
        NSGradient(starting: NSColor.black.withAlphaComponent(0.35), ending: .clear)?.draw(in: bounds, angle: 90)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// White text on a dark plate over a photo: Large Files' size, Assign Location's place.
final class PhotoGridPlate: NSView {
    private let label = NSTextField(labelWithString: "")

    init(alpha: CGFloat, weight: NSFont.Weight) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: weight)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(width: ceil(size.width) + 14, height: ceil(size.height) + 6)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 7, dy: 3)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
