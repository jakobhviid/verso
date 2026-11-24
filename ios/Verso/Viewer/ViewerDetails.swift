// The details of the viewer's photo on iOS, as Photos has them: a swipe up, or Info, slides the photo to the top of the
// screen, fitted there, and its details come beneath it as rounded cards, which push the photo up and away as they
// scroll, with the bottom bar floating over them; a swipe down, Info again, a tap on the photo or a pull down past the
// cards' top brings the photo back. The cards are Photos': the caption (Immich's description, typed in place); the
// rating, one to five stars, where the account has ratings on in Immich, as the Mac shows them under the description;
// the date and time with Adjust, and the file's name with whether its original is on this iPhone; the camera with
// badges for the format and Live; the lens with the focal length and aperture, and the resolution, megapixels and file
// size; ISO, focal length, aperture and shutter in one row (Immich keeps no exposure compensation); the place on a map
// with Adjust, named from Immich's own data (its city, state and country), the map's tiles from Apple. Then Verso's
// own: the people in it, its albums and its tags, which open their pages (ViewerState.open decides where). The date,
// the place and the rating change through the shared MetadataState, and the details come from the shared
// AssetInspectorState, as on the Mac.

import MapKit
import SwiftUI

/// Where the details lead: a person's photos, an album, a tag's photos, or the place on a map.
enum ViewerDetailsRoute: Hashable {
    case person(id: String, name: String)
    case album(Album)
    case tag(id: String, name: String)
    case place(latitude: Double, longitude: Double, title: String)
}

/// Where the photo goes as its details come up: fitted into the top of the screen, a quarter of it at least and a
/// little under half at most, with the details beneath.
struct ViewerDetailsLayout {
    /// The height at the top of the screen the photo fits into with the details up.
    let photoHeight: CGFloat
    /// The photo's scale there, from its size fitted to the whole screen.
    let photoScale: CGFloat
    /// How far its middle moves up.
    let photoOffset: CGFloat

    init(screen: CGSize, aspectRatio: CGFloat) {
        let ratio = max(aspectRatio, 0.05)
        var fitted = CGSize(width: screen.width, height: screen.width / ratio)
        if fitted.height > screen.height { fitted = CGSize(width: screen.height * ratio, height: screen.height) }
        let height = min(max(fitted.height, screen.height * 0.25), screen.height * 0.45).rounded()
        photoHeight = height
        photoScale = fitted.height > height ? height / fitted.height : 1
        photoOffset = height / 2 - screen.height / 2
    }
}

/// The details beneath the photo, in the stage's one scroll with it (ViewerStage). They are made only while they are up
/// or moving, so paging with them away loads no faces, map or tags.
struct ViewerDetails: View {
    let state: ViewerState
    /// Room under the last card for the bottom bar, which floats over the cards.
    let bottomClearance: CGFloat

    var body: some View {
        Group {
            if state.detailsActive {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, bottomClearance)
            } else {
                Color.clear
            }
        }
        // A caption that did not save; a date or place says so in its own sheet.
        .modifier(ViewerMetadataErrorAlert(metadata: state.session.metadata,
                                           isActive: state.presented == nil && state.editing == nil))
    }

    @ViewBuilder
    private var content: some View {
        switch state.inspector.phase(for: state.currentID) {
        case .none, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        case .failed:
            ContentUnavailableView {
                Label("Can't Load the Details", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") { state.detailsAttempt += 1 }
            }
        case .current, .stale:
            if let asset = state.inspector.asset {
                // The previous photo's details stay, dimmed and read-only, until the next one's arrive, rather than a
                // spinner at every swipe, as on the Mac.
                ViewerDetailsCards(state: state, asset: asset, editable: state.inspector.canEdit(state.currentID))
            }
        }
    }
}

/// What Immich's answer for one photo says of its tags, which the shared AssetResponse leaves out.
private struct ViewerAssetTags: Decodable {
    var tags: [ExploreTag]?
}

private struct ViewerDetailsCards: View {
    let state: ViewerState
    let asset: AssetResponse
    /// The details are the shown photo's own, not the previous one's while the next load.
    let editable: Bool
    /// The photo's tags, read as its details show.
    @State private var tags: (assetID: String, list: [ExploreTag])?
    /// Whether the photo's original is in this iPhone's cache, as viewing it zoomed in leaves it.
    @State private var onDevice: (assetID: String, found: Bool)?

