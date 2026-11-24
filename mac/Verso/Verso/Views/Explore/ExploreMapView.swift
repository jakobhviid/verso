import MapKit
import SwiftUI
import VersoCore

/// The map of the photos: clusters made again as the map moves, by the shared core (`mapClusters`), as on Linux and
/// the iPhone, and fitted to the photos once with MapKit (`ExploreMapFit`).
struct ExploreMapView: View {
    @Environment(LibrarySession.self) private var session
    @State private var markers: [ExploreMarker] = []
    @State private var clusters: [MapCluster] = []
    @State private var region = MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 180, longitudeDelta: 360))
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 180, longitudeDelta: 360)))
    @State private var didFitMarkers = false
    @State private var filters = ExploreMapFilters()
    @State private var error: String?
    @Environment(PageNavigation.self) private var navigation
    @State private var clusterTask: Task<Void, Never>?
    private var filterKey: String { "\(filters.favorites)-\(filters.archived)-\(filters.partners)-\(String(describing: filters.afterDay))-\(String(describing: filters.beforeDay))" }
    var body: some View {
        let filters = filters
        let session = session
        let pipeline = session.pipeline
        return Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation(String(localized: "\(cluster.assets.count) photos"), coordinate: .init(latitude: cluster.latitude, longitude: cluster.longitude)) {
                    ExploreMapAnnotation(assets: cluster.assets, pipeline: pipeline) { open(cluster) }
                        .environment(session)
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in region = context.region; recluster() }
        // Not a scroll view: under the toolbar a light blur with no edge, as the pages that scroll have, rather than the
        // hard band MapKit's own edge effect draws (ARCHITECTURE.md, "Verso on the Mac").
        .modifier(MapUnderBars())
        .pageToolbar("map") {
            ToolbarItem(id: "dateRange", placement: .principal) { ExploreMapRangePicker(filters: filters) }
            ToolbarItem(id: "mapFilters") { ExploreMapFiltersButton(filters: filters) }
        }
        .task(id: filterKey) {
            do {
                let loaded = try await session.client.exploreMarkers(favorites: filters.favorites, archived: filters.archived, partners: filters.partners,
                    after: filters.afterDay, before: filters.beforeDay)
                guard !Task.isCancelled else { return }
                markers = loaded
                error = nil
                if !didFitMarkers, let bounds = ExploreMapFit.initialBounds(loaded) {
                    didFitMarkers = true
                    // Fit the source markers once; fitting clusters feeds camera changes back into clustering.
                    if !position.positionedByUser {
                        region = MKCoordinateRegion(bounds)
                        position = .rect(bounds)
                    }
                }
                recluster()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .overlay { if let error { ContentUnavailableView("Map Unavailable", systemImage: "map", description: Text(error)) } }
        .onDisappear { clusterTask?.cancel() }
    }
    private func open(_ cluster: MapCluster) {
        navigation.open(GridRoute(source: .explore(.map(ExploreMapQuery(bbox: cluster.bbox, favorites: filters.favorites, archived: filters.archived,
            partners: filters.partners, after: filters.afterDay, before: filters.beforeDay))), title: String(localized: "Map Photos")))
    }

    private func recluster() {
        clusterTask?.cancel()
        let markers = markers
        let latitude = region.center.latitude, longitude = region.center.longitude
        let latSpan = region.span.latitudeDelta, lonSpan = region.span.longitudeDelta
        clusterTask = Task {
            let result = await Task.detached {
                let photos = markers.map { MapPhoto(id: $0.id, latitude: $0.lat, longitude: $0.lon) }
                return mapClusters(photos: photos, latitude: latitude, longitude: longitude, latitudeSpan: latSpan, longitudeSpan: lonSpan)
            }.value
            if !Task.isCancelled, clusters != result { clusters = result }
        }
    }
}

/// The map in the window's safe area, its edges carried on under the toolbar and the sidebar as a mirrored, blurred copy
/// (macOS 26's background extension), as content that does not scroll goes under the bars: MapKit's own edge effect over
/// its top, the hard style, is clipped away with what lies outside, and MapKit keeps its controls and its Legal label in
/// the safe area. On macOS 15 the map runs under the toolbar's own background.
private struct MapUnderBars: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

/// The Immich web app's map date ranges (MapSettingsModal.svelte), plus a custom range.
enum ExploreMapDateRange: String, CaseIterable, Identifiable {
    case all, past24Hours, past7Days, past30Days, pastYear, past3Years, custom
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All Time"
        case .past24Hours: "Past 24 Hours"
        case .past7Days: "Past 7 Days"
        case .past30Days: "Past 30 Days"
        case .pastYear: "Past Year"
        case .past3Years: "Past 3 Years"
        case .custom: "Custom Range"
        }
    }

    func start(before now: Date) -> Date? {
        let calendar = Calendar.current
        return switch self {
        case .all, .custom: nil
        case .past24Hours: calendar.date(byAdding: .hour, value: -24, to: now)
        case .past7Days: calendar.date(byAdding: .day, value: -7, to: now)
        case .past30Days: calendar.date(byAdding: .day, value: -30, to: now)
        case .pastYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .past3Years: calendar.date(byAdding: .year, value: -3, to: now)
        }
    }
}

@MainActor @Observable
final class ExploreMapFilters {
    var favorites = false
    var archived = false
    var partners = true
    private(set) var dateRange = ExploreMapDateRange.all
    /// When a "past" range starts, fixed when it is chosen so the map's queries stay the same.
    private(set) var rangeStart: Date?
    var after = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var before = Date()

    func select(_ range: ExploreMapDateRange) {
        dateRange = range
        rangeStart = range.start(before: Date())
    }

    var afterDay: Date? { dateRange == .custom ? Calendar.current.startOfDay(for: after) : rangeStart }
    var beforeDay: Date? { dateRange == .custom ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: before)) : nil }
}

/// Takes only a stable reference: on macOS 15 a toolbar item whose inputs change is rebuilt,
/// which dismisses its popover after every filter change.
/// The date ranges in the middle of the toolbar, as Photos' Years, Months and All Photos; a custom range is in the
/// filters.
private struct ExploreMapRangePicker: View {
    let filters: ExploreMapFilters
    var body: some View {
        ToolbarModePicker(selection: Binding(get: { filters.dateRange }, set: { filters.select($0) }),
                          options: [.all, .past3Years, .pastYear, .past30Days, .past7Days, .past24Hours]) { $0.title }
    }
}

private struct ExploreMapFiltersButton: View {
    let filters: ExploreMapFilters
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Label("Map Filters", systemImage: "line.3.horizontal.decrease") }
            .popover(isPresented: $showing) { ExploreMapFiltersForm(filters: filters) }
    }
}

private struct ExploreMapFiltersForm: View {
    @Bindable var filters: ExploreMapFilters
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Favorites Only", isOn: $filters.favorites)
            Toggle("Include Archived", isOn: $filters.archived)
            Toggle("Include Partners", isOn: $filters.partners)
            Toggle("Custom Range", isOn: Binding(get: { filters.dateRange == .custom }, set: { filters.select($0 ? .custom : .all) }))
            if filters.dateRange == .custom {
                DatePicker("From", selection: $filters.after, in: ...filters.before, displayedComponents: .date)
                DatePicker("Through", selection: $filters.before, in: filters.after..., displayedComponents: .date)
            }
        }
        .padding().frame(width: 300)
        .animation(.smooth(duration: 0.25), value: filters.dateRange)
    }
}
