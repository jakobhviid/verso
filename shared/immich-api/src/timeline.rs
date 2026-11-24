//! Timeline buckets: how many Assets each month holds, and which ids one month holds.
//!
//! Buckets group by the Asset's **local wall-clock** time (`localDateTime`), not by UTC, so a photo taken
//! 2020-03-01 00:30 at +02:00 is in the March bucket although its UTC time is in February (as of
//! v3.3.5). A UTC date-range search therefore does not reproduce a bucket; listing a month goes
//! through [`Client::time_bucket`] (ids) and then search or [`Client::asset`] for details.
//!
//! Visibility: the bucket endpoints include archived Assets by default. The library and person timelines send
//! `visibility=timeline`; an album sends nothing, because an album shows its archived members too; the archive sends
//! `visibility=archive`, as Immich's own Archive page does; favorites send `isFavorite=true` and no visibility, as
//! Immich's Favorites page does, so archived favorites are among them.
//!
//! `GET /timeline/bucket` answers in **columns** (`{"id":[...],"fileCreatedAt":[...],...}`), with
//! `fileCreatedAt` in UTC without a `Z`. A column the server leaves out reads as its default; a column of the
//! wrong length is a protocol error.

use std::fmt;
use std::str::FromStr;

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, Utc};
use serde::Deserialize;

use crate::asset::Visibility;
use crate::client::{Client, Fetched};
use crate::dates::parse_utc;
use crate::error::ApiError;

/// Which timeline to read.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TimelineScope {
    /// The whole library: timeline visibility only (no archived, no trashed).
    Library,
    /// The whole library as a gallery shows it, each stack as its primary Asset with the stack's id and count
    /// (`withStacked`), with the photos of the partners shown in the timeline (`withPartners`).
    LibraryStacked,
    /// One album, by id, archived members included.
    Album(String),
    /// One person, by id: timeline visibility only.
    Person(String),
    /// The archive: archived visibility only.
    Archive,
    /// The favorites, archived ones included.
    Favorites,
    /// The trash (Recently Deleted).
    Trash,
    /// The Locked Folder; Immich answers only a session a PIN code unlocked.
    Locked,
    /// The Assets that carry one tag, by id.
    Tag(String),
    /// A partner's library, by their user id: timeline visibility only.
    Partner(String),
}

/// How a gallery narrows and orders a timeline: favorites only, oldest first, by date added. The drive asks with none.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct TimelineOptions {
    pub favorites_only: bool,
    pub oldest_first: bool,
    /// By upload date (`orderBy=createdAt`, Immich v3.0), instead of the date taken: months are upload months.
    pub by_date_added: bool,
    /// Each stack as its primary Asset, with the stack's id and count (`withStacked`), as Immich's web app and Verso's
    /// Mac app show every timeline; `LibraryStacked` always is.
    pub stacked: bool,
}

impl TimelineScope {
    /// The scope's query with `options` added.
    fn query_with(&self, options: &TimelineOptions) -> Vec<(&'static str, &str)> {
        let mut query = self.query();
        if options.favorites_only && *self != TimelineScope::Favorites {
            // Immich refuses partners' photos together with the favorite filter; a partner's favorites are theirs.
            query.retain(|(key, _)| *key != "withPartners");
            query.push(("isFavorite", "true"));
        }
        if options.oldest_first {
            query.push(("order", "asc"));
        }
        if options.by_date_added {
            query.push(("orderBy", "createdAt"));
        }
        if options.stacked && *self != TimelineScope::LibraryStacked {
            query.push(("withStacked", "true"));
        }
        query
    }

