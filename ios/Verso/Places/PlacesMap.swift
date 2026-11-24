// The map of the photos, as Photos' Places shows it on iOS: a photo of each cluster on the map, with how many, the
// clusters made again as the map moves (`mapClusters`, the shared core's, as on the Mac and Linux), and a tap that
// opens the photos there. The map takes the taps itself, as its selection: a pin is a picture that touches pass
// through, so a pinch or a pan that starts on a pin moves the map, as anywhere else, and a tap selects the pin's
// cluster, which opens its photos and is cleared again so the same pin opens them on the next tap. The filters are
// Immich's map settings (MapSettingsModal.svelte in Immich's web app), as on the Mac: favorites only, archived,
// partners' photos and a date range. Under the bars the map runs on behind the soft edge every page has, drawn by a
// scroll view that holds it and does not scroll (ARCHITECTURE.md, "The map's top on the iPhone and the iPad").

import MapKit
import SwiftUI
import VersoCore

/// The map's filters, kept while Places shows.
struct PlacesMapFilters: Equatable {
    var favorites = false
    var archived = false
    var partners = true
    var range = PlacesMapRange.all
    /// When a "past" range starts, fixed when it is chosen so the map's queries stay the same.
    var rangeStart: Date?

    var isFiltered: Bool { favorites || archived || !partners || range != .all }

    mutating func select(_ newRange: PlacesMapRange) {
        range = newRange
        rangeStart = newRange.start(before: .now)
    }

    /// The photos in a cluster's box, with these filters, for the grid.
    func query(bbox: String) -> ExploreMapQuery {
        ExploreMapQuery(bbox: bbox, favorites: favorites, archived: archived, partners: partners, after: rangeStart, before: nil)
    }
}

/// The Immich web app's map date ranges.
enum PlacesMapRange: String, CaseIterable, Identifiable {
    case all, past3Years, pastYear, past30Days, past7Days, past24Hours
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All Time"
        case .past3Years: "Past 3 Years"
        case .pastYear: "Past Year"
        case .past30Days: "Past 30 Days"
        case .past7Days: "Past 7 Days"
        case .past24Hours: "Past 24 Hours"
        }
    }

    func start(before now: Date) -> Date? {
        let calendar = Calendar.current
        return switch self {
        case .all: nil
        case .past24Hours: calendar.date(byAdding: .hour, value: -24, to: now)
        case .past7Days: calendar.date(byAdding: .day, value: -7, to: now)
        case .past30Days: calendar.date(byAdding: .day, value: -30, to: now)
        case .pastYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .past3Years: calendar.date(byAdding: .year, value: -3, to: now)
        }
    }
}

