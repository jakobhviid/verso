//! A search as the Mac gallery makes one: words in one of four places (what photos show, file names, descriptions,
//! the text in photos), narrowed by filters (people, place, camera, dates, media type, not in an album, archived,
//! favorites, rating), in an order; and the recent searches.

use chrono::{NaiveDate, TimeZone, Utc};
use immich_api::search::AssetQuery;
use immich_api::{AssetKind, SmartQuery, Visibility};

use verso_core::grid_options::MediaType;
use crate::library::Source;
use crate::settings::Settings;

/// Where the words are looked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Mode {
    /// What photos show (smart search, which needs machine learning).
    #[default]
    Context,
    FileName,
    Description,
    /// The text in photos (OCR).
    Text,
}

impl Mode {
    pub const ALL: [Mode; 4] = [Mode::Context, Mode::FileName, Mode::Description, Mode::Text];

    pub fn code(self) -> &'static str {
        match self {
            Mode::Context => "context",
            Mode::FileName => "fileName",
            Mode::Description => "description",
            Mode::Text => "ocr",
        }
    }

    pub fn from_code(code: &str) -> Option<Mode> {
        Mode::ALL.into_iter().find(|mode| mode.code() == code)
    }
}

/// The results' order: as found (smart search's best first, otherwise newest first), or by date.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Order {
    #[default]
    Default,
    NewestFirst,
    OldestFirst,
}

/// What narrows a search; empty, nothing does.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Filters {
    /// People, by id and name.
    pub people: Vec<(String, String)>,
    pub country: Option<String>,
    pub state: Option<String>,
    pub city: Option<String>,
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
    pub taken_after: Option<NaiveDate>,
    pub taken_before: Option<NaiveDate>,
    pub media_type: MediaType,
    pub not_in_album: bool,
    /// Only archived photos.
    pub archived: bool,
    pub favorites: bool,
    pub rating: Option<u8>,
}

/// One filter that is set, to show as a chip and take away again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Chip {
    Person(usize),
    Country,
    State,
    City,
    Make,
    Model,
    Lens,
    TakenAfter,
    TakenBefore,
    MediaType,
    NotInAlbum,
    Archived,
    Favorites,
    Rating,
}

impl Filters {
    pub fn is_empty(&self) -> bool {
        *self == Filters::default()
    }

    /// The filters set, each with what its chip says.
    pub fn chips(&self, text: impl Fn(&str) -> String) -> Vec<(Chip, String)> {
        let mut chips: Vec<(Chip, String)> = self.people.iter().enumerate().map(|(index, (_, name))| (Chip::Person(index), name.clone())).collect();
        let mut add = |chip: Chip, label: Option<String>| {
            if let Some(label) = label {
                chips.push((chip, label));
            }
        };
        add(Chip::Country, self.country.clone());
        add(Chip::State, self.state.clone());
        add(Chip::City, self.city.clone());
        add(Chip::Make, self.make.clone());
        add(Chip::Model, self.model.clone());
        add(Chip::Lens, self.lens.clone());
        add(Chip::TakenAfter, self.taken_after.map(|date| text("From {date}").replace("{date}", &date.format("%Y-%m-%d").to_string())));
        add(Chip::TakenBefore, self.taken_before.map(|date| text("Until {date}").replace("{date}", &date.format("%Y-%m-%d").to_string())));
        add(Chip::MediaType, match self.media_type {
            MediaType::All => None,
            MediaType::Photos => Some(text("Photos")),
            MediaType::Videos => Some(text("Videos")),
        });
        add(Chip::NotInAlbum, self.not_in_album.then(|| text("Not in an Album")));
        add(Chip::Archived, self.archived.then(|| text("Archived")));
        add(Chip::Favorites, self.favorites.then(|| text("Favorites")));
        add(Chip::Rating, self.rating.map(|stars| text("{count} Stars").replace("{count}", &stars.to_string())));
        chips
    }