    fn query(&self) -> Vec<(&'static str, &str)> {
        match self {
            TimelineScope::Library => vec![("visibility", "timeline")],
            TimelineScope::LibraryStacked => vec![("visibility", "timeline"), ("withStacked", "true"), ("withPartners", "true")],
            TimelineScope::Album(album_id) => vec![("albumId", album_id.as_str())],
            TimelineScope::Person(person_id) => vec![("personId", person_id.as_str()), ("visibility", "timeline")],
            TimelineScope::Archive => vec![("visibility", "archive")],
            TimelineScope::Favorites => vec![("isFavorite", "true")],
            TimelineScope::Trash => vec![("isTrashed", "true")],
            TimelineScope::Locked => vec![("visibility", "locked")],
            TimelineScope::Tag(tag_id) => vec![("tagId", tag_id.as_str())],
            TimelineScope::Partner(user_id) => vec![("userId", user_id.as_str()), ("visibility", "timeline")],
        }
    }
}

/// A calendar month, the unit of a timeline bucket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct YearMonth {
    pub year: i32,
    /// 1 to 12.
    pub month: u32,
}

impl YearMonth {
    /// A month, if `month` is 1 to 12 and the year is one chrono can represent.
    pub fn new(year: i32, month: u32) -> Option<YearMonth> {
        NaiveDate::from_ymd_opt(year, month, 1).map(|_| YearMonth { year, month })
    }

    /// Parse `"2025-04-01"` (a bucket key), `"2025-04-01T00:00:00.000Z"` or `"2025-04"`.
    pub fn parse(text: &str) -> Option<YearMonth> {
        let text = text.trim();
        let mut parts = text.splitn(3, '-');
        let year = parts.next()?.parse().ok()?;
        let month_text = parts.next()?;
        if month_text.len() != 2 {
            return None;
        }
        let month = month_text.parse().ok()?;
        if let Some(rest) = parts.next() {
            // The rest must at least start with a valid day, so "2025-04-xx" is refused.
            let day: u32 = rest.get(..2)?.parse().ok()?;
            NaiveDate::from_ymd_opt(year, month, day)?;
        }
        YearMonth::new(year, month)
    }

    /// The key the bucket endpoints use: the first day, `"2025-04-01"`.
    pub fn bucket_key(&self) -> String {
        format!("{:04}-{:02}-01", self.year, self.month)
    }

    /// The first day of the month.
    pub fn first_day(&self) -> NaiveDate {
        // `new` and `parse` only build valid months.
        NaiveDate::from_ymd_opt(self.year, self.month, 1).unwrap_or_default()
    }

    /// The month after this one.
    pub fn next(&self) -> YearMonth {
        if self.month == 12 {
            YearMonth { year: self.year + 1, month: 1 }
        } else {
            YearMonth { year: self.year, month: self.month + 1 }
        }
    }

    /// The month before this one.
    pub fn previous(&self) -> YearMonth {
        if self.month == 1 {
            YearMonth { year: self.year - 1, month: 12 }
        } else {
            YearMonth { year: self.year, month: self.month - 1 }
        }
    }

    /// The month a wall-clock time falls in.
    pub fn of(wall_clock: &NaiveDateTime) -> YearMonth {
        YearMonth {
            year: wall_clock.year(),
            month: wall_clock.month(),
        }
    }

    /// The UTC instants that can hold this month's wall-clock times: the month read as UTC, widened by
    /// `margin` on each side. With a 14 hour margin it covers every time zone; filter the results by
    /// `local_date_time` afterwards (ARCHITECTURE.md, "Names and sizes without a session").
    pub fn utc_range_widened(&self, margin: Duration) -> std::ops::Range<DateTime<Utc>> {
        let start = self.first_day().and_time(chrono::NaiveTime::MIN).and_utc();
        let end = self.next().first_day().and_time(chrono::NaiveTime::MIN).and_utc();
        (start - margin)..(end + margin)
    }
}

impl fmt::Display for YearMonth {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:04}-{:02}", self.year, self.month)
    }
}

impl FromStr for YearMonth {
    type Err = ApiError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        YearMonth::parse(text).ok_or_else(|| ApiError::Protocol(format!("not a month: `{text}`")))
    }
}

/// How many Assets one month holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeBucket {
    pub month: YearMonth,
    pub count: u32,
}

