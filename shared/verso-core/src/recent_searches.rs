//! The recent searches, kept for each account (one per server and user) on Linux, the Mac and the iPhone: the newest
//! first, at most 20, a search made again moving up rather than repeating, and one with nothing to look for never
//! kept. Linux's window, the Mac and the iPhone (through `verso-bridge`) all keep them here.
//!
//! What a search is differs with the platform, on purpose, and each keeps its own in a form of its own, which the core
//! reads and writes as it is, so nothing kept needs migrating: Linux keeps a search's words and where they are looked
//! for, a line each (`context\tdog`), and the same words in the same place are the same search; the Mac and the iPhone
//! keep the whole search, its filters and order with it, as one JSON array (Immich Gallery's `SearchQuery`), and a
//! search the same but for its order is the same one.

use std::collections::{BTreeMap, BTreeSet};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::{Deserialize, Serialize};

/// How many recent searches are kept.
pub const KEPT: usize = 20;

/// Where a search's words are looked for.
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

    /// The code Linux keeps it by.
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

/// A search as Linux keeps it: its words, and where they were looked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Words {
    pub mode: Mode,
    pub text: String,
}

/// A search as the Mac and the iPhone keep it, the whole of it, in the shape their `SearchQuery` encodes: a key it
/// lacks is that key's default, as their decoder reads it. Its dates are Foundation's, seconds since 2001, kept as they
/// are; where words are looked for (`Context`, `File Name`, `Description`, `Text in Images`) and the order
/// (`automatic`, `newest`, `oldest`) by the app's own names.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Search {
    pub text: String,
    pub mode: String,
    pub sort: String,
    #[serde(rename = "personIDs")]
    pub person_ids: BTreeSet<String>,
    pub person_names: BTreeMap<String, String>,
    pub country: String,
    pub state: String,
    pub city: String,
    pub make: String,
    pub model: String,
    pub lens_model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taken_after: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taken_before: Option<f64>,
    /// `IMAGE` or `VIDEO`, or empty for both.
    pub media_type: String,
    pub archived: bool,
    pub favorites: bool,
    pub not_in_album: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<i64>,
}

impl Default for Search {
    fn default() -> Search {
        Search {
            text: String::new(),
            mode: "Context".to_owned(),
            sort: "automatic".to_owned(),
            person_ids: BTreeSet::new(),
            person_names: BTreeMap::new(),
            country: String::new(),
            state: String::new(),
            city: String::new(),
            make: String::new(),
            model: String::new(),
            lens_model: String::new(),
            taken_after: None,
            taken_before: None,
            media_type: String::new(),
            archived: false,
            favorites: false,
            not_in_album: false,
            rating: None,
        }
    }
}

impl Search {
    /// Whether it narrows by anything: a filter the app shows as a chip.
    pub fn filters(&self) -> bool {
        let places = [&self.country, &self.state, &self.city, &self.make, &self.model, &self.lens_model];
        places.into_iter().any(|value| !value.is_empty())
            || matches!(self.media_type.as_str(), "IMAGE" | "VIDEO")
            || !self.person_ids.is_empty()
            || self.taken_after.is_some()
            || self.taken_before.is_some()
            || self.archived
            || self.favorites
            || self.not_in_album
            || self.rating.is_some()
    }

    /// The same search but for its order.
    fn same(&self, other: &Search) -> bool {
        Search { sort: other.sort.clone(), ..self.clone() } == *other
    }
}

/// Keep `search` first among `kept`, the same one earlier going; at most `KEPT`.
fn remembered<S>(mut kept: Vec<S>, search: S, same: impl Fn(&S, &S) -> bool) -> Vec<S> {
    kept.retain(|known| !same(known, &search));
    kept.insert(0, search);
    kept.truncate(KEPT);
    kept
}

