//! What a grid shows, as sections of tiles: a timeline's months, read lazily (the months and their counts first,
//! then each month's photos as it comes into view), or a search's results grouped by month.

use chrono::{NaiveDateTime, Utc};
use immich_api::asset_info::AssetDetails;
use immich_api::search::AssetQuery;
use immich_api::timeline::{BucketAsset, TimelineScope, YearMonth};
use immich_api::{AssetKind, Client, SmartQuery, TextField, TimelineOptions};

/// One photo or video in a grid.
#[derive(Debug, Clone, PartialEq)]
pub struct Tile {
    pub id: String,
    /// Width over height as shown; 1 when unknown.
    pub ratio: f64,
    pub thumbhash: Option<String>,
    pub is_video: bool,
    pub duration_ms: Option<u64>,
    pub is_favorite: bool,
    /// A Live Photo: a still with a short video.
    pub is_live: bool,
    /// The stack it heads, and how many it holds.
    pub stack: Option<(String, u32)>,
    pub is_trashed: bool,
    /// When it was taken, on the clock where it was taken.
    pub taken: NaiveDateTime,
    /// Whether it has coordinates, where known.
    pub located: Option<bool>,
    /// The city it was taken in, where known.
    pub city: Option<String>,
}

impl From<&BucketAsset> for Tile {
    fn from(asset: &BucketAsset) -> Tile {
        Tile {
            id: asset.id.clone(),
            ratio: asset.ratio.unwrap_or(1.0),
            thumbhash: asset.thumbhash.clone(),
            is_video: !asset.is_image,
            duration_ms: asset.duration_ms,
            is_favorite: asset.is_favorite,
            is_live: asset.live_photo_video_id.is_some(),
            stack: asset.stack.clone(),
            is_trashed: asset.is_trashed,
            taken: asset.local_date_time(),
            located: Some(asset.coordinates.is_some()),
            city: asset.city.clone(),
        }
    }
}

/// Width over height of an Asset read whole: its own size where Immich has one, else the EXIF size turned by its
/// orientation (5 to 8 swap the sides).
pub fn ratio_of(details: &AssetDetails) -> f64 {
    if let (Some(width), Some(height)) = (details.width, details.height) {
        if width > 0 && height > 0 {
            return f64::from(width) / f64::from(height);
        }
    }
    let Some(exif) = details.exif.as_ref() else { return 1.0 };
    let (Some(width), Some(height)) = (exif.image_width, exif.image_height) else { return 1.0 };
    if width == 0 || height == 0 {
        return 1.0;
    }
    let turned = exif.orientation.as_deref().and_then(|orientation| orientation.trim().parse::<u32>().ok()).is_some_and(|orientation| (5..=8).contains(&orientation));
    if turned {
        f64::from(height) / f64::from(width)
    } else {
        f64::from(width) / f64::from(height)
    }
}

impl From<&AssetDetails> for Tile {
    fn from(details: &AssetDetails) -> Tile {
        Tile {
            id: details.id.clone(),
            ratio: ratio_of(details),
            thumbhash: details.thumbhash.clone().filter(|hash| !hash.is_empty()),
            is_video: details.kind == AssetKind::Video,
            duration_ms: details.duration_ms,
            is_favorite: details.is_favorite,
            is_live: details.live_photo_video_id.is_some(),
            stack: details.stack.as_ref().map(|stack| (stack.id.clone(), stack.asset_count.min(u64::from(u32::MAX)) as u32)),
            is_trashed: details.is_trashed,
            taken: details.local_date_time.unwrap_or_else(|| details.file_created_at.naive_utc()),
            located: details.exif.as_ref().map(|exif| exif.latitude.is_some() && exif.longitude.is_some()),
            city: details.exif.as_ref().and_then(|exif| exif.city.clone()).filter(|city| !city.is_empty()),
        }
    }
}

/// A run of tiles under one heading: a month of a timeline or of search results, or all of a list with no dates.
#[derive(Debug, Clone, PartialEq)]
pub struct Section {
    /// The month it holds, for a timeline (`None` for a list without months).
    pub month: Option<YearMonth>,
    /// How many tiles it holds, known before they are read.
    pub count: u32,
    /// Its tiles, once read.
    pub tiles: Option<Vec<Tile>>,
}