/// One Asset in a bucket: its id, dates and what a grid lays it out by; no file names and no file sizes.
#[derive(Debug, Clone, PartialEq)]
pub struct BucketAsset {
    pub id: String,
    /// When it was taken, in UTC.
    pub file_created_at: DateTime<Utc>,
    /// The offset of the wall clock where it was taken, in hours (can be fractional, such as 5.5).
    pub local_offset_hours: f64,
    pub is_trashed: bool,
    pub visibility: Visibility,
    pub is_image: bool,
    /// What a grid lays out and shows before the thumbnail arrives; `None` where the server left the column out.
    /// Width over height, as shown (rotation applied).
    pub ratio: Option<f64>,
    /// The thumbnail's ThumbHash, base64.
    pub thumbhash: Option<String>,
    pub is_favorite: bool,
    /// A video's length in milliseconds.
    pub duration_ms: Option<u64>,
    /// The video half of a Live Photo.
    pub live_photo_video_id: Option<String>,
    pub owner_id: Option<String>,
    /// The stack it heads, and how many Assets the stack holds, where it heads one.
    pub stack: Option<(String, u32)>,
    /// Where it was taken, when known: coordinates (both, or neither; only from
    /// [`Client::time_bucket_with_coordinates`]) and the city.
    pub coordinates: Option<(f64, f64)>,
    pub city: Option<String>,
    /// The country it was taken in, when known.
    pub country: Option<String>,
}