/// Linux's recent searches as kept: a line each, the code of where the words were looked for, a tab, and the words.
/// A line that is not that is left out.
pub fn read_words(stored: &str) -> Vec<Words> {
    stored.lines().filter_map(|line| line.split_once('\t')).filter_map(|(mode, text)| Some(Words { mode: Mode::from_code(mode)?, text: text.to_owned() })).collect()
}

/// Linux's recent searches as kept.
pub fn words_lines(searches: &[Words]) -> String {
    searches.iter().map(|search| format!("{}\t{}", search.mode.code(), search.text)).collect::<Vec<_>>().join("\n")
}

/// Linux's recent searches once `search` is made: its words trimmed and on one line, first, the same words in the same
/// place earlier going. Words of nothing but spaces are not kept.
pub fn remember_words(kept: Vec<Words>, search: Words) -> Vec<Words> {
    let text = search.text.trim().replace(['\t', '\n'], " ");
    if text.is_empty() {
        return kept;
    }
    remembered(kept, Words { mode: search.mode, text }, |first, second| first == second)
}

/// The Mac's and the iPhone's recent searches as kept; none from what is not a JSON array of searches.
pub fn read_searches(stored: &str) -> Vec<Search> {
    serde_json::from_str(stored).unwrap_or_default()
}

/// The Mac's and the iPhone's recent searches as kept.
pub fn searches_json(searches: &[Search]) -> String {
    serde_json::to_string(searches).unwrap_or_else(|_| "[]".to_owned())
}

/// The Mac's and the iPhone's recent searches once `search` is made: first, the same search but for its order earlier
/// going. A search with neither words nor a filter is not kept.
pub fn remember_search(kept: Vec<Search>, search: Search) -> Vec<Search> {
    if search.text.is_empty() && !search.filters() {
        return kept;
    }
    remembered(kept, search, Search::same)
}

/// Where Linux keeps an account's recent searches: by the account's key (`Connection::account_key`).
pub fn linux_key(account: &str) -> String {
    format!("search.recent.{account}")
}

