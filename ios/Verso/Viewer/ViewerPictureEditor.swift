// The photo's editor on iOS, Photos' Edit as Immich edits: the picture turned a quarter at a time and cropped, never
// the original. Edit in the viewer's bottom bar opens it over the viewer, on the picture as it was taken (Immich's
// unedited preview), turned and mirrored as the photo's edits turn it, under a frame whose corners and sides crop it
// and whose middle moves the crop. Nothing is written until Done, which saves the edit list through the shared
// MetadataState, as the Mac's Rotate and Crop save theirs (Immich's PUT /assets/{id}/edits); Cancel leaves the photo as
// it was. The crop is kept in the original's own upright pixels and goes first in the list, the turn is one rotate
// step, and a mirror made in Immich's web app stays (MetadataEditList, shared with the Mac, as Verso on Linux changes
// the list).

import SwiftUI

struct ViewerPictureEditor: View {
    let session: LibrarySession
    let asset: AssetResponse
    @Environment(\.dismiss) private var dismiss
    /// The edits the photo had as the editor opened, and the list as the editor changes it.
    @State private var loadedEdits: [MetadataEdit]?
    @State private var edits: [MetadataEdit] = []
    /// The crop, as fractions of the upright picture before any turn.
    @State private var crop = MetadataEditList.wholePicture
    /// The crop was changed here, so Done writes it; else the photo's own crop step stays as it was.
    @State private var cropChanged = false
    @State private var image: CGImage?
    @State private var loadError: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .navigationTitle("Edit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .modifier(ViewerMetadataErrorAlert(metadata: session.metadata))
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            ViewerCropCanvas(image: image, turn: ViewerPictureTurn(edits), crop: $crop, changed: $cropChanged)
                .padding(24)
                .disabled(saving)
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't Edit This Photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else {
            ProgressView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                .disabled(saving)
                .accessibilityIdentifier("Cancel Edit")
        }
        ToolbarItem(placement: .confirmationAction) {
            if saving {
                ProgressView()
            } else {
                Button("Done", systemImage: "checkmark", role: .confirm) { save() }
                    .disabled(image == nil)
                    .accessibilityIdentifier("Done Editing")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Rotate Left", systemImage: "rotate.left") { turn(-1) }
                .disabled(image == nil || saving)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Reset") { reset() }
                .disabled(!canReset || saving)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Rotate Right", systemImage: "rotate.right") { turn(1) }
                .disabled(image == nil || saving)
        }
    }

    /// Reset: the whole picture, not turned. A mirror made in Immich's web app stays, as this editor makes none.
    private var canReset: Bool {
        image != nil && (crop != MetadataEditList.wholePicture || edits.contains { $0.action == "rotate" })
    }

    /// The photo's edits, and its picture as it was taken, to edit from.
    private func load() async {
        do {
            let loaded = try await session.metadata.loadEdits(asset.id, session: session).edits
            loadedEdits = loaded
            edits = loaded
            if let dimensions = asset.exifInfo?.metadataDimensions {
                crop = MetadataEditList.crop(in: loaded, width: dimensions.width, height: dimensions.height)
            }
            guard let picture = await session.pipeline.thumbnail(asset.id, size: .preview, edited: false) else {
                if !Task.isCancelled { loadError = String(localized: "The photo as it was taken couldn't be loaded.") }
                return
            }
            image = picture
        } catch where !error.isCancellation {
            session.handle(error)
            loadError = error.localizedDescription
        } catch {}
    }

    private func turn(_ quarterTurns: Int) {
        edits = MetadataEditList.rotated(edits, quarterTurns: quarterTurns)
    }

    private func reset() {
        edits.removeAll { $0.action == "rotate" }
        crop = MetadataEditList.wholePicture
        cropChanged = true
    }

    /// Writes the edit list when it changed, and closes once Immich has made the pictures again.
    private func save() {
        guard let loadedEdits else {
            dismiss()
            return
        }
        var final = edits
        if cropChanged, let dimensions = asset.exifInfo?.metadataDimensions {
            final = MetadataEditList.cropped(final, crop: crop, width: dimensions.width, height: dimensions.height)
        }
        guard final != loadedEdits else {
            dismiss()
            return
        }
        saving = true
        let id = asset.id
        let session = session
        Task {
            if await session.metadata.saveEdits(id, edits: final, session: session) { dismiss() }
            saving = false
        }
    }
}

/// How the steps after the crop turn and mirror the picture, as Immich applies them in their order: a matrix of quarter
/// turns and mirrors on points about the picture's middle, x to the right and y down. A rotate step turns it clockwise
/// by its angle as seen; a horizontal mirror swaps left and right, a vertical one top and bottom.
struct ViewerPictureTurn: Equatable {
    /// Where a point goes: x becomes xx·x + xy·y, and y becomes yx·x + yy·y.
    private(set) var xx = 1
    private(set) var xy = 0
    private(set) var yx = 0
    private(set) var yy = 1