    /// Take one filter away; a place or camera takes those below it too, as they were chosen within it.
    pub fn remove(&mut self, chip: Chip) {
        match chip {
            Chip::Person(index) => {
                if index < self.people.len() {
                    self.people.remove(index);
                }
            }
            Chip::Country => {
                self.country = None;
                self.state = None;
                self.city = None;
            }
            Chip::State => {
                self.state = None;
                self.city = None;
            }
            Chip::City => self.city = None,
            Chip::Make => {
                self.make = None;
                self.model = None;
                self.lens = None;
            }
            Chip::Model => self.model = None,
            Chip::Lens => self.lens = None,
            Chip::TakenAfter => self.taken_after = None,
            Chip::TakenBefore => self.taken_before = None,
            Chip::MediaType => self.media_type = MediaType::All,
            Chip::NotInAlbum => self.not_in_album = false,
            Chip::Archived => self.archived = false,
            Chip::Favorites => self.favorites = false,
            Chip::Rating => self.rating = None,
        }
    }

    /// The filters as a search query.
    pub fn query(&self) -> AssetQuery {
        let start = |date: NaiveDate| Utc.from_utc_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default());
        let taken = match (self.taken_after, self.taken_before) {
            (None, None) => None,
            (after, before) => {
                let from = after.map_or_else(|| Utc.timestamp_opt(0, 0).single().unwrap_or_default(), start);
                // "Before" includes that day: up to the start of the next.
                let to = before.and_then(|date| date.succ_opt()).map_or_else(|| Utc.with_ymd_and_hms(9999, 1, 1, 0, 0, 0).single().unwrap_or_default(), start);
                Some(from..to)
            }
        };
        AssetQuery {
            person_ids: (!self.people.is_empty()).then(|| self.people.iter().map(|(id, _)| id.clone()).collect()),
            country: self.country.clone(),
            state: self.state.clone(),
            city: self.city.clone(),
            camera_make: self.make.clone(),
            camera_model: self.model.clone(),
            lens_model: self.lens.clone(),
            taken,
            kind: match self.media_type {
                MediaType::All => None,
                MediaType::Photos => Some(AssetKind::Image),
                MediaType::Videos => Some(AssetKind::Video),
            },
            not_in_album: self.not_in_album,
            visibility: self.archived.then_some(Visibility::Archive),
            favorites_only: self.favorites,
            rating: self.rating,
            ..AssetQuery::default()
        }
    }
}

/// What the page reads for words, filters and an order; `None` for neither words nor filters (the landing page).
pub fn source(mode: Mode, text: &str, filters: &Filters, order: Order) -> Option<Source> {
    let text = text.trim();
    if text.is_empty() && filters.is_empty() {
        return None;
    }
    let mut query = filters.query();
    query.oldest_first = order == Order::OldestFirst;
    if text.is_empty() {
        return Some(Source::Search(Box::new(query)));
    }
    Some(match mode {
        Mode::Context => Source::Smart(Box::new(SmartQuery { text: Some(text.to_owned()), filter: query, ..SmartQuery::default() }), order),
        Mode::FileName => Source::Search(Box::new(AssetQuery { file_name: Some(text.to_owned()), ..query })),
        Mode::Description => Source::Search(Box::new(AssetQuery { description: Some(text.to_owned()), ..query })),
        Mode::Text => Source::Search(Box::new(AssetQuery { ocr: Some(text.to_owned()), ..query })),
    })
}

/// A search made, to make again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recent {
    pub mode: Mode,
    pub text: String,
}

/// How many recent searches are kept.
const RECENT: usize = 20;

fn recent_key(account: &str) -> String {
    format!("search.recent.{account}")
}

/// The recent searches of an account (one per server and user), newest first.
pub fn recent(settings: &Settings, account: &str) -> Vec<Recent> {
    settings
        .get(&recent_key(account))
        .map(|text| text.lines().filter_map(|line| line.split_once('\t')).filter_map(|(mode, text)| Some(Recent { mode: Mode::from_code(mode)?, text: text.to_owned() })).collect())
        .unwrap_or_default()
}