/// Where a grid's tiles come from.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    /// A timeline: months from `GET /timeline/buckets`, each read when shown.
    Timeline(TimelineScope),
    /// A timeline narrowed and ordered by a page's view options (favorites only, oldest first, by date added).
    Arranged(TimelineScope, TimelineOptions),
    /// A metadata search, read whole (up to a limit) and grouped by month.
    Search(Box<AssetQuery>),
    /// Tiles already known (a memory): one section, or grouped by month.
    Tiles { tiles: Vec<Tile>, by_month: bool },
    /// The Assets directly in one of the server's folders (external libraries, upload folders).
    Folder(String),
    /// The largest files first, perhaps only favorites, or only photos or videos.
    LargeFiles { favorites_only: bool, kind: Option<AssetKind> },
    /// Smart search: what best matches the words, within the filter; best first, or by date (`Order`).
    Smart(Box<SmartQuery>, crate::search::Order),
    /// A file name, description or recognised text, newest first.
    Text(TextField, String),
    /// Photos by id (a cluster on the map), each read whole, newest first.
    Ids(Vec<String>),
    /// A stack's photos, the primary first.
    Stack(String),
    /// The library's photos without a location (or, with `all`, every one, to see which have one), each month read.
    WithoutLocation { all: bool },
}

impl Source {
    /// A timeline's scope and options, for the sources read month by month.
    pub fn timeline(&self) -> Option<(TimelineScope, TimelineOptions)> {
        match self {
            Source::Timeline(scope) => Some((scope.clone(), TimelineOptions::default())),
            Source::Arranged(scope, options) => Some((scope.clone(), *options)),
            _ => None,
        }
    }
}

/// The most photos read by id for one grid, and how many at once.
const IDS_LIMIT: usize = 500;
const IDS_AT_ONCE: usize = 8;

/// The most tiles a search reads for one grid: more is a timeline's job.
pub const SEARCH_LIMIT: usize = 5000;

/// A stack's photos as tiles, the primary first and the trashed left out.
pub fn stack_tiles(stack: &immich_api::Stack) -> Vec<Tile> {
    let mut tiles: Vec<Tile> = stack.assets.iter().filter(|details| !details.is_trashed).map(Tile::from).collect();
    if let Some(position) = tiles.iter().position(|tile| tile.id == stack.primary_asset_id) {
        let primary = tiles.remove(position);
        tiles.insert(0, primary);
    }
    tiles
}

