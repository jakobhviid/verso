// The sheets the photo menu's actions open on iOS (PhotoActionsMenu): Add To's albums, of one's own or shared with
// people (AddToAlbumSheet), a new album or a new shared album, whose sharing then opens in the same sheet
// (AlbumSharingSheet), as the Mac opens an album's sharing; Immich's tags; and the photos' date and time, place and
// description. For one photo the date and the place are the viewer's own editors (ViewerDateEditor,
// ViewerLocationEditor); for several, Adjust Date & Time moves them all by the same amount, as the Mac's metadata sheet
// can (MetadataUpdate's `dateTimeRelative`), from the earliest photo's date as the person sets it, and Adjust Location
// gives them all one place. Every change goes through the session's AlbumsActions, MetadataState and Immich client, as
// on the Mac, so the grids and the details follow. Adjust Location's search sends the words typed to Apple's maps once
// the person submits them, never the photos' places.

import MapKit
import SwiftUI

/// A sheet over a page's photos, for a menu's action.
struct PhotoActionSheet: Identifiable {
    enum Kind {
        case addToAlbum(shared: Bool)
        case newAlbum(shared: Bool)
        case tag, date, location, description
    }

    let id = UUID()
    let kind: Kind
    /// Immich's photos it is for; Adjust Date & Time's earliest first.
    let ids: [String]
}

/// The sheet for a PhotoActionSheet. `onDone` is told once the photos went into an album or a tag, or were changed,
/// with a word to say about it, if any.
struct PhotoActionSheetView: View {
    let session: LibrarySession
    let sheet: PhotoActionSheet
    let onDone: (String?) -> Void

    var body: some View {
        switch sheet.kind {
        case .addToAlbum(let shared):
            AddToAlbumSheet(session: session, ids: sheet.ids, albums: shared ? .shared : .own) { name in
                onDone(PhotoActionWords.added(sheet.ids.count, to: name))
            }
        case .newAlbum(let shared):
            PhotoNewAlbumSheet(session: session, ids: sheet.ids, shared: shared) { name in
                onDone(PhotoActionWords.added(sheet.ids.count, to: name))
            }
        case .tag:
            PhotoTagPicker(session: session, ids: sheet.ids) { name in onDone(PhotoActionWords.tagged(sheet.ids.count, name)) }
        case .date, .location, .description:
            PhotoDetailsEditor(session: session, kind: sheet.kind, ids: sheet.ids) { onDone(nil) }
        }
    }
}

/// What the grid says once photos went somewhere.
enum PhotoActionWords {
    static func added(_ count: Int, to album: String) -> String {
        count == 1 ? String(localized: "Added to “\(album)”") : String(localized: "Added \(count) Items to “\(album)”")
    }

    static func tagged(_ count: Int, _ tag: String) -> String {
        count == 1 ? String(localized: "Tagged “\(tag)”") : String(localized: "Tagged \(count) Items “\(tag)”")
    }
}

// MARK: New album