/// Where the Mac and the iPhone keep an account's recent searches: by its server's API address and its user, together
/// in Base64.
pub fn apple_key(api_url: &str, user_id: &str) -> String {
    format!("searchHistory.{}", STANDARD.encode(format!("{api_url}|{user_id}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(mode: Mode, text: &str) -> Words {
        Words { mode, text: text.to_owned() }
    }

    #[test]
    fn linux_puts_the_newest_first_without_repeating_the_same_words_in_the_same_place() {
        let mut kept = Vec::new();
        for search in [words(Mode::Context, "dog"), words(Mode::FileName, "IMG"), words(Mode::Context, " dog "), words(Mode::Text, "dog")] {
            kept = remember_words(kept, search);
        }
        assert_eq!(kept, [words(Mode::Text, "dog"), words(Mode::Context, "dog"), words(Mode::FileName, "IMG")]);
        assert_eq!(remember_words(kept.clone(), words(Mode::Context, "  ")), kept, "nothing to look for");
        let lines = words_lines(&remember_words(kept, words(Mode::Description, "a\tb\nc")));
        assert_eq!(lines, "description\ta b c\nocr\tdog\ncontext\tdog\nfileName\tIMG");
        assert_eq!(read_words(&lines).len(), 4);
        assert_eq!(read_words("context\tdog\nnot a search\nnowhere\tcat\n"), [words(Mode::Context, "dog")]);
        let mut many = Vec::new();
        for count in 0..25 {
            many = remember_words(many, words(Mode::Context, &count.to_string()));
        }
        assert_eq!((many.len(), many[0].text.as_str(), many[19].text.as_str()), (20, "24", "5"));
    }

    #[test]
    fn the_mac_keeps_the_whole_search_and_the_same_one_in_another_order_moves_up() {
        let beach = Search { text: "beach".to_owned(), ..Search::default() };
        let denmark = Search { country: "Denmark".to_owned(), media_type: "VIDEO".to_owned(), favorites: true, rating: Some(4), sort: "newest".to_owned(), ..Search::default() };
        let mut kept = remember_search(Vec::new(), beach.clone());
        kept = remember_search(kept, denmark.clone());
        kept = remember_search(kept, Search { sort: "oldest".to_owned(), ..beach.clone() });
        assert_eq!(kept.iter().map(|search| (search.text.as_str(), search.sort.as_str())).collect::<Vec<_>>(), [("beach", "oldest"), ("", "newest")]);
        // A search with nothing to look for is not kept: no words, and no filter the app shows.
        let nothing = Search { media_type: "OTHER".to_owned(), sort: "newest".to_owned(), ..Search::default() };
        assert_eq!(remember_search(kept.clone(), nothing), kept);
        for filtered in [
            Search { person_ids: BTreeSet::from(["p".to_owned()]), ..Search::default() },
            Search { taken_before: Some(757_382_400.0), ..Search::default() },
            Search { not_in_album: true, ..Search::default() },
            Search { lens_model: "50mm".to_owned(), ..Search::default() },
        ] {
            assert_eq!(remember_search(Vec::new(), filtered).len(), 1);
        }
        // The words as the app gave them: the app trims them.
        assert_eq!(remember_search(Vec::new(), Search { text: " ".to_owned(), ..Search::default() }).len(), 1);
        let mut many = Vec::new();
        for count in 0..25 {
            many = remember_search(many, Search { text: count.to_string(), ..Search::default() });
        }
        assert_eq!((many.len(), many[0].text.as_str()), (20, "24"));
    }

    #[test]
    fn the_macs_searches_are_read_as_its_decoder_reads_them_and_written_as_its_encoder_wrote_them() {
        let kept = r#"[{"text":"IMG_","mode":"File Name","sort":"oldest","personIDs":["b","a"],"personNames":{"a":"Ada","b":"Bo"},"country":"","state":"","city":"","make":"","model":"","lensModel":"","takenAfter":757382400.25,"mediaType":"","archived":false,"favorites":false,"notInAlbum":false},{"text":"dog"}]"#;
        let searches = read_searches(kept);
        assert_eq!(searches.len(), 2);
        assert_eq!(searches[0].person_ids.iter().map(String::as_str).collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!((searches[0].taken_after, searches[0].rating), (Some(757_382_400.25), None));
        assert_eq!(searches[1], Search { text: "dog".to_owned(), ..Search::default() }, "a key it lacks is its default");
        // The same search whatever order its people came in, and an older entry without a newer key the same as one
        // with that key's default.
        let again = Search { sort: "automatic".to_owned(), person_ids: BTreeSet::from(["b".to_owned(), "a".to_owned()]), ..searches[0].clone() };
        assert_eq!(remember_search(searches.clone(), again).len(), 2);
        assert_eq!(remember_search(searches.clone(), Search { text: "dog".to_owned(), not_in_album: false, ..Search::default() }).len(), 2);
        let written = searches_json(&searches);
        assert!(written.contains(r#""personIDs":["a","b"]"#) && written.contains(r#""takenAfter":757382400.25"#) && !written.contains("rating"), "{written}");
        assert_eq!(read_searches(&written), searches);
        assert!(read_searches("").is_empty() && read_searches("{}").is_empty());
        assert_eq!(searches_json(&[]), "[]");
    }

    #[test]
    fn each_account_keeps_its_own() {
        assert_eq!(linux_key("4f2a"), "search.recent.4f2a");
        assert_eq!(apple_key("https://demo.immich.app/api", "6bbe2767-7851-461a-aa2d-afbd3460aa85"), "searchHistory.aHR0cHM6Ly9kZW1vLmltbWljaC5hcHAvYXBpfDZiYmUyNzY3LTc4NTEtNDYxYS1hYTJkLWFmYmQzNDYwYWE4NQ==");
    }
}