/// Remember a search first; the same words in the same place move up rather than repeat.
pub fn remember(settings: &Settings, account: &str, search: Recent) {
    let text = search.text.trim().replace(['\t', '\n'], " ");
    if text.is_empty() {
        return;
    }
    let mut kept = recent(settings, account);
    kept.retain(|known| !(known.mode == search.mode && known.text == text));
    kept.insert(0, Recent { mode: search.mode, text });
    kept.truncate(RECENT);
    let lines: Vec<String> = kept.iter().map(|known| format!("{}\t{}", known.mode.code(), known.text)).collect();
    settings.set(&recent_key(account), Some(&lines.join("\n")));
}

pub fn clear_recent(settings: &Settings, account: &str) {
    settings.set(&recent_key(account), None);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_words_and_no_filters_is_the_landing_page_and_filters_alone_search() {
        assert!(source(Mode::Context, "  ", &Filters::default(), Order::Default).is_none());
        let favorites = Filters { favorites: true, ..Filters::default() };
        match source(Mode::Context, "", &favorites, Order::OldestFirst) {
            Some(Source::Search(query)) => assert!(query.favorites_only && query.oldest_first),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn words_go_where_the_mode_says_with_the_filters() {
        let filters = Filters { city: Some("Aarhus".into()), not_in_album: true, ..Filters::default() };
        match source(Mode::FileName, "IMG", &filters, Order::Default) {
            Some(Source::Search(query)) => {
                assert_eq!(query.file_name.as_deref(), Some("IMG"));
                assert_eq!(query.city.as_deref(), Some("Aarhus"));
                assert!(query.not_in_album);
            }
            other => panic!("{other:?}"),
        }
        match source(Mode::Context, "a dog", &filters, Order::NewestFirst) {
            Some(Source::Smart(query, order)) => {
                assert_eq!(query.text.as_deref(), Some("a dog"));
                assert_eq!(query.filter.city.as_deref(), Some("Aarhus"));
                assert_eq!(order, Order::NewestFirst);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn chips_name_each_filter_and_taking_a_place_takes_those_within_it() {
        let mut filters = Filters { country: Some("Denmark".into()), city: Some("Aarhus".into()), rating: Some(4), favorites: true, ..Filters::default() };
        let labels: Vec<String> = filters.chips(str::to_owned).into_iter().map(|(_, label)| label).collect();
        assert_eq!(labels, ["Denmark", "Aarhus", "Favorites", "4 Stars"]);
        filters.remove(Chip::Country);
        assert_eq!((filters.country.clone(), filters.city.clone()), (None, None));
    }

    #[test]
    fn dates_include_the_last_day_and_archived_means_only_archived() {
        let filters = Filters { taken_before: NaiveDate::from_ymd_opt(2024, 3, 31), archived: true, ..Filters::default() };
        let query = filters.query();
        assert_eq!(query.taken.unwrap().end, Utc.with_ymd_and_hms(2024, 4, 1, 0, 0, 0).unwrap());
        assert_eq!(query.visibility, Some(Visibility::Archive));
    }

    #[test]
    fn recent_searches_put_the_newest_first_without_repeating() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        remember(&settings, "me", Recent { mode: Mode::Context, text: "dog".into() });
        remember(&settings, "me", Recent { mode: Mode::FileName, text: "IMG".into() });
        remember(&settings, "me", Recent { mode: Mode::Context, text: "dog".into() });
        let texts: Vec<String> = recent(&settings, "me").into_iter().map(|search| search.text).collect();
        assert_eq!(texts, ["dog", "IMG"]);
        assert!(recent(&settings, "someone else").is_empty());
        clear_recent(&settings, "me");
        assert!(recent(&settings, "me").is_empty());
    }
}