impl BucketAsset {
    /// The wall-clock time it was taken: the UTC time plus the local offset. Buckets group by this.
    pub fn local_date_time(&self) -> NaiveDateTime {
        let offset_seconds = (self.local_offset_hours * 3600.0).round() as i64;
        self.file_created_at.naive_utc() + Duration::seconds(offset_seconds)
    }
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct TimeBucketWire {
    time_bucket: Option<String>,
    count: u32,
}

fn into_time_buckets(wire: Vec<TimeBucketWire>) -> Result<Vec<TimeBucket>, ApiError> {
    wire.into_iter()
        .map(|bucket| {
            let key = bucket.time_bucket.unwrap_or_default();
            let month = YearMonth::parse(&key)
                .ok_or_else(|| ApiError::Protocol(format!("a timeline bucket with an unreadable month `{key}`")))?;
            Ok(TimeBucket {
                month,
                count: bucket.count,
            })
        })
        .collect()
}

/// The columnar answer of `GET /timeline/bucket`. Only the columns we use; the rest are ignored.
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct BucketColumns {
    id: Vec<String>,
    file_created_at: Vec<Option<String>>,
    local_offset_hours: Vec<Option<f64>>,
    is_trashed: Vec<Option<bool>>,
    visibility: Vec<Option<Visibility>>,
    is_image: Vec<Option<bool>>,
    // The columns a gallery lays out by, read leniently: any shape the server sends decodes, and one that does not
    // fit (not a list, a value of another type, a length that differs) counts as missing. The drive reads its months
    // through the same type, and must never fail on a column it does not use.
    #[serde(deserialize_with = "lenient_column")]
    ratio: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    thumbhash: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    is_favorite: Vec<serde_json::Value>,
    /// Milliseconds on Immich 3, `H:MM:SS.ffffff` before.
    #[serde(deserialize_with = "lenient_column")]
    duration: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    live_photo_video_id: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    owner_id: Vec<serde_json::Value>,
    /// `[stack id, count]` for the Asset that heads a stack (sent only with `withStacked`).
    #[serde(deserialize_with = "lenient_column")]
    stack: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    latitude: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    longitude: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    city: Vec<serde_json::Value>,
    #[serde(deserialize_with = "lenient_column")]
    country: Vec<serde_json::Value>,
}

/// A column as a list of whatever it holds; anything but a list is an empty column.
fn lenient_column<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Vec<serde_json::Value>, D::Error> {
    Ok(match serde_json::Value::deserialize(deserializer)? {
        serde_json::Value::Array(values) => values,
        _ => Vec::new(),
    })
}

/// The value at `index` of a lenient column, only when the column has one per row.
fn lenient_cell(column: &[serde_json::Value], index: usize, rows: usize) -> Option<&serde_json::Value> {
    if column.len() == rows {
        column.get(index).filter(|value| !value.is_null())
    } else {
        None
    }
}

/// A video's length from the bucket's `duration` column: milliseconds, or `H:MM:SS.ffffff` from older servers.
fn duration_ms(value: &serde_json::Value) -> Option<u64> {
    match value {
        serde_json::Value::Number(number) => number.as_u64().or_else(|| number.as_f64().map(|milliseconds| milliseconds.max(0.0) as u64)),
        serde_json::Value::String(text) => {
            let mut seconds = 0.0;
            for part in text.split(':') {
                seconds = seconds * 60.0 + part.trim().parse::<f64>().ok()?;
            }
            Some((seconds * 1000.0).round() as u64)
        }
        _ => None,
    }
}

/// The value at `index` of a column, or `fallback` when the column was left out.
fn cell<T: Clone>(column: &[Option<T>], index: usize, fallback: T) -> T {
    column.get(index).cloned().flatten().unwrap_or(fallback)
}

fn check_column_length<T>(name: &str, column: &[T], rows: usize) -> Result<(), ApiError> {
    if column.is_empty() || column.len() == rows {
        Ok(())
    } else {
        Err(ApiError::Protocol(format!(
            "timeline bucket column `{name}` has {} entries for {rows} ids",
            column.len()
        )))
    }
}

fn into_bucket_assets(columns: BucketColumns) -> Result<Vec<BucketAsset>, ApiError> {
    let rows = columns.id.len();
    check_column_length("fileCreatedAt", &columns.file_created_at, rows)?;
    check_column_length("localOffsetHours", &columns.local_offset_hours, rows)?;
    check_column_length("isTrashed", &columns.is_trashed, rows)?;
    check_column_length("visibility", &columns.visibility, rows)?;
    check_column_length("isImage", &columns.is_image, rows)?;

    columns
        .id
        .iter()
        .enumerate()
        .map(|(index, id)| {
            let file_created_at = columns
                .file_created_at
                .get(index)
                .and_then(|text| text.as_deref())
                .and_then(parse_utc)
                .ok_or_else(|| ApiError::Protocol(format!("bucket Asset {id} has no usable fileCreatedAt")))?;
            Ok(BucketAsset {
                id: id.clone(),
                file_created_at,
                local_offset_hours: cell(&columns.local_offset_hours, index, 0.0),
                is_trashed: cell(&columns.is_trashed, index, false),
                visibility: cell(&columns.visibility, index, Visibility::Timeline),
                is_image: cell(&columns.is_image, index, true),
                ratio: lenient_cell(&columns.ratio, index, rows).and_then(serde_json::Value::as_f64).filter(|ratio| ratio.is_finite() && *ratio > 0.0),
                thumbhash: lenient_cell(&columns.thumbhash, index, rows).and_then(serde_json::Value::as_str).filter(|hash| !hash.is_empty()).map(str::to_owned),
                is_favorite: lenient_cell(&columns.is_favorite, index, rows).and_then(serde_json::Value::as_bool).unwrap_or(false),
                duration_ms: lenient_cell(&columns.duration, index, rows).and_then(duration_ms),
                live_photo_video_id: lenient_cell(&columns.live_photo_video_id, index, rows).and_then(serde_json::Value::as_str).filter(|id| !id.is_empty()).map(str::to_owned),
                owner_id: lenient_cell(&columns.owner_id, index, rows).and_then(serde_json::Value::as_str).map(str::to_owned),
                stack: lenient_cell(&columns.stack, index, rows).and_then(serde_json::Value::as_array).and_then(|pair| match pair.as_slice() {
                    [stack_id, count] => {
                        let count = count.as_u64().or_else(|| count.as_str().and_then(|text| text.parse().ok()))?;
                        Some((stack_id.as_str()?.to_owned(), u32::try_from(count).ok()?))
                    }
                    _ => None,
                }),
                // As Immich's map: located when it has both a latitude and a longitude.
                coordinates: lenient_cell(&columns.latitude, index, rows)
                    .and_then(serde_json::Value::as_f64)
                    .zip(lenient_cell(&columns.longitude, index, rows).and_then(serde_json::Value::as_f64)),
                city: lenient_cell(&columns.city, index, rows).and_then(serde_json::Value::as_str).filter(|city| !city.is_empty()).map(str::to_owned),
                country: lenient_cell(&columns.country, index, rows).and_then(serde_json::Value::as_str).filter(|country| !country.is_empty()).map(str::to_owned),
            })
        })
        .collect()
}

pub(crate) const ENDPOINTS: &[crate::wire::Endpoint] = crate::wire::endpoints![
    GET "/timeline/buckets" "asset.read",
    GET "/timeline/bucket" "asset.read",
];

impl Client {
    /// The months of a timeline and how many Assets each holds, newest first (`GET /timeline/buckets`).
    /// Needs `asset.read`.
    pub async fn time_buckets(&self, scope: &TimelineScope) -> Result<Vec<TimeBucket>, ApiError> {
        let wire: Vec<TimeBucketWire> = self.get_json(&["timeline", "buckets"], &scope.query()).await?;
        into_time_buckets(wire)
    }