struct PlacesMap: View {
    let session: LibrarySession
    let filters: PlacesMapFilters
    /// Opens the photos of a cluster, with a title for their page.
    let open: (_ query: ExploreMapQuery, _ title: String) -> Void
    @State private var markers: [ExploreMarker] = []
    /// Each marker's city, by its photo, for the title of a cluster's photos.
    @State private var cities: [String: String] = [:]
    @State private var clusters: [MapCluster] = []
    /// The cluster a tap on its pin selected, by its id, until its photos open.
    @State private var chosenCluster: String?
    @State private var region = MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                                   span: .init(latitudeDelta: 180, longitudeDelta: 360))
    @State private var position = MapCameraPosition.automatic
    @State private var fittedMarkers = false
    @State private var loaded = false
    @State private var error: String?
    @State private var clusterTask: Task<Void, Never>?
    /// What the markers were read for, so coming back from a cluster's photos keeps them.
    @State private var loadedKey: String?

    /// The map in a scroll view that does not scroll, so the bars' edge effects are the scroll view's, soft at the top as
    /// on every page: a map that is the page's content draws its own under the bars, in the automatic style, which is a
    /// hard edge under a pale band on iOS 27, and takes no style from SwiftUI. The map runs on under the bars, which are
    /// its safe area, so its fit, its compass and its legal notice stay clear of them.
    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ScrollView {
                map
                    .safeAreaPadding(insets)
                    .frame(width: proxy.size.width + insets.leading + insets.trailing,
                           height: proxy.size.height + insets.top + insets.bottom)
            }
            .scrollDisabled(true)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .ignoresSafeArea()
        }
    }

    private var map: some View {
        let pipeline = session.pipeline
        return Map(position: $position, selection: $chosenCluster) {
            ForEach(clusters) { cluster in
                Annotation(String(localized: "\(cluster.assets.count) photos"),
                           coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)) {
                    PlacesMapPin(cluster: cluster, pipeline: pipeline) { select(cluster) }
                }
                .annotationTitles(.hidden)
                .tag(cluster.id)
            }
        }
        .onChange(of: chosenCluster) { _, id in
            guard let id else { return }
            chosenCluster = nil
            if let cluster = clusters.first(where: { $0.id == id }) { select(cluster) }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            recluster()
        }
        .overlay {
            if let error {
                ContentUnavailableView {
                    Label("Can't Load the Map", systemImage: "map")
                } description: {
                    Text(error)
                }
                .background(.background)
            } else if loaded && markers.isEmpty {
                ContentUnavailableView("No Photos on the Map", systemImage: "map",
                                       description: Text(filters.isFiltered ? "No photos with a location match the filters."
                                                                            : "Photos with a location appear here."))
                    .background(.background.opacity(0.85))
            }
        }
        .task(id: loadKey) {
            guard loadKey != loadedKey else { return }
            await load()
        }
        .onDisappear { clusterTask?.cancel() }
    }

    private var loadKey: String { "\(String(describing: filters))-\(session.services.reconnections)" }

    private func load() async {
        let key = loadKey
        do {
            let found = try await session.client.exploreMarkers(favorites: filters.favorites, archived: filters.archived,
                                                                partners: filters.partners, after: filters.rangeStart, before: nil)
            guard !Task.isCancelled else { return }
            markers = found
            loadedKey = key
            cities = Dictionary(found.compactMap { marker in marker.city.flatMap { $0.isEmpty ? nil : (marker.id, $0) } }) { first, _ in first }
            loaded = true
            error = nil
            // The markers are fitted once, when they first come; fitting the clusters would feed the camera's changes
            // back into the clustering.
            if !fittedMarkers, let bounds = ExploreMapFit.initialBounds(found) {
                fittedMarkers = true
                if !position.positionedByUser {
                    region = MKCoordinateRegion(bounds)
                    position = .rect(bounds)
                }
            }
            recluster()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    /// Opens a cluster's photos, titled with the city most of them were taken in, and how many other places.
    private func select(_ cluster: MapCluster) {
        var counts: [String: Int] = [:]
        for id in cluster.assets { if let city = cities[id] { counts[city, default: 0] += 1 } }
        let ranked = counts.sorted { first, second in
            first.value != second.value ? first.value > second.value : first.key < second.key
        }
        let title: String
        if let first = ranked.first {
            title = ranked.count == 1 ? first.key : String(localized: "\(first.key) and \(ranked.count - 1) More")
        } else {
            title = String(localized: "Photos on the Map")
        }
        open(filters.query(bbox: cluster.bbox), title)
    }

    /// Groups the markers in view into clusters, off the main thread; a cluster that did not change keeps its pin.
    private func recluster() {
        clusterTask?.cancel()
        let markers = markers
        let latitude = region.center.latitude, longitude = region.center.longitude
        let latitudeSpan = region.span.latitudeDelta, longitudeSpan = region.span.longitudeDelta
        clusterTask = Task {
            let made = await Task.detached {
                let photos = markers.map { MapPhoto(id: $0.id, latitude: $0.lat, longitude: $0.lon) }
                return mapClusters(photos: photos, latitude: latitude, longitude: longitude, latitudeSpan: latitudeSpan,
                                   longitudeSpan: longitudeSpan)
            }.value
            if !Task.isCancelled, clusters != made { clusters = made }
        }
    }
}

/// A cluster on the map: one of its photos in a rounded square with a white edge, and how many in a badge, as Photos
/// draws its places. MapKit hosts each pin on its own, so it is given everything it uses. The picture takes no touches:
/// a tap on it is the map's, which selects the cluster (PlacesMap), and a pinch or pan on it moves the map. VoiceOver
/// opens the photos with the pin's own action.
struct PlacesMapPin: View {
    let cluster: MapCluster
    let pipeline: ImagePipeline
    let select: () -> Void

    var body: some View {
        ExploreThumbnail(pipeline: pipeline, assetID: cluster.assets.first)
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if cluster.assets.count > 1 {
                    Text(cluster.assets.count, format: .number)
                        .font(.caption2.bold())
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cluster.assets.count == 1 ? Text("1 photo") : Text("\(cluster.assets.count) photos"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, select)
    }
}
