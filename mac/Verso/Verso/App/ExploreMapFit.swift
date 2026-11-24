import Foundation
import MapKit

/// Fitting the map to its photos when they first come, with MapKit's own geometry. The clusters it shows come from the
/// shared core (`mapClusters`, verso-core's `map` through the bridge), as on Linux.
enum ExploreMapFit {
    /// The area that holds every photo with a place, with room for their pins; nil without any.
    static func initialBounds(_ markers: [ExploreMarker]) -> MKMapRect? {
        let points = markers.filter { $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180 }
            // Mercator cannot represent the poles; fit their nearest visible latitude instead.
            .map { MKMapPoint(CLLocationCoordinate2D(latitude: min(85, max(-85, $0.lat)), longitude: $0.lon)) }
        guard let first = points.first else { return nil }
        let bounds = points.dropFirst().reduce(MKMapRect(x: first.x, y: first.y, width: 0, height: 0)) {
            $0.union(MKMapRect(x: $1.x, y: $1.y, width: 0, height: 0))
        }
        // Leave room for thumbnails, with a useful minimum area for a single location.
        let padded = bounds.insetBy(dx: -max(bounds.width * 0.15, 10_000), dy: -max(bounds.height * 0.15, 10_000))
            .intersection(.world)
        guard !padded.isNull, !padded.isEmpty, padded.origin.x.isFinite, padded.origin.y.isFinite,
              padded.width.isFinite, padded.height.isFinite else { return nil }
        return padded
    }
}