    /// [`Client::time_buckets`] narrowed and ordered by `options`. Needs `asset.read`.
    pub async fn time_buckets_with(&self, scope: &TimelineScope, options: &TimelineOptions) -> Result<Vec<TimeBucket>, ApiError> {
        let wire: Vec<TimeBucketWire> = self.get_json(&["timeline", "buckets"], &scope.query_with(options)).await?;
        into_time_buckets(wire)
    }

    /// [`Client::time_bucket`] narrowed and ordered by `options`. Needs `asset.read`.
    pub async fn time_bucket_with(&self, scope: &TimelineScope, month: YearMonth, options: &TimelineOptions) -> Result<Vec<BucketAsset>, ApiError> {
        self.time_bucket_options_asking(scope, month, options, false).await
    }

    /// [`Client::time_bucket_with`], each Asset with its coordinates, for a map. Needs `asset.read`.
    pub async fn time_bucket_with_coordinates_and_options(
        &self,
        scope: &TimelineScope,
        month: YearMonth,
        options: &TimelineOptions,
    ) -> Result<Vec<BucketAsset>, ApiError> {
        self.time_bucket_options_asking(scope, month, options, true).await
    }

    async fn time_bucket_options_asking(
        &self,
        scope: &TimelineScope,
        month: YearMonth,
        options: &TimelineOptions,
        coordinates: bool,
    ) -> Result<Vec<BucketAsset>, ApiError> {
        let key = month.bucket_key();
        let mut query = scope.query_with(options);
        query.push(("timeBucket", key.as_str()));
        if coordinates {
            query.push(("withCoordinates", "true"));
        }
        let columns: BucketColumns = self.get_json(&["timeline", "bucket"], &query).await?;
        into_bucket_assets(columns)
    }

    /// [`Client::time_buckets`], unless nothing changed since `etag` (Immich answers 304 then).
    /// Needs `asset.read`.
    pub async fn time_buckets_if_changed(
        &self,
        scope: &TimelineScope,
        etag: Option<&str>,
    ) -> Result<Fetched<Vec<TimeBucket>>, ApiError> {
        let fetched: Fetched<Vec<TimeBucketWire>> = self
            .get_json_if_changed(&["timeline", "buckets"], &scope.query(), etag)
            .await?;
        match fetched {
            Fetched::NotModified => Ok(Fetched::NotModified),
            Fetched::Changed { value, etag } => Ok(Fetched::Changed {
                value: into_time_buckets(value)?,
                etag,
            }),
        }
    }

    /// The Assets of one month of a timeline (`GET /timeline/bucket`): ids and dates only.
    /// Needs `asset.read`.
    pub async fn time_bucket(&self, scope: &TimelineScope, month: YearMonth) -> Result<Vec<BucketAsset>, ApiError> {
        self.time_bucket_asking(scope, month, false).await
    }

