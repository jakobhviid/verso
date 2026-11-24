//! The map's arithmetic on Linux, where libshumate shows OpenStreetMap's Web Mercator tiles: the degrees a view spans,
//! the place at a point of it, and where the photos are, to fit the map to them. The clusters are the core's
//! (`verso_core::map`), as on the Mac and the iPhone.

use immich_api::map::MapMarker;
use verso_core::map::on_the_map;

/// The degrees a web map shows (OpenStreetMap's Web Mercator, 256 pixel tiles): its height in latitude, around
/// `latitude`, and its width in longitude, for a view of `width` by `height` pixels at `zoom`.
pub fn view_spans(latitude: f64, zoom: f64, width: f64, height: f64) -> (f64, f64) {
    let world = 256.0 * 2f64.powf(zoom);
    let longitude_span = (width * 360.0 / world).min(360.0);
    let latitude = latitude.clamp(-85.05, 85.05).to_radians();
    let centre = (1.0 - (latitude.tan() + 1.0 / latitude.cos()).ln() / std::f64::consts::PI) / 2.0 * world;
    let at = |y: f64| (std::f64::consts::PI * (1.0 - 2.0 * y.clamp(0.0, world) / world)).sinh().atan().to_degrees();
    let latitude_span = (at(centre - height / 2.0) - at(centre + height / 2.0)).abs();
    (latitude_span, longitude_span)
}

/// The place `dx` and `dy` pixels from the middle of a web map centred on (`latitude`, `longitude`) at `zoom`.
pub fn location_at(latitude: f64, longitude: f64, zoom: f64, dx: f64, dy: f64) -> (f64, f64) {
    let world = 256.0 * 2f64.powf(zoom);
    let latitude = latitude.clamp(-85.05, 85.05).to_radians();
    let centre_y = (1.0 - (latitude.tan() + 1.0 / latitude.cos()).ln() / std::f64::consts::PI) / 2.0 * world;
    let y = (centre_y + dy).clamp(0.0, world);
    let at_latitude = (std::f64::consts::PI * (1.0 - 2.0 * y / world)).sinh().atan().to_degrees();
    let mut at_longitude = longitude + dx * 360.0 / world;
    while at_longitude > 180.0 {
        at_longitude -= 360.0;
    }
    while at_longitude < -180.0 {
        at_longitude += 360.0;
    }
    (at_latitude, at_longitude)
}

/// Where the photos are: the centre and the spans of degrees that hold them all, with a margin; `None` without any.
pub fn extent(markers: &[MapMarker]) -> Option<(f64, f64, f64, f64)> {
    let placed: Vec<&MapMarker> = markers.iter().filter(|marker| on_the_map(marker)).collect();
    let first = placed.first()?;
    let (mut south, mut north, mut west, mut east) = (first.lat, first.lat, first.lon, first.lon);
    for marker in &placed {
        south = south.min(marker.lat);
        north = north.max(marker.lat);
        west = west.min(marker.lon);
        east = east.max(marker.lon);
    }
    let latitude_span = ((north - south) * 1.3).max(0.2);
    let longitude_span = ((east - west) * 1.3).max(0.2);
    Some(((south + north) / 2.0, (west + east) / 2.0, latitude_span.min(170.0), longitude_span.min(360.0)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(id: &str, lat: f64, lon: f64) -> MapMarker {
        MapMarker { id: id.to_owned(), lat, lon, ..MapMarker::default() }
    }

    #[test]
    fn a_view_spans_what_a_web_map_shows() {
        let (latitude_span, longitude_span) = view_spans(0.0, 0.0, 256.0, 256.0);
        assert!((longitude_span - 360.0).abs() < 1e-9);
        assert!((latitude_span - 170.1).abs() < 0.2, "the whole Mercator world: {latitude_span}");
        let (latitude_span, longitude_span) = view_spans(55.7, 12.0, 1024.0, 768.0);
        assert!((longitude_span - 0.3515625).abs() < 1e-9);
        assert!(latitude_span > 0.1 && latitude_span < 0.3, "{latitude_span}");
        assert_eq!(view_spans(0.0, 1.0, 5000.0, 400.0).1, 360.0, "never more than the world across");
    }

    #[test]
    fn a_click_on_the_map_names_its_place() {
        assert_eq!(location_at(55.676, 12.568, 10.0, 0.0, 0.0).1, 12.568);
        let (latitude, _) = location_at(55.676, 12.568, 10.0, 0.0, 0.0);
        assert!((latitude - 55.676).abs() < 1e-6, "{latitude}");
        let (north, east) = location_at(55.676, 12.568, 10.0, 256.0, -256.0);
        assert!(north > 55.676 && east > 12.568, "up and right are north and east");
        assert!((east - (12.568 + 360.0 / 1024.0)).abs() < 1e-9, "a tile across at zoom 10 is 360/1024 degrees");
        assert!(location_at(0.0, 179.0, 2.0, 100.0, 0.0).1 < 0.0, "east of 180 wraps to the west");
    }

    #[test]
    fn the_extent_holds_every_photo() {
        let (latitude, longitude, latitude_span, longitude_span) = extent(&[marker("a", 50.0, 10.0), marker("b", 60.0, 20.0)]).unwrap();
        assert_eq!((latitude, longitude), (55.0, 15.0));
        assert!(latitude_span >= 10.0 && longitude_span >= 10.0);
        assert!(extent(&[]).is_none());
    }
}
