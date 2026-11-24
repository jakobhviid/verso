//! The map's clusters: the photos on screen gathered into cells of a grid that doubles with each zoom out, so a
//! cell keeps its edges as the view moves and a cluster keeps its picture. Linux's window, the Mac and the iPhone
//! (through `verso-bridge`) all cluster here. Ported from Immich Gallery's `ExploreMapCluster` (MIT;
//! THIRD-PARTY-NOTICES.md).

use std::collections::BTreeMap;

use immich_api::map::MapMarker;

/// Photos close together on the map, shown as one.
#[derive(Debug, Clone, PartialEq)]
pub struct Cluster {
    /// The first photo's id, by id order: it names the cluster and gives its picture.
    pub id: String,
    pub latitude: f64,
    pub longitude: f64,
    /// Every photo in it, by id.
    pub assets: Vec<String>,
    /// The box that holds its photos, a hair wider, so the photos Immich finds in it are the cluster's.
    pub bounds: Bounds,
}

/// A box on the map, in degrees.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    pub west: f64,
    pub south: f64,
    pub east: f64,
    pub north: f64,
}

impl Bounds {
    /// The box as Immich's timeline takes it (`bbox`): west, south, east and north.
    pub fn bbox(&self) -> String {
        format!("{},{},{},{}", self.west, self.south, self.east, self.north)
    }
}

/// How much wider than its photos a cluster's box is, in degrees.
const MARGIN: f64 = 0.000001;

/// Whether a photo's place can be shown on the map: a latitude between the poles and a longitude within the date line.
pub fn on_the_map(marker: &MapMarker) -> bool {
    marker.lat.is_finite() && marker.lon.is_finite() && marker.lat.abs() <= 90.0 && marker.lon.abs() <= 180.0
}