    /// [`Client::time_bucket`] with each asset's coordinates, which the server sends only when asked
    /// (`withCoordinates`, as of v3.4.1: without it a month has its cities and no coordinates).
    pub async fn time_bucket_with_coordinates(&self, scope: &TimelineScope, month: YearMonth) -> Result<Vec<BucketAsset>, ApiError> {
        self.time_bucket_asking(scope, month, true).await
    }

    async fn time_bucket_asking(&self, scope: &TimelineScope, month: YearMonth, coordinates: bool) -> Result<Vec<BucketAsset>, ApiError> {
        let key = month.bucket_key();
        let mut query = scope.query();
        query.push(("timeBucket", key.as_str()));
        if coordinates {
            query.push(("withCoordinates", "true"));
        }
        let columns: BucketColumns = self.get_json(&["timeline", "bucket"], &query).await?;
        into_bucket_assets(columns)
    }

    /// [`Client::time_bucket`], unless nothing changed since `etag`.
    /// Needs `asset.read`.
    pub async fn time_bucket_if_changed(
        &self,
        scope: &TimelineScope,
        month: YearMonth,
        etag: Option<&str>,
    ) -> Result<Fetched<Vec<BucketAsset>>, ApiError> {
        let key = month.bucket_key();
        let mut query = scope.query();
        query.push(("timeBucket", key.as_str()));
        let fetched: Fetched<BucketColumns> = self.get_json_if_changed(&["timeline", "bucket"], &query, etag).await?;
        match fetched {
            Fetched::NotModified => Ok(Fetched::NotModified),
            Fetched::Changed { value, etag } => Ok(Fetched::Changed {
                value: into_bucket_assets(value)?,
                etag,
            }),
        }
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn options_narrow_and_order_a_timeline_without_changing_the_drives_query() {
        let none = TimelineScope::Library.query_with(&TimelineOptions::default());
        assert_eq!(none, TimelineScope::Library.query());
        let all = TimelineOptions { favorites_only: true, oldest_first: true, by_date_added: true, stacked: true };
        let person = TimelineScope::Person("p".into());
        let query = person.query_with(&all);
        assert!(query.contains(&("isFavorite", "true")) && query.contains(&("order", "asc")) && query.contains(&("orderBy", "createdAt")));
        let favorites = TimelineScope::Favorites.query_with(&all);
        assert_eq!(favorites.iter().filter(|(key, _)| *key == "isFavorite").count(), 1, "Favorites asks once");
        let library = TimelineScope::LibraryStacked;
        assert!(library.query_with(&TimelineOptions::default()).contains(&("withPartners", "true")));
        let favorite_library = library.query_with(&all);
        assert!(!favorite_library.iter().any(|(key, _)| *key == "withPartners"), "Immich refuses partners with favorites");
        assert!(query.contains(&("withStacked", "true")), "stacked asks for the stacks");
        assert_eq!(favorite_library.iter().filter(|(key, _)| *key == "withStacked").count(), 1, "the stacked library asks once");
    }

    use super::*;
    use crate::fixtures;
    use crate::test_server::{CannedResponse, FakeServer};

    #[test]
    fn year_month_parses_bucket_keys() {
        assert_eq!(YearMonth::parse("2025-04-01"), Some(YearMonth { year: 2025, month: 4 }));
        assert_eq!(
            YearMonth::parse("2024-01-01T00:00:00.000Z"),
            Some(YearMonth { year: 2024, month: 1 })
        );
        assert_eq!(YearMonth::parse("1970-01"), Some(YearMonth { year: 1970, month: 1 }));
        for bad in ["2025-13-01", "2025-4-01", "2025", "", "2025-04-xx", "April"] {
            assert_eq!(YearMonth::parse(bad), None, "accepted {bad}");
        }
    }

    #[test]
    fn year_month_formats_and_steps() {
        let december = YearMonth::new(2019, 12).unwrap();
        assert_eq!(december.to_string(), "2019-12");
        assert_eq!(december.bucket_key(), "2019-12-01");
        assert_eq!(december.next(), YearMonth { year: 2020, month: 1 });
        assert_eq!(december.next().previous(), december);
        assert!(YearMonth::new(2019, 0).is_none());
        assert!("2019-12-01".parse::<YearMonth>().is_ok());
    }

    #[test]
    fn widened_utc_range_covers_every_zone() {
        let march = YearMonth::new(2020, 3).unwrap();
        let range = march.utc_range_widened(Duration::hours(14));
        assert_eq!(range.start, parse_utc("2020-02-29T10:00:00Z").unwrap());
        assert_eq!(range.end, parse_utc("2020-04-01T14:00:00Z").unwrap());
    }

    #[test]
    fn buckets_decode() {
        let wire: Vec<TimeBucketWire> = serde_json::from_str(fixtures::TIME_BUCKETS).unwrap();
        let buckets = into_time_buckets(wire).unwrap();
        assert_eq!(buckets.len(), 3);
        assert_eq!(
            buckets[0],
            TimeBucket {
                month: YearMonth { year: 2025, month: 4 },
                count: 1
            }
        );
        assert_eq!(buckets[2].month, YearMonth { year: 1970, month: 1 });
    }

    #[test]
    fn columnar_bucket_decodes_with_utc_without_z() {
        let columns: BucketColumns = serde_json::from_str(fixtures::TIME_BUCKET_COLUMNS).unwrap();
        let assets = into_bucket_assets(columns).unwrap();
        assert_eq!(assets.len(), 3);
        let first = &assets[0];
        assert_eq!(first.id, "2d6e3655-50dd-40f5-b8cf-f7d3f56aa95e");
        assert_eq!(first.file_created_at, parse_utc("2018-11-17T12:04:36Z").unwrap());
        assert_eq!(first.local_offset_hours, 1.0);
        assert_eq!(first.visibility, Visibility::Timeline);
        assert!(first.is_image);
        assert!(!first.is_trashed);
        assert_eq!(
            first.local_date_time(),
            parse_utc("2018-11-17T13:04:36Z").unwrap().naive_utc()
        );
    }

    #[test]
    fn the_grids_columns_decode_where_the_server_sends_them() {
        let columns: BucketColumns = serde_json::from_str(fixtures::TIME_BUCKET_COLUMNS).unwrap();
        let first = into_bucket_assets(columns).unwrap().remove(0);
        assert_eq!(first.ratio, Some(0.75));
        assert_eq!(first.thumbhash.as_deref(), Some("HQgKDQIDSW2VuGdnh3p3h/+a0a8p"));
        assert!(!first.is_favorite);
        assert_eq!(first.duration_ms, None);
        assert_eq!(first.owner_id.as_deref(), Some("201f18cd-48ec-4220-8e10-1466650212ee"));
        assert_eq!(first.stack, None);

        let video = r#"{"id":["a","b"],"fileCreatedAt":["2018-11-17T12:04:36","2018-11-17T11:31:54"],
            "duration":[12345,"0:01:02.500000"],"ratio":[0,1.5],"stack":[["stack-1","3"],null],
            "livePhotoVideoId":["",null],"isFavorite":[true,null],"city":["Brussels",""],"country":["Belgium",null]}"#;
        let assets = into_bucket_assets(serde_json::from_str(video).unwrap()).unwrap();
        assert_eq!(assets[0].duration_ms, Some(12345), "milliseconds, as Immich 3 sends them");
        assert_eq!(assets[1].duration_ms, Some(62500), "H:MM:SS.ffffff, as older servers send it");
        assert_eq!(assets[0].ratio, None, "a ratio of zero would lay out nothing");
        assert_eq!(assets[1].ratio, Some(1.5));
        assert_eq!(assets[0].stack, Some(("stack-1".to_owned(), 3)));
        assert_eq!(assets[0].live_photo_video_id, None, "an empty id is none");
        assert!(assets[0].is_favorite);
        assert!(!assets[1].is_favorite);
        assert_eq!((assets[0].city.as_deref(), assets[0].country.as_deref()), (Some("Brussels"), Some("Belgium")));
        assert_eq!((assets[1].city.as_deref(), assets[1].country.as_deref()), (None, None), "empty or none is unknown");
    }