    init(_ edits: [MetadataEdit]) {
        for edit in edits {
            switch edit.action {
            case "rotate":
                let quarters = (((edit.parameters.angle ?? 0) / 90) % 4 + 4) % 4
                for _ in 0..<quarters { then(xx: 0, xy: -1, yx: 1, yy: 0) }
            case "mirror" where edit.parameters.axis == "vertical":
                then(xx: 1, xy: 0, yx: 0, yy: -1)
            case "mirror":
                then(xx: -1, xy: 0, yx: 0, yy: 1)
            default:
                break
            }
        }
    }

    /// A step after the ones so far.
    private mutating func then(xx stepXX: Int, xy stepXY: Int, yx stepYX: Int, yy stepYY: Int) {
        (xx, xy, yx, yy) = (stepXX * xx + stepXY * yx, stepXX * xy + stepXY * yy,
                            stepYX * xx + stepYY * yx, stepYX * xy + stepYY * yy)
    }

    /// The picture lies on its side: its width shows as its height.
    var swapsSides: Bool { xx == 0 }

    /// Mirrored by an odd number of mirrors.
    var mirrored: Bool { xx * yy - xy * yx < 0 }

    /// The clockwise quarter turns that follow a left-for-right mirror when `mirrored`, as SwiftUI draws the picture.
    var quarterTurns: Int {
        // The turn alone is the matrix times that mirror: its first column says which.
        switch mirrored ? (-xx, -yx) : (xx, yx) {
        case (1, 0): 0
        case (0, 1): 1
        case (-1, 0): 2
        default: 3
        }
    }

    /// A point of the picture before the turn, as fractions of it, to where it shows, as fractions of what shows.
    func shown(_ point: CGPoint) -> CGPoint {
        let across = point.x - 0.5
        let down = point.y - 0.5
        return CGPoint(x: CGFloat(xx) * across + CGFloat(xy) * down + 0.5,
                       y: CGFloat(yx) * across + CGFloat(yy) * down + 0.5)
    }

    /// Where a point that shows is in the picture before the turn: the matrix turned over undoes it.
    func picture(_ point: CGPoint) -> CGPoint {
        let across = point.x - 0.5
        let down = point.y - 0.5
        return CGPoint(x: CGFloat(xx) * across + CGFloat(yx) * down + 0.5,
                       y: CGFloat(xy) * across + CGFloat(yy) * down + 0.5)
    }