/// The clusters of the photos in a view centred on (`latitude`, `longitude`) and `latitude_span` by `longitude_span`
/// degrees, with a margin, about 12 cells high and 16 wide, by id. A view that is not a number has none.
pub fn clusters(markers: &[MapMarker], latitude: f64, longitude: f64, latitude_span: f64, longitude_span: f64) -> Vec<Cluster> {
    if ![latitude, longitude, latitude_span, longitude_span].iter().all(|value| value.is_finite()) {
        return Vec::new();
    }
    let latitude = latitude.clamp(-90.0, 90.0);
    let wrapped = longitude % 360.0;
    let longitude = if wrapped < -180.0 {
        wrapped + 360.0
    } else if wrapped > 180.0 {
        wrapped - 360.0
    } else {
        wrapped
    };
    let latitude_span = latitude_span.abs().clamp(0.00001, 180.0);
    let longitude_span = longitude_span.abs().clamp(0.00001, 360.0);
    // Cell sizes are powers of two, so their edges stay put between zoom levels and small moves.
    let latitude_step = 2f64.powf((latitude_span / 12.0).max(0.00001).log2().ceil());
    let longitude_step = 2f64.powf((longitude_span / 16.0).max(0.00001).log2().ceil());
    let mut groups: BTreeMap<(i64, i64), Vec<&MapMarker>> = BTreeMap::new();
    for marker in markers.iter().filter(|marker| on_the_map(marker)) {
        let distance = ((marker.lon - longitude + 540.0) % 360.0 - 180.0).abs();
        if (marker.lat - latitude).abs() > latitude_span * 0.65 || distance > longitude_span * 0.65 {
            continue;
        }
        let key = ((marker.lat / latitude_step).floor() as i64, (marker.lon / longitude_step).floor() as i64);
        groups.entry(key).or_default().push(marker);
    }
    let mut clusters: Vec<Cluster> = groups
        .into_values()
        .map(|mut group| {
            // By id, so a group that did not change keeps its name and picture whatever order the server sent.
            group.sort_by(|first, second| first.id.cmp(&second.id));
            let count = group.len() as f64;
            let lowest = |value: fn(&MapMarker) -> f64| group.iter().map(|marker| value(marker)).fold(f64::INFINITY, f64::min);
            let highest = |value: fn(&MapMarker) -> f64| group.iter().map(|marker| value(marker)).fold(f64::NEG_INFINITY, f64::max);
            Cluster {
                id: group[0].id.clone(),
                latitude: group.iter().map(|marker| marker.lat).sum::<f64>() / count,
                longitude: group.iter().map(|marker| marker.lon).sum::<f64>() / count,
                assets: group.iter().map(|marker| marker.id.clone()).collect(),
                bounds: Bounds {
                    west: (lowest(|marker| marker.lon) - MARGIN).max(-180.0),
                    south: (lowest(|marker| marker.lat) - MARGIN).max(-90.0),
                    east: (highest(|marker| marker.lon) + MARGIN).min(180.0),
                    north: (highest(|marker| marker.lat) + MARGIN).min(90.0),
                },
            }
        })
        .collect();
    clusters.sort_by(|first, second| first.id.cmp(&second.id));
    clusters
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(id: &str, lat: f64, lon: f64) -> MapMarker {
        MapMarker { id: id.to_owned(), lat, lon, ..MapMarker::default() }
    }

    /// Every photo of every cluster.
    fn photos(clusters: &[Cluster]) -> usize {
        clusters.iter().map(|cluster| cluster.assets.len()).sum()
    }

    /// 50,000 photos spread over the world, a degree apart.
    fn world() -> Vec<MapMarker> {
        (0..50_000).map(|index| marker(&index.to_string(), f64::from(index % 180) - 89.5, f64::from(index % 360) - 179.5)).collect()
    }

    #[test]
    fn nearby_photos_gather_and_far_ones_stay_apart() {
        let markers = [marker("b", 55.676, 12.568), marker("a", 55.677, 12.569), marker("c", 48.857, 2.352), marker("bad", f64::NAN, 0.0)];
        let wide = clusters(&markers, 52.0, 7.0, 20.0, 30.0);
        assert_eq!(wide.len(), 2, "{wide:?}");
        let copenhagen = wide.iter().find(|cluster| cluster.assets.len() == 2).unwrap();
        assert_eq!(copenhagen.id, "a", "named by the first id, so it keeps its picture");
        assert_eq!(copenhagen.assets, ["a", "b"]);
        let near = clusters(&markers, 55.676, 12.568, 0.002, 0.003);
        assert_eq!(near.len(), 2, "zoomed in, the two Copenhagen photos part: {near:?}");
        assert!(near.iter().all(|cluster| cluster.assets.len() == 1));
    }

    #[test]
    fn the_whole_world_of_photos_gathers_into_a_few_hundred_and_closer_into_fewer() {
        let markers = world();
        let everywhere = clusters(&markers, 0.0, 0.0, 180.0, 360.0);
        assert!(everywhere.len() <= 400, "{}", everywhere.len());
        assert_eq!(photos(&everywhere), markers.len());
        for cluster in &everywhere {
            let bounds = cluster.bounds;
            assert!(bounds.west <= bounds.east && bounds.south <= bounds.north, "{bounds:?}");
            let numbers: Vec<f64> = bounds.bbox().split(',').map(|number| number.parse().unwrap()).collect();
            assert_eq!(numbers, [bounds.west, bounds.south, bounds.east, bounds.north]);
        }
        assert!(clusters(&markers, 0.0, 0.0, 10.0, 10.0).len() < everywhere.len());
    }

    #[test]
    fn what_is_off_screen_stays_out_and_the_date_line_wraps() {
        let markers = [marker("fiji", -17.7, 178.0), marker("samoa", -13.8, -172.0)];
        assert_eq!(photos(&clusters(&markers, -15.0, 180.0, 20.0, 30.0)), 2);
        assert!(clusters(&markers, 50.0, 0.0, 10.0, 10.0).is_empty());
        let across = [marker("east", 0.0, 179.9), marker("west", 0.0, -179.9)];
        for longitude in [-1260.0, -540.0, -180.0, 180.0, 540.0, 1260.0] {
            assert_eq!(photos(&clusters(&across, 0.0, longitude, 10.0, 10.0)), 2, "seen from {longitude}");
        }
    }

    #[test]
    fn any_span_gives_places_on_the_map_and_a_span_of_the_world_shows_every_photo() {
        let markers = world();
        for span in [0.0, -10.0, 720.0, f64::MAX] {
            let shown = clusters(&markers, 0.0, 0.0, span, span);
            assert!(shown.iter().all(|cluster| cluster.latitude.is_finite() && cluster.longitude.is_finite()), "{span}");
            if span.abs() >= 360.0 {
                assert_eq!(photos(&shown), markers.len(), "{span}");
            }
        }
    }

    #[test]
    fn a_view_or_a_photo_that_is_not_a_place_shows_nothing() {
        let markers = [marker("a", 45.0, 9.0)];
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(clusters(&markers, invalid, 0.0, 10.0, 10.0).is_empty());
            assert!(clusters(&markers, 0.0, invalid, 10.0, 10.0).is_empty());
            assert!(clusters(&markers, 0.0, 0.0, invalid, 10.0).is_empty());
            assert!(clusters(&markers, 0.0, 0.0, 10.0, invalid).is_empty());
        }
        let nowhere = [marker("nan", f64::NAN, 0.0), marker("infinity", 0.0, f64::INFINITY), marker("beyond", 91.0, 181.0)];
        assert!(clusters(&nowhere, 0.0, 0.0, 180.0, 360.0).is_empty());
        assert!(!on_the_map(&nowhere[2]) && on_the_map(&markers[0]));
    }

    #[test]
    fn a_cluster_keeps_its_name_through_small_moves_zooms_and_the_servers_order() {
        let close = [marker("b", 45.01, 9.01), marker("a", 45.02, 9.02), marker("c", 46.0, 10.0)];
        let reversed: Vec<MapMarker> = close.iter().rev().cloned().collect();
        let stable = clusters(&close, 45.0, 9.0, 10.0, 10.0);
        assert_eq!(stable, clusters(&reversed, 45.0, 9.0, 10.001, 10.001), "a camera's rounding and the server's order change nothing");
        let zoomed = clusters(&close, 45.0, 9.0, 1.0, 1.0);
        let pair = |shown: &[Cluster]| shown.iter().find(|cluster| cluster.assets == ["a", "b"]).map(|cluster| cluster.id.clone());
        assert_eq!(pair(&stable).as_deref(), Some("a"));
        assert_eq!(pair(&zoomed).as_deref(), Some("a"));
        let mut names: Vec<&str> = zoomed.iter().map(|cluster| cluster.id.as_str()).collect();
        names.dedup();
        assert_eq!(names.len(), zoomed.len(), "each cluster a name of its own");
    }

    #[test]
    fn cells_have_fixed_edges_so_a_camera_rounding_splits_no_cluster() {
        let edge = [marker("left", 44.165, 9.0), marker("right", 44.168, 9.0)];
        let shown = clusters(&edge, 44.0, 9.0, 10.0, 10.0);
        assert_eq!(shown.len(), 1);
        assert_eq!(shown[0].assets.len(), 2);
        assert_eq!(shown, clusters(&edge, 44.0, 9.0, 10.001, 10.001));
    }

    #[test]
    fn a_clusters_box_holds_its_photos_a_hair_wider_and_stays_on_the_map() {
        let shown = clusters(&[marker("b", 45.01, 9.01), marker("a", 45.02, 9.02)], 45.0, 9.0, 10.0, 10.0);
        let bounds = shown[0].bounds;
        assert!((bounds.west - (9.01 - MARGIN)).abs() < 1e-12 && (bounds.east - (9.02 + MARGIN)).abs() < 1e-12, "{bounds:?}");
        assert!((bounds.south - (45.01 - MARGIN)).abs() < 1e-12 && (bounds.north - (45.02 + MARGIN)).abs() < 1e-12, "{bounds:?}");
        let corner = clusters(&[marker("corner", -90.0, 180.0)], -89.0, 179.0, 10.0, 10.0);
        assert_eq!((corner[0].bounds.south, corner[0].bounds.east), (-90.0, 180.0));
        assert_eq!(Bounds { west: -180.0, south: -0.5, east: 12.25, north: 90.0 }.bbox(), "-180,-0.5,12.25,90");
        assert_eq!(Bounds { west: 0.0000001, south: 0.0, east: 0.0, north: 0.0 }.bbox(), "0.0000001,0,0,0", "never written with an exponent");
    }
}