    #[test]
    fn a_grid_column_the_drive_does_not_use_never_breaks_a_month() {
        let odd = r#"{"id":["a","b"],"fileCreatedAt":["2018-11-17T12:04:36","2018-11-17T11:31:54"],
            "ratio":"wide","stack":[{"id":"x"},null],"thumbhash":[1],"isFavorite":[true],"duration":{"ms":3}}"#;
        let assets = into_bucket_assets(serde_json::from_str(odd).unwrap()).unwrap();
        assert_eq!(assets.len(), 2, "the month still reads");
        assert_eq!(assets[0].ratio, None);
        assert_eq!(assets[0].stack, None);
        assert_eq!(assets[0].thumbhash, None);
        assert!(!assets[0].is_favorite, "a column one short is ignored, not misaligned");
    }

    #[test]
    fn missing_columns_default_and_short_columns_fail() {
        let only_ids = r#"{"id":["a","b"],"fileCreatedAt":["2018-11-17T12:04:36","2018-11-17T11:31:54"]}"#;
        let assets = into_bucket_assets(serde_json::from_str(only_ids).unwrap()).unwrap();
        assert_eq!(assets[1].local_offset_hours, 0.0);
        assert_eq!(assets[1].visibility, Visibility::Timeline);

        let short = r#"{"id":["a","b"],"fileCreatedAt":["2018-11-17T12:04:36"]}"#;
        assert!(matches!(
            into_bucket_assets(serde_json::from_str(short).unwrap()),
            Err(ApiError::Protocol(_))
        ));
    }