    private var session: LibrarySession { state.session }
    private var exif: Exif? { asset.exifInfo }

    /// Only the owner changes a photo's details, and not while it is in the trash, as on the Mac.
    private var canChange: Bool {
        editable && !asset.isTrashed && session.user?.id != nil && asset.ownerId == session.user?.id
    }

    var body: some View {
        VStack(spacing: 14) {
            captionCard
            ratingCard
            infoCard
            placeCard
            peopleCard
            albumsCard
            tagsCard
        }
        .disabled(!editable || session.metadata.busy)
        .opacity(editable ? 1 : 0.5)
        .task(id: asset.id) { await loadExtras() }
    }

    // MARK: Caption

    @ViewBuilder
    private var captionCard: some View {
        if canChange {
            ViewerDescriptionField(state: state, asset: asset)
                .id(asset.id)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .viewerCard()
        } else if let description = exif?.description, !description.isEmpty {
            Text(description)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .viewerCard()
        }
    }

    // MARK: Rating

    /// Immich's stars, where the account has ratings on: the owner sets one to five with a tap and clears them, as on
    /// the Mac; anyone else sees them when the photo has some.
    @ViewBuilder
    private var ratingCard: some View {
        let rating = exif?.rating ?? 0
        if state.ratingsEnabled, canChange || rating > 0 {
            HStack(spacing: 4) {
                Text("Rating")
                Spacer(minLength: 8)
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        setRating(stars)
                    } label: {
                        Image(systemName: stars <= rating ? "star.fill" : "star")
                            .foregroundStyle(stars <= rating ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canChange)
                    .accessibilityLabel(stars == 1 ? Text("1 Star") : Text("\(stars) Stars"))
                    .accessibilityAddTraits(stars == rating ? .isSelected : [])
                }
                if canChange, rating > 0 {
                    Button("Clear") { setRating(nil) }
                        .buttonStyle(.borderless)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .viewerCard()
        }
    }

    /// Sets the stars, or with nil clears them, through the shared MetadataState, which reads the details again.
    private func setRating(_ stars: Int?) {
        let update = stars.map { MetadataUpdate(ids: [asset.id], rating: $0) }
            ?? MetadataUpdate(ids: [asset.id], clearRating: true)
        let session = session
        Task { _ = await session.metadata.update(update, session: session) }
    }

    // MARK: Date, file and camera

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            dateRow
                .padding(16)
            Divider()
            cameraRow
                .padding(16)
            let lens = lensLine
            let size = sizeLine
            if !lens.isEmpty || !size.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if !lens.isEmpty { Text(lens) }
                    if !size.isEmpty { Text(size) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            let specs = exposureSpecs
            if !specs.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                        if index > 0 { Divider().frame(height: 16) }
                        Text(spec)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 14)
            }
        }
        .viewerCard()
    }

    private var dateRow: some View {
        let local = onDevice?.assetID == asset.id && onDevice?.found == true
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let date = ImmichDate.parse(asset.localDateTime) {
                    Text(Self.dateLine(date))
                }
                HStack(spacing: 6) {
                    Image(systemName: local ? "iphone" : "cloud")
                        .accessibilityLabel(local ? Text("Original on This \(DeviceWords.model)") : Text("Original on the Server"))
                    Text(fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canChange {
                Button("Adjust") { state.present(.date(asset)) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var cameraRow: some View {
        let camera = cameraName
        return HStack(spacing: 8) {
            Text(camera.isEmpty ? String(localized: "No Camera Details") : camera)
                .foregroundStyle(camera.isEmpty ? .secondary : .primary)
            Spacer(minLength: 8)
            if !format.isEmpty {
                Text(format)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
            }
            if asset.livePhotoVideoId != nil {
                Image(systemName: "livephoto")
                    .font(.footnote.weight(.medium))
                    .padding(5)
                    .background(.quaternary, in: .circle)
                    .accessibilityLabel(Text("Live Photo"))
            }
        }
    }

    /// "Thursday · 19 Nov 2026 · 10.53", in the photo's own time, as Immich keeps it.
    private static func dateLine(_ date: Date) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let weekday = date.formatted(Date.FormatStyle(timeZone: utc).weekday(.wide))
        let day = date.formatted(Date.FormatStyle(timeZone: utc).day().month(.abbreviated).year())
        return [weekday, day, ImmichDate.time(date)].joined(separator: " · ")
    }

    /// The original's name without its extension, which the format's badge says, as Photos names it.
    private var fileName: String {
        let name = (asset.originalFileName as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// The make and the model, without the make twice where the model starts with it ("Canon Canon EOS R5").
    private var cameraName: String {
        let make = exif?.make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = exif?.model?.trimmingCharacters(in: .whitespaces) ?? ""
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return model.isEmpty ? make : make + " " + model
    }

    /// The file's format, from its name's extension, as Photos badges it: HEIF, JPEG, RAW for a camera's raw files.
    private var format: String {
        let fileExtension = (asset.originalFileName as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "heic", "heif", "hif": return "HEIF"
        case "jpg", "jpeg": return "JPEG"
        case "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr",
             "iiq", "erf", "kdc", "mrw", "raw":
            return "RAW"
        default: return fileExtension.uppercased()
        }
    }

    /// The lens, with the focal length and aperture it was used at unless its name already says them.
    private var lensLine: String {
        let lens = exif?.lensModel?.trimmingCharacters(in: .whitespaces) ?? ""
        var optics: [String] = []
        if let focal = exif?.focalLength { optics.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let aperture = exif?.fNumber { optics.append("ƒ\(aperture.formatted(.number.precision(.fractionLength(0...2))))") }
        let setting = optics.joined(separator: " ")
        if lens.isEmpty { return setting }
        if setting.isEmpty || lens.localizedCaseInsensitiveContains("mm") { return lens }
        return lens + " · " + setting
    }

    /// "12 MP · 4032 × 3024 · 2.1 MB", and a video's length.
    private var sizeLine: String {
        var parts: [String] = []
        if let width = exif?.exifImageWidth ?? asset.width, let height = exif?.exifImageHeight ?? asset.height {
            let megapixels = Double(width * height) / 1_000_000
            if asset.type == .image, megapixels >= 0.1 {
                parts.append("\(megapixels.formatted(.number.precision(.fractionLength(0...1)))) MP")
            }
            parts.append("\(width) × \(height)")
        }
        if let bytes = exif?.fileSizeInByte { parts.append(bytes.formatted(.byteCount(style: .file))) }
        if asset.type == .video, let duration = asset.duration?.milliseconds {
            parts.append(Duration.formatMilliseconds(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// ISO, focal length, aperture and shutter, as Photos lists them in a row.
    private var exposureSpecs: [String] {
        guard let exif else { return [] }
        var specs: [String] = []
        if let iso = exif.iso { specs.append("ISO \(iso)") }
        if let focal = exif.focalLength { specs.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let aperture = exif.fNumber { specs.append("ƒ\(aperture.formatted(.number.precision(.fractionLength(0...2))))") }
        if let exposure = exif.exposureTime, !exposure.isEmpty { specs.append("\(exposure) s") }
        return specs
    }

    // MARK: Place

    @ViewBuilder
    private var placeCard: some View {
        let place = [exif?.city, exif?.state, exif?.country].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
        if let latitude = exif?.latitude, let longitude = exif?.longitude {
            VStack(spacing: 0) {
                Button {
                    state.open(.place(latitude: latitude, longitude: longitude, title: place))
                } label: {
                    ViewerSmallMap(latitude: latitude, longitude: longitude, title: place)
                        .frame(height: 180)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                HStack(alignment: .firstTextBaseline) {
                    Text(place.isEmpty ? String(localized: "Location") : place)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if canChange {
                        Button("Adjust") { state.present(.location(asset)) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(16)
            }
            .viewerCard()
        } else if canChange {
            Button { state.present(.location(asset)) } label: {
                Label("Add a Location", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .viewerCard()
        }
    }

    // MARK: People, albums and tags

    @ViewBuilder
    private var peopleCard: some View {
        if let people = asset.people, !people.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("People")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(people) { person in
                            Button { state.open(.person(id: person.id, name: person.name)) } label: {
                                ViewerFace(person: person, pipeline: session.pipeline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(16)
            .viewerCard()
        }
    }

    @ViewBuilder
    private var albumsCard: some View {
        let albums = state.inspector.albums
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Albums")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                ForEach(albums) { album in
                    if album.id != albums.first?.id { Divider().padding(.leading, 16) }
                    Button { state.open(.album(album)) } label: {
                        HStack {
                            Label(album.albumName, systemImage: "rectangle.stack")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
            .viewerCard()
        }
    }

    @ViewBuilder
    private var tagsCard: some View {
        if let tags, tags.assetID == asset.id, !tags.list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tags")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(tags.list) { tag in
                            Button { state.open(.tag(id: tag.id, name: tag.value)) } label: {
                                Label(tag.value, systemImage: "tag")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.quaternary, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(16)
            .viewerCard()
        }
    }

    // MARK: Loading

    /// Whether the original is on this iPhone, and the photo's tags.
    private func loadExtras() async {
        let id = asset.id
        let client = session.client
        if onDevice?.assetID != id {
            let found = await Self.originalIsOnDevice(id, client: client)
            guard !Task.isCancelled else { return }
            onDevice = (id, found)
        }
        guard tags?.assetID != id else { return }
        let answer: ViewerAssetTags? = try? await client.get("assets/\(id)")
        guard !Task.isCancelled else { return }
        tags = (id, answer?.tags ?? [])
    }

    /// The original, with Immich's edits as the zoomed-in photo loads it or as it was taken, in the account's cache.
    private static func originalIsOnDevice(_ id: String, client: ImmichClient) async -> Bool {
        guard let cache = client.session.configuration.urlCache else { return false }
        let requests = [client.originalRequest(id, edited: true), client.originalRequest(id, edited: false)]
        return await Task.detached { requests.contains { cache.cachedResponse(for: $0) != nil } }.value
    }
}

private extension View {
    /// A card of the details: the width of the screen less its margins, rounded, a step lighter than the black.
    func viewerCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

/// The caption: Immich's description, typed in place and saved when the field is left, to the photo it was started
/// for, as on the Mac (DescriptionDraft). Adjust Info's Description brings the details up with it ready to type in.
private struct ViewerDescriptionField: View {
    let state: ViewerState
    let asset: AssetResponse
    @State private var draft: DescriptionDraft
    @FocusState private var focused: Bool

    init(state: ViewerState, asset: AssetResponse) {
        self.state = state
        self.asset = asset
        _draft = State(initialValue: DescriptionDraft(assetID: asset.id, saved: asset.exifInfo?.description ?? ""))
    }

    var body: some View {
        TextField("Add a Caption", text: $draft.text, axis: .vertical)
            .lineLimit(1...8)
            .focused($focused)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onDisappear { save() }
            .task(id: state.captionFocusID) {
                guard state.captionFocusID == asset.id else { return }
                // Once the details have come up.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                focused = true
                state.captionFocusID = nil
            }
            .toolbar {
                if focused {
                    ToolbarItem(placement: .keyboard) {
                        Button("Done") { focused = false }
                    }
                }
            }
    }

    private func save() {
        guard let change = draft.takeChange() else { return }
        let saved = asset.exifInfo?.description ?? ""
        let session = state.session
        Task {
            let update = MetadataUpdate(ids: [change.assetID], description: change.description)
            if !(await session.metadata.update(update, session: session)) {
                draft.saveFailed(change.description, saved: saved)
            }
        }
    }
}

/// A person's face in a photo, round, with the name below.
private struct ViewerFace: View {
    let person: AssetPerson
    let pipeline: ImagePipeline
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.circle)
            Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                .font(.caption)
                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 76)
        }
        .accessibilityElement(children: .combine)
        .task(id: person.id) { image = await pipeline.personThumbnail(person.id) }
    }
}

/// The place on a small map that does not move: a tap opens it to move around in.
private struct ViewerSmallMap: View {
    let latitude: Double
    let longitude: Double
    let title: String

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)),
            interactionModes: []) {
            Marker(title.isEmpty ? String(localized: "Photo") : title, coordinate: coordinate)
        }
        .allowsHitTesting(false)
        .id("\(latitude),\(longitude)")
        .accessibilityLabel(Text(title.isEmpty ? String(localized: "Map") : title))
    }
}

/// The photo's place on a map to move around in.
struct ViewerPlaceMap: View {
    let latitude: Double
    let longitude: Double
    let title: String

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
            Marker(title.isEmpty ? String(localized: "Photo") : title, coordinate: coordinate)
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .navigationTitle(title.isEmpty ? String(localized: "Location") : title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .bottom)
    }
}