/// Add To's New Album and New Shared Album: a name and a description, and the album is made with the photos in it; a
/// shared one then shows its sharing, people and links, in the same sheet.
struct PhotoNewAlbumSheet: View {
    let session: LibrarySession
    let ids: [String]
    let shared: Bool
    /// Told the album's name once it is made with the photos.
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var busy = false
    @State private var errorMessage: String?
    /// The shared album made, whose sharing shows.
    @State private var sharingAlbumID: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let sharingAlbumID {
            AlbumSharingSheet(session: session, albumID: sharingAlbumID)
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text(footer)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(shared ? "New Shared Album" : "New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(shared ? "Next" : "Create", systemImage: shared ? "chevron.forward" : "checkmark",
                           role: .confirm, action: create)
                        .disabled(busy || trimmedName.isEmpty)
                }
            }
            .disabled(busy)
        }
        .interactiveDismissDisabled(busy)
        .onAppear { nameFocused = true }
    }

    private var footer: String {
        let photos = ids.count == 1 ? String(localized: "The item goes into the new album.")
            : String(localized: "The \(ids.count) items go into the new album.")
        return shared ? photos + " " + String(localized: "Then choose whom to share it with.") : photos
    }

    private func create() {
        let title = trimmedName
        guard !title.isEmpty, !busy else { return }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        errorMessage = nil
        Task {
            do {
                let album = try await session.client.createAlbum(name: title, description: text.isEmpty ? nil : text, assetIDs: ids)
                await session.reloadAlbums()
                onCreated(title)
                if shared { sharingAlbumID = album.id } else { dismiss() }
            } catch {
                session.handle(error)
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: Tags

/// Immich's tags, searchable by name; a tap tags the photos, and a name no tag has makes one.
struct PhotoTagPicker: View {
    let session: LibrarySession
    let ids: [String]
    /// Told the tag's name once the photos have it.
    let onTagged: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var words: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var tags: [ExploreTag] {
        words.isEmpty ? session.exploreTags : session.exploreTags.filter { $0.value.localizedStandardContains(words) }
    }

    var body: some View {
        let tags = tags
        NavigationStack {
            List {
                if !words.isEmpty, !session.exploreTags.contains(where: { $0.value.caseInsensitiveCompare(words) == .orderedSame }) {
                    Section {
                        Button("New Tag “\(words)”", systemImage: "plus") { create(words) }
                    }
                }
                Section {
                    ForEach(tags) { tag in
                        Button { apply(tag) } label: {
                            Label(tag.value, systemImage: "tag")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .overlay {
                if tags.isEmpty, words.isEmpty, !busy { ContentUnavailableView("No Tags", systemImage: "tag") }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or New Tag")
            .navigationTitle(ids.count == 1 ? String(localized: "Add a Tag") : String(localized: "Tag \(ids.count) Items"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                if busy {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .disabled(busy)
            .alert("Can't Tag the Items", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await session.loadExploreTags(refresh: true) }
    }

    private func apply(_ tag: ExploreTag) {
        guard !busy else { return }
        busy = true
        Task {
            await give(tag)
            busy = false
        }
    }

    /// A tag of the name typed, made and then given to the photos.
    private func create(_ name: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await session.client.exploreCreateTag(name)
                await session.loadExploreTags(refresh: true)
                if let made = session.exploreTags.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame }) {
                    await give(made)
                }
            } catch {
                session.handle(error)
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    /// The tag given to the photos, and the sheet closed.
    private func give(_ tag: ExploreTag) async {
        do {
            try await session.client.exploreTagAssets(ids, tag: tag.id, remove: false)
            session.invalidateGrids()
            onTagged(tag.value)
            dismiss()
        } catch {
            session.handle(error)
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: Date, place and description

/// Adjust Info's editors, once the photo they start from has loaded: the first, which for the date is the earliest.
private struct PhotoDetailsEditor: View {
    let session: LibrarySession
    let kind: PhotoActionSheet.Kind
    let ids: [String]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var asset: AssetResponse?
    @State private var failure: String?

    var body: some View {
        Group {
            if let asset {
                editor(asset)
            } else {
                NavigationStack {
                    Group {
                        if let failure {
                            ContentUnavailableView("Can't Load the Item", systemImage: "exclamationmark.triangle",
                                                   description: Text(failure))
                        } else {
                            ProgressView()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        }
                    }
                }
            }
        }
        .task {
            guard let first = ids.first else { return }
            do {
                asset = try await session.client.asset(first)
            } catch {
                session.handle(error)
                failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func editor(_ asset: AssetResponse) -> some View {
        switch kind {
        case .date:
            if ids.count == 1 {
                ViewerDateEditor(session: session, asset: asset)
            } else {
                PhotoDateShiftEditor(session: session, ids: ids, reference: asset, onChanged: onChanged)
            }
        case .location:
            if ids.count == 1 {
                ViewerLocationEditor(session: session, asset: asset)
            } else {
                PhotoLocationEditor(session: session, ids: ids, start: asset, onChanged: onChanged)
            }
        default:
            PhotoDescriptionEditor(session: session, asset: asset)
        }
    }
}

/// Adjust Date & Time for several photos: the earliest one's date and time, in its own time zone, set as the person
/// wants it, and every photo moved by the same amount, as Photos adjusts several; a time zone chosen goes to them all.
struct PhotoDateShiftEditor: View {
    let session: LibrarySession
    let ids: [String]
    /// The earliest of the photos, whose date the picker shows.
    let reference: AssetResponse
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var original = Date()
    @State private var zone = "UTC"
    @State private var zoneTouched = false
    @State private var saving = false

    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? .gmt }
    /// How far every photo moves, in whole minutes, as Immich takes it: the picker shows and sets minutes, and leaves
    /// out the seconds the photo's time has.
    private var minutes: Int {
        Int(floor(date.timeIntervalSinceReferenceDate / 60) - floor(original.timeIntervalSinceReferenceDate / 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date and Time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, timeZone)
                } footer: {
                    Text(shiftWords)
                }
                Section {
                    NavigationLink {
                        PhotoTimeZoneList(selection: zone, choose: changeTimeZone)
                    } label: {
                        LabeledContent("Time Zone", value: zone.replacingOccurrences(of: "_", with: " "))
                    }
                } footer: {
                    Text(zoneTouched ? String(localized: "Every item takes this time zone.")
                        : String(localized: "Each item keeps its own time zone."))
                }
            }
            .navigationTitle("Adjust Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adjust", role: .confirm) { save() }
                        .disabled(saving || (minutes == 0 && !zoneTouched))
                }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .modifier(ViewerMetadataErrorAlert(metadata: session.metadata))
        .onAppear {
            if let name = reference.exifInfo?.timeZone, TimeZone(identifier: name) != nil { zone = name }
            original = ImmichDate.parse(reference.exifInfo?.dateTimeOriginal ?? reference.fileCreatedAt) ?? Date()
            date = original
        }
    }

    /// "The 3 items move 2 days, 3 hours later.", as the picker now stands.
    private var shiftWords: String {
        let count = ids.count
        let minutes = minutes
        guard minutes != 0 else { return String(localized: "The earliest of the \(count) items is shown. The others move by as much as it does.") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.year, .day, .hour, .minute]
        formatter.maximumUnitCount = 2
        let amount = formatter.string(from: TimeInterval(abs(minutes) * 60)) ?? ""
        return minutes > 0 ? String(localized: "The \(count) items move \(amount) later.")
            : String(localized: "The \(count) items move \(amount) earlier.")
    }

    /// A new zone keeps the time on the clock, as the viewer's editor and the Mac's do.
    private func changeTimeZone(_ name: String) {
        guard let new = TimeZone(identifier: name) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        calendar.timeZone = new
        if let adjusted = calendar.date(from: components) { date = adjusted }
        zone = name
        zoneTouched = true
    }

    private func save() {
        let update = MetadataUpdate(ids: ids, dateTimeRelative: minutes, timeZone: zoneTouched ? zone : nil)
        saving = true
        Task {
            if await session.metadata.update(update, session: session) {
                onChanged()
                dismiss()
            }
            saving = false
        }
    }
}

/// Every time zone, searchable by name.
private struct PhotoTimeZoneList: View {
    let selection: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return all }
        return all.filter { $0.replacingOccurrences(of: "_", with: " ").localizedStandardContains(words) }
    }

    var body: some View {
        List(zones, id: \.self) { name in
            Button {
                choose(name)
                dismiss()
            } label: {
                HStack {
                    Text(name.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.primary)
                    Spacer()
                    if name == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search Time Zones")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Adjust Location for several photos: one place for them all, put on the map with a tap or found by name.
struct PhotoLocationEditor: View {
    let session: LibrarySession
    let ids: [String]
    /// The first photo, whose place the map opens on, if it has one.
    let start: AssetResponse
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position = MapCameraPosition.automatic
    @State private var query = ""
    @State private var searching = false
    @State private var results: [MKMapItem] = []
    @State private var searchError: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if let coordinate { Marker("Location", coordinate: coordinate) }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { point in
                    guard let value = proxy.convert(point, from: .local) else { return }
                    let normalized = metadataCoordinate(latitude: value.latitude, longitude: value.longitude)
                    coordinate = CLLocationCoordinate2D(latitude: normalized.latitude, longitude: normalized.longitude)
                }
            }
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a Place")
            .searchSuggestions {
                ForEach(results.indices, id: \.self) { index in
                    Button { choose(results[index]) } label: {
                        VStack(alignment: .leading) {
                            Text(results[index].name ?? String(localized: "Place"))
                            if let address = results[index].address?.shortAddress {
                                Text(address)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .onSubmit(of: .search) { search() }
            .navigationTitle("Adjust Location")
            .navigationSubtitle(hint)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Assign", role: .confirm) { save() }
                        .disabled(coordinate == nil || saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .modifier(ViewerMetadataErrorAlert(metadata: session.metadata))
        .onAppear {
            if let latitude = start.exifInfo?.latitude, let longitude = start.exifInfo?.longitude {
                let known = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                position = .region(MKCoordinateRegion(center: known, latitudinalMeters: 50000, longitudinalMeters: 50000))
            }
        }
    }

    /// Fixed decimal points, as in Immich, so the coordinates read the same in every language.
    private var hint: String {
        if let searchError { return searchError }
        guard let coordinate else { return String(localized: "Tap the map to place the pin for \(ids.count) items.") }
        return String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = words
        Task {
            do {
                results = try await MKLocalSearch(request: request).start().mapItems
                if results.isEmpty { searchError = String(localized: "No place named “\(words)”.") }
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    private func choose(_ place: MKMapItem) {
        let found = place.location.coordinate
        coordinate = found
        position = .region(MKCoordinateRegion(center: found, latitudinalMeters: 5000, longitudinalMeters: 5000))
        searching = false
        results = []
    }

    private func save() {
        guard let coordinate else { return }
        saving = true
        Task {
            let update = MetadataUpdate(ids: ids, latitude: coordinate.latitude, longitude: coordinate.longitude)
            if await session.metadata.update(update, session: session) {
                onChanged()
                dismiss()
            }
            saving = false
        }
    }
}

/// Adjust Description for one photo from a grid, where the viewer writes it in its details' caption: Immich's
/// description, written in a field of its own.
struct PhotoDescriptionEditor: View {
    let session: LibrarySession
    let asset: AssetResponse
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Add a Description", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                    .focused($focused)
            }
            .navigationTitle("Adjust Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) { save() }
                        .disabled(saving || text == (asset.exifInfo?.description ?? ""))
                }
            }
            .disabled(saving)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
        .modifier(ViewerMetadataErrorAlert(metadata: session.metadata))
        .onAppear {
            text = asset.exifInfo?.description ?? ""
            focused = true
        }
    }

    private func save() {
        saving = true
        let update = MetadataUpdate(ids: [asset.id], description: text.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            if await session.metadata.update(update, session: session) { dismiss() }
            saving = false
        }
    }
}