    #[test]
    fn fractional_offsets() {
        let columns = r#"{"id":["a"],"fileCreatedAt":["2020-01-01T00:00:00"],"localOffsetHours":[5.5]}"#;
        let assets = into_bucket_assets(serde_json::from_str(columns).unwrap()).unwrap();
        assert_eq!(
            assets[0].local_date_time(),
            parse_utc("2020-01-01T05:30:00Z").unwrap().naive_utc()
        );
    }

    #[tokio::test]
    async fn scopes_send_the_right_filters() {
        let server = FakeServer::start(vec![
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "{}"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
            CannedResponse::json(200, "[]"),
        ])
        .await;
        let client = Client::new(&server.url, None, "test").unwrap();
        client.time_buckets(&TimelineScope::Library).await.unwrap();
        client.time_buckets(&TimelineScope::Album("album-1".into())).await.unwrap();
        let month = YearMonth::new(2018, 11).unwrap();
        client
            .time_bucket(&TimelineScope::Person("person-1".into()), month)
            .await
            .unwrap();
        client.time_buckets(&TimelineScope::Archive).await.unwrap();
        client.time_buckets(&TimelineScope::Favorites).await.unwrap();
        client.time_buckets(&TimelineScope::Trash).await.unwrap();
        client.time_buckets(&TimelineScope::Locked).await.unwrap();
        client.time_buckets(&TimelineScope::Tag("tag-1".into())).await.unwrap();
        client.time_buckets(&TimelineScope::LibraryStacked).await.unwrap();
        client.time_buckets(&TimelineScope::Partner("user-2".into())).await.unwrap();
        let targets: Vec<String> = server.requests().into_iter().map(|request| request.target).collect();
        assert_eq!(
            targets,
            [
                "/api/timeline/buckets?visibility=timeline",
                "/api/timeline/buckets?albumId=album-1",
                "/api/timeline/bucket?personId=person-1&visibility=timeline&timeBucket=2018-11-01",
                "/api/timeline/buckets?visibility=archive",
                "/api/timeline/buckets?isFavorite=true",
                "/api/timeline/buckets?isTrashed=true",
                "/api/timeline/buckets?visibility=locked",
                "/api/timeline/buckets?tagId=tag-1",
                "/api/timeline/buckets?visibility=timeline&withStacked=true&withPartners=true",
                "/api/timeline/buckets?userId=user-2&visibility=timeline",
            ]
        );
    }
}