/// The sections of a source, with the months of a timeline still to read.
pub async fn sections(client: &Client, source: &Source) -> Result<Vec<Section>, String> {
    match source {
        Source::Timeline(_) | Source::Arranged(..) => {
            let (scope, options) = source.timeline().expect("a timeline");
            let buckets = client.time_buckets_with(&scope, &options).await.map_err(|error| error.to_string())?;
            Ok(buckets.into_iter().filter(|bucket| bucket.count > 0).map(|bucket| Section { month: Some(bucket.month), count: bucket.count, tiles: None }).collect())
        }
        Source::Search(query) => {
            let mut tiles = Vec::new();
            let mut cursor: Option<String> = None;
            loop {
                let page = client.search_details(query, 1000, cursor.as_deref()).await.map_err(|error| error.to_string())?;
                tiles.extend(page.assets.iter().filter(|details| !details.is_trashed).map(Tile::from));
                match page.next_cursor {
                    Some(next) if tiles.len() < SEARCH_LIMIT && Some(&next) != cursor.as_ref() => cursor = Some(next),
                    _ => break,
                }
            }
            Ok(by_month(tiles))
        }
        Source::Tiles { tiles, by_month: true } => Ok(by_month(tiles.clone())),
        Source::Tiles { tiles, by_month: false } => Ok(one_section(tiles.clone())),
        Source::Folder(path) => {
            let assets = client.folder_assets(path).await.map_err(|error| error.to_string())?;
            let mut tiles: Vec<Tile> = assets.iter().filter(|details| !details.is_trashed).map(Tile::from).collect();
            tiles.sort_by_key(|tile| std::cmp::Reverse(tile.taken));
            Ok(by_month(tiles))
        }
        Source::LargeFiles { favorites_only, kind } => {
            let assets = client.large_assets(0, Some(&immich_api::Visibility::Timeline), 250).await.map_err(|error| error.to_string())?;
            let wanted = |details: &&AssetDetails| (!favorites_only || details.is_favorite) && kind.as_ref().is_none_or(|kind| details.kind == *kind);
            Ok(one_section(assets.iter().filter(wanted).map(Tile::from).collect()))
        }
        Source::Smart(query, order) => {
            let mut assets = client.smart_search(query, 250).await.map_err(|error| error.to_string())?;
            assets.retain(|details| !details.is_trashed);
            let mut tiles: Vec<Tile> = assets.iter().map(Tile::from).collect();
            // A date order sorts the best matches found, as the Mac gallery does.
            match order {
                crate::search::Order::NewestFirst => tiles.sort_by_key(|tile| std::cmp::Reverse(tile.taken)),
                crate::search::Order::OldestFirst => tiles.sort_by_key(|tile| tile.taken),
                crate::search::Order::Default => {}
            }
            Ok(one_section(tiles))
        }
        Source::WithoutLocation { all } => {
            // Every month is read: the timeline's counts include the photos with a location.
            let buckets = client.time_buckets(&TimelineScope::Library).await.map_err(|error| error.to_string())?;
            let mut tasks = tokio::task::JoinSet::new();
            let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(IDS_AT_ONCE));
            for (order, bucket) in buckets.into_iter().filter(|bucket| bucket.count > 0).enumerate() {
                let (client, permits) = (client.clone(), permits.clone());
                tasks.spawn(async move {
                    let _permit = permits.acquire_owned().await.ok()?;
                    Some((order, bucket.month, client.time_bucket_with_coordinates(&TimelineScope::Library, bucket.month).await.ok()?))
                });
            }
            let mut months = Vec::new();
            while let Some(outcome) = tasks.join_next().await {
                if let Ok(Some(month)) = outcome {
                    months.push(month);
                }
            }
            months.sort_by_key(|(order, _, _)| *order);
            Ok(months
                .into_iter()
                .filter_map(|(_, month, assets)| {
                    let tiles: Vec<Tile> = assets.iter().map(Tile::from).filter(|tile| *all || tile.located != Some(true)).collect();
                    (!tiles.is_empty()).then_some(Section { month: Some(month), count: tiles.len() as u32, tiles: Some(tiles) })
                })
                .collect())
        }
        Source::Stack(id) => {
            let stack = client.stack(id).await.map_err(|error| error.to_string())?;
            Ok(one_section(stack_tiles(&stack)))
        }
        Source::Ids(ids) => {
            let mut tasks = tokio::task::JoinSet::new();
            let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(IDS_AT_ONCE));
            for id in ids.iter().take(IDS_LIMIT) {
                let (client, permits, id) = (client.clone(), permits.clone(), id.clone());
                tasks.spawn(async move {
                    let _permit = permits.acquire_owned().await.ok()?;
                    client.asset_details(&id).await.ok()
                });
            }
            let mut tiles = Vec::new();
            while let Some(outcome) = tasks.join_next().await {
                if let Ok(Some(details)) = outcome {
                    if !details.is_trashed {
                        tiles.push(Tile::from(&details));
                    }
                }
            }
            tiles.sort_by_key(|tile| std::cmp::Reverse(tile.taken));
            Ok(by_month(tiles))
        }
        Source::Text(field, text) => {
            let assets = client.search_text(*field, text, 1000).await.map_err(|error| error.to_string())?;
            Ok(by_month(assets.iter().filter(|details| !details.is_trashed).map(Tile::from).collect()))
        }
    }
}

/// One month of a timeline. Trashed photos stay out, unless the timeline is the trash.
pub async fn month(client: &Client, scope: &TimelineScope, month: YearMonth) -> Result<Vec<Tile>, String> {
    month_with(client, scope, &TimelineOptions::default(), month).await
}

/// One month of a timeline narrowed and ordered by `options`.
pub async fn month_with(client: &Client, scope: &TimelineScope, options: &TimelineOptions, month: YearMonth) -> Result<Vec<Tile>, String> {
    let assets = client.time_bucket_with(scope, month, options).await.map_err(|error| error.to_string())?;
    let trash = *scope == TimelineScope::Trash;
    Ok(assets.iter().filter(|asset| trash || !asset.is_trashed).map(Tile::from).collect())
}

/// Tiles as one section without a heading, in the order given.
pub fn one_section(tiles: Vec<Tile>) -> Vec<Section> {
    if tiles.is_empty() {
        return Vec::new();
    }
    vec![Section { month: None, count: tiles.len() as u32, tiles: Some(tiles) }]
}

/// Tiles grouped into months, in the order given, each month where its first tile is.
pub fn by_month(tiles: Vec<Tile>) -> Vec<Section> {
    let mut sections: Vec<Section> = Vec::new();
    for tile in tiles {
        let month = YearMonth::of(&tile.taken);
        match sections.iter_mut().find(|section| section.month == Some(month)) {
            Some(section) => {
                section.count += 1;
                section.tiles.get_or_insert_with(Vec::new).push(tile);
            }
            None => sections.push(Section { month: Some(month), count: 1, tiles: Some(vec![tile]) }),
        }
    }
    sections
}

