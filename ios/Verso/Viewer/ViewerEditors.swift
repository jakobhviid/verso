// The viewer's sheets for changing a photo on iOS: Adjust Date and Time and Adjust Location, from the More menu or the
// details, and the stack's sheet from its badge (ViewerStackSheet); Add To's are the menu of photo actions' own
// (PhotoActionSheets). The date and the place are written through the shared MetadataState, as the Mac's MetadataSheet
// writes them, so the grids and the details follow. Adjust Location's search sends the words typed to Apple's maps,
// once the person submits them, never the photo's place.

import MapKit
import SwiftUI

/// The sheet for a ViewerPresentation.
struct ViewerPresentationSheet: View {
    let state: ViewerState
    let presentation: ViewerPresentation

    var body: some View {
        let session = state.session
        switch presentation {
        case .date(let asset): ViewerDateEditor(session: session, asset: asset)
        case .location(let asset): ViewerLocationEditor(session: session, asset: asset)
        case .stack(let id): ViewerStackSheet(state: state, stackID: id)
        }
    }
}

/// Why a change to a photo's details failed, shown where it was made (MetadataState.error).
struct ViewerMetadataErrorAlert: ViewModifier {
    let metadata: MetadataState
    /// False while a sheet over this view shows the error instead.
    var isActive = true

    func body(content: Content) -> some View {
        content.alert("Can't Save the Change", isPresented: Binding(get: { isActive && metadata.error != nil },
                                                                    set: { shown in if !shown { metadata.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(metadata.error ?? "")
        }
    }
}

// MARK: Date and time

/// The photo's date and time, shown and set in its own time zone. Changing the zone keeps the time on the clock, as on
/// the Mac.
struct ViewerDateEditor: View {
    let session: LibrarySession
    let asset: AssetResponse
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var zone = "UTC"
    @State private var saving = false

    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? .gmt }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date and Time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, timeZone)
                }
                Section {
                    NavigationLink {
                        ViewerTimeZoneList(selection: zone, choose: changeTimeZone)
                    } label: {
                        LabeledContent("Time Zone", value: zone)
                    }
                } footer: {
                    Text("UTC offset: \(Self.offset(timeZone, at: date))")
                }
            }
            .navigationTitle("Adjust Date and Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adjust", role: .confirm) { save() }
                        .disabled(saving)
                }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .modifier(ViewerMetadataErrorAlert(metadata: session.metadata))
        .onAppear {
            if let name = asset.exifInfo?.timeZone, TimeZone(identifier: name) != nil { zone = name }
            date = ImmichDate.parse(asset.exifInfo?.dateTimeOriginal ?? asset.fileCreatedAt) ?? Date()
        }
    }

    /// "+02:00" for a zone two hours ahead of UTC at that date.
    private static func offset(_ zone: TimeZone, at date: Date) -> String {
        let minutes = zone.secondsFromGMT(for: date) / 60
        let sign = minutes < 0 ? "-" : "+"
        return String(format: "%@%02d:%02d", sign, abs(minutes) / 60, abs(minutes) % 60)
    }

    private func changeTimeZone(_ name: String) {
        guard let new = TimeZone(identifier: name) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        calendar.timeZone = new
        if let adjusted = calendar.date(from: components) { date = adjusted }
        zone = name
    }

    private func save() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        let update = MetadataUpdate(ids: [asset.id], dateTimeOriginal: formatter.string(from: date), timeZone: zone)
        saving = true
        Task {
            if await session.metadata.update(update, session: session) { dismiss() }
            saving = false
        }
    }
}

/// Every time zone, searchable by name.
private struct ViewerTimeZoneList: View {
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

// MARK: Location

/// The photo's place: a tap on the map puts the pin there, and a search finds a place by name.
struct ViewerLocationEditor: View {
    let session: LibrarySession
    let asset: AssetResponse
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
            if let latitude = asset.exifInfo?.latitude, let longitude = asset.exifInfo?.longitude {
                let known = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                coordinate = known
                position = .region(MKCoordinateRegion(center: known, latitudinalMeters: 5000, longitudinalMeters: 5000))
            }
        }
    }

    /// Fixed decimal points, as in Immich, so the coordinates read the same in every language.
    private var hint: String {
        if let searchError { return searchError }
        guard let coordinate else { return String(localized: "Tap the map to place the pin.") }
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
            let update = MetadataUpdate(ids: [asset.id], latitude: coordinate.latitude, longitude: coordinate.longitude)
            if await session.metadata.update(update, session: session) { dismiss() }
            saving = false
        }
    }
}