    func shown(_ rect: CGRect) -> CGRect {
        Self.rect(shown(rect.origin), shown(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    func picture(_ rect: CGRect) -> CGRect {
        Self.rect(picture(rect.origin), picture(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    private static func rect(_ corner: CGPoint, _ opposite: CGPoint) -> CGRect {
        CGRect(x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
               width: abs(corner.x - opposite.x), height: abs(corner.y - opposite.y))
    }
}

/// Where a finger takes the crop's frame: a corner moves its two sides, a side its own, the middle the whole frame.
private enum ViewerCropGrip: CaseIterable {
    // The middle first, under the sides and the corners, which take a touch before it.
    case middle, top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing

    var movesLeft: Bool { [.leading, .topLeading, .bottomLeading].contains(self) }
    var movesRight: Bool { [.trailing, .topTrailing, .bottomTrailing].contains(self) }
    var movesTop: Bool { [.top, .topLeading, .topTrailing].contains(self) }
    var movesBottom: Bool { [.bottom, .bottomLeading, .bottomTrailing].contains(self) }

    /// The area that takes the finger, about a frame of `box` in points: a corner's square, a side's strip between
    /// them, the middle inside.
    func area(around box: CGRect) -> CGRect {
        let reach: CGFloat = 44
        let half = reach / 2
        let innerWidth = max(0, box.width - reach)
        let innerHeight = max(0, box.height - reach)
        switch self {
        case .middle: return CGRect(x: box.minX + half, y: box.minY + half, width: innerWidth, height: innerHeight)
        case .top: return CGRect(x: box.minX + half, y: box.minY - half, width: innerWidth, height: reach)
        case .bottom: return CGRect(x: box.minX + half, y: box.maxY - half, width: innerWidth, height: reach)
        case .leading: return CGRect(x: box.minX - half, y: box.minY + half, width: reach, height: innerHeight)
        case .trailing: return CGRect(x: box.maxX - half, y: box.minY + half, width: reach, height: innerHeight)
        case .topLeading: return CGRect(x: box.minX - half, y: box.minY - half, width: reach, height: reach)
        case .topTrailing: return CGRect(x: box.maxX - half, y: box.minY - half, width: reach, height: reach)
        case .bottomLeading: return CGRect(x: box.minX - half, y: box.maxY - half, width: reach, height: reach)
        case .bottomTrailing: return CGRect(x: box.maxX - half, y: box.maxY - half, width: reach, height: reach)
        }
    }

    /// The frame, as fractions of what shows, moved by `delta`, kept on the picture and at least `minimum` in size.
    func moved(_ start: CGRect, by delta: CGSize, minimum: CGSize) -> CGRect {
        if self == .middle {
            let left = min(max(0, start.minX + delta.width), 1 - start.width)
            let top = min(max(0, start.minY + delta.height), 1 - start.height)
            return CGRect(origin: CGPoint(x: left, y: top), size: start.size)
        }
        var left = start.minX
        var top = start.minY
        var right = start.maxX
        var bottom = start.maxY
        if movesLeft { left = max(0, min(start.minX + delta.width, start.maxX - minimum.width)) }
        if movesRight { right = min(1, max(start.maxX + delta.width, start.minX + minimum.width)) }
        if movesTop { top = max(0, min(start.minY + delta.height, start.maxY - minimum.height)) }
        if movesBottom { bottom = min(1, max(start.maxY + delta.height, start.minY + minimum.height)) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// The picture, turned as its edits turn it and fitted to the space, under the crop's frame: what the crop leaves out
/// dimmed, the corners and sides dragged to crop, the middle dragged to move the crop, and thirds while a finger moves
/// it, as Photos crops.
private struct ViewerCropCanvas: View {
    let image: CGImage
    let turn: ViewerPictureTurn
    @Binding var crop: CGRect
    @Binding var changed: Bool
    /// The frame as the drag began, as fractions of what shows.
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let pictureRatio = CGFloat(image.width) / CGFloat(max(image.height, 1))
            let shown = Self.fitted(ratio: turn.swapsSides ? 1 / pictureRatio : pictureRatio, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: turn.swapsSides ? shown.height : shown.width,
                           height: turn.swapsSides ? shown.width : shown.height)
                    .scaleEffect(x: turn.mirrored ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(Double(90 * turn.quarterTurns)))
                    .frame(width: shown.width, height: shown.height)
                    .accessibilityLabel(Text("Photo"))
                cropFrame(in: shown)
            }
            .frame(width: shown.width, height: shown.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func cropFrame(in size: CGSize) -> some View {
        let fraction = turn.shown(crop)
        let box = CGRect(x: fraction.minX * size.width, y: fraction.minY * size.height,
                         width: fraction.width * size.width, height: fraction.height * size.height)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(box)
            }
            .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
            if dragStart != nil { thirds(of: box) }
            Path { path in path.addRect(box) }
                .stroke(.white.opacity(0.9), lineWidth: 1)
            corners(of: box)
            ForEach(ViewerCropGrip.allCases, id: \.self) { grip in
                let area = grip.area(around: box)
                Color.clear
                    .contentShape(.rect)
                    .frame(width: area.width, height: area.height)
                    .position(x: area.midX, y: area.midY)
                    .gesture(drag(grip, in: size))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(Text("Crop"))
    }

    /// Photos' corners: short thick lines along each corner's two sides.
    private func corners(of box: CGRect) -> some View {
        let length = min(20, box.width / 2, box.height / 2)
        return Path { path in
            let corners: [(point: CGPoint, across: CGFloat, down: CGFloat)] = [
                (CGPoint(x: box.minX, y: box.minY), 1, 1), (CGPoint(x: box.maxX, y: box.minY), -1, 1),
                (CGPoint(x: box.minX, y: box.maxY), 1, -1), (CGPoint(x: box.maxX, y: box.maxY), -1, -1),
            ]
            for corner in corners {
                path.move(to: CGPoint(x: corner.point.x + corner.across * length, y: corner.point.y))
                path.addLine(to: corner.point)
                path.addLine(to: CGPoint(x: corner.point.x, y: corner.point.y + corner.down * length))
            }
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
    }

    private func thirds(of box: CGRect) -> some View {
        Path { path in
            for third in 1...2 {
                let across = box.minX + box.width * CGFloat(third) / 3
                path.move(to: CGPoint(x: across, y: box.minY))
                path.addLine(to: CGPoint(x: across, y: box.maxY))
                let down = box.minY + box.height * CGFloat(third) / 3
                path.move(to: CGPoint(x: box.minX, y: down))
                path.addLine(to: CGPoint(x: box.maxX, y: down))
            }
        }
        .stroke(.white.opacity(0.6), lineWidth: 0.5)
    }

    /// Follows the finger in what shows, and keeps the crop in the picture before the turn.
    private func drag(_ grip: ViewerCropGrip, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? turn.shown(crop)
                if dragStart == nil { dragStart = start }
                let delta = CGSize(width: value.translation.width / max(size.width, 1),
                                   height: value.translation.height / max(size.height, 1))
                let minimum = CGSize(width: min(1, 48 / max(size.width, 1)), height: min(1, 48 / max(size.height, 1)))
                crop = turn.picture(grip.moved(start, by: delta, minimum: minimum))
                changed = true
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The largest size of `ratio`, width over height, inside `space`.
    private static func fitted(ratio: CGFloat, in space: CGSize) -> CGSize {
        guard space.width > 0, space.height > 0, ratio > 0 else { return .zero }
        if space.width / space.height > ratio { return CGSize(width: space.height * ratio, height: space.height) }
        return CGSize(width: space.width, height: space.width / ratio)
    }
}