/// One level of the server's folders: a folder under `parent` (`""` for the top), as Immich's folder view steps
/// through them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Folder {
    pub name: String,
    pub path: String,
    /// It holds photos itself, not only folders.
    pub has_photos: bool,
    /// How many folders with photos are in it, at any depth.
    pub folders_inside: usize,
}

/// The folders directly under `parent`, from the server's list of folders that hold photos.
pub fn folders_under(paths: &[String], parent: &str) -> Vec<Folder> {
    let parent = parent.trim_end_matches('/');
    let prefix = format!("{parent}/");
    let mut folders: Vec<Folder> = Vec::new();
    for path in paths {
        let Some(rest) = path.strip_prefix(&prefix) else { continue };
        let name = rest.split('/').next().unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        let full = format!("{prefix}{name}");
        let deeper = rest.len() > name.len();
        match folders.iter_mut().find(|folder| folder.name == name) {
            Some(folder) => {
                folder.has_photos |= !deeper;
                folder.folders_inside += usize::from(deeper);
            }
            None => folders.push(Folder { name: name.to_owned(), path: full, has_photos: !deeper, folders_inside: usize::from(deeper) }),
        }
    }
    folders.sort_by_key(|folder| folder.name.to_lowercase());
    folders
}

/// A search for one kind of Asset in the timeline (the Videos page), newest first.
pub fn videos_query() -> AssetQuery {
    AssetQuery { kind: Some(AssetKind::Video), visibility: Some(immich_api::Visibility::Timeline), ..AssetQuery::default() }
}

/// Today's date, for memories and greetings.
pub fn today() -> chrono::NaiveDate {
    Utc::now().date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tile(id: &str, taken: &str) -> Tile {
        Tile {
            id: id.to_owned(),
            ratio: 1.0,
            thumbhash: None,
            is_video: false,
            duration_ms: None,
            is_favorite: false,
            is_live: false,
            stack: None,
            is_trashed: false,
            taken: NaiveDateTime::parse_from_str(taken, "%Y-%m-%d %H:%M").unwrap(),
            located: None,
            city: None,
        }
    }

    #[test]
    fn folders_step_one_level_at_a_time() {
        let paths: Vec<String> = ["/data/upload/u1/00/01", "/data/upload/u1/00/02", "/data/upload/u1/01/aa", "/data/library/Trip", "/data/library/Trip/Day 2", "/photos"]
            .iter()
            .map(|path| path.to_string())
            .collect();
        let top = folders_under(&paths, "");
        assert_eq!(top.iter().map(|folder| folder.name.as_str()).collect::<Vec<_>>(), ["data", "photos"]);
        assert_eq!(top[0].folders_inside, 5);
        assert!(!top[0].has_photos);
        assert!(top[1].has_photos);
        let library = folders_under(&paths, "/data/library");
        assert_eq!(library, vec![Folder { name: "Trip".into(), path: "/data/library/Trip".into(), has_photos: true, folders_inside: 1 }]);
        assert_eq!(folders_under(&paths, "/data/upload/u1/00/").len(), 2, "a trailing slash is the same folder");
    }

    #[test]
    fn a_stack_shows_its_primary_first_and_leaves_out_the_trashed() {
        let asset = |id: &str, is_trashed: bool| AssetDetails { id: id.to_owned(), is_trashed, ..AssetDetails::default() };
        let stack = immich_api::Stack { id: "s".into(), primary_asset_id: "b".into(), assets: vec![asset("a", false), asset("b", false), asset("c", true), asset("d", false)] };
        let ids: Vec<String> = stack_tiles(&stack).into_iter().map(|tile| tile.id).collect();
        assert_eq!(ids, ["b", "a", "d"]);
    }

    #[test]
    fn tiles_group_by_the_month_they_were_taken_in_keeping_their_order() {
        let sections = by_month(vec![tile("a", "2024-03-10 10:00"), tile("b", "2024-03-01 09:00"), tile("c", "2024-02-28 23:59"), tile("d", "2024-03-05 12:00")]);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].month, YearMonth::new(2024, 3));
        assert_eq!(sections[0].count, 3);
        let ids: Vec<&str> = sections[0].tiles.as_ref().unwrap().iter().map(|tile| tile.id.as_str()).collect();
        assert_eq!(ids, ["a", "b", "d"]);
        assert_eq!(sections[1].month, YearMonth::new(2024, 2));
    }
}
