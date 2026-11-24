//! The sidebar as Edit Sidebar arranges it, after Immich Gallery's `SidebarLayout`: on Linux, on the Mac and in the
//! iPhone's Collections, which keeps the Mac's. Its sections in order, the built-in ones and the person's own, which
//! page sits in which and in what order, what is hidden (pages and whole sections, and on the Mac and the iPhone an
//! album or a partner of an account), which sections are collapsed, and how many albums an album section lists and by
//! what. The built-in sections and their pages are each platform's own (the Mac's sidebar has Search, Linux's has
//! not), handed in as `Defaults`; the rules are the core's. Linux's window, the Mac and the iPhone (through
//! `verso-bridge`) all arrange here.
//!
//! Each platform keeps the layout in a form of its own, which the core reads and writes as it is (`Form`), so nothing
//! kept needs migrating. The forms differ on purpose in two rules besides: the person's own sections are `custom-` and
//! a number on Linux and a UUID on the Mac and the iPhone, and a section that lists albums takes no pages on Linux,
//! while on the Mac and the iPhone it takes them above its albums.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde::{Deserialize, Serialize};

/// The built-in sections in their first order, each with its pages; a section with none lists albums.
pub type Defaults<'a> = &'a [(&'a str, &'a [&'a str])];

/// How many albums an album section lists on the Mac and the iPhone until the person chooses.
pub const ALBUM_LIMIT: usize = 5;

/// The form a platform keeps its sidebar in, and the rules it has always had.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Form {
    /// Linux's: the arrangement under a key of its own, `{"sections":[{"id":"Photos"},{"id":"custom-1","name":"Kids"}],
    /// "pages":[["library","Photos"]]}`, and what is hidden under another, ids by commas, a section as `section:` and
    /// its id (`section:Sharing,map`). The person's own sections are `custom-1`, `custom-2`; the albums' sections take
    /// no pages; nothing collapses.
    Linux,
    /// The Mac's and the iPhone's: one value, `{"albumLimits":{"myAlbums":10},"albumSorting":{},"entries":[{"group":
    /// "photos","link":"search"}],"hiddenDynamicItems":[],"hiddenLinks":["map"],"sections":[{"hidden":false,"id":
    /// "photos"}]}`, its keys in order as Foundation's encoder sorts them, or the first form, the entries alone in an
    /// array. The person's own sections are UUIDs; every section takes pages.
    Apple,
}

/// A section of the sidebar: a built-in one, or the person's own with its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub id: String,
    /// The name the person gave it; a built-in section is named by the platform.
    pub name: Option<String>,
    /// Hidden from the sidebar, its pages keeping their places.
    pub hidden: bool,
    /// Shown by its heading alone, on the Mac and the iPhone.
    pub collapsed: bool,
    custom: bool,
}

impl Section {
    /// The person's own, which can be renamed and deleted.
    pub fn is_custom(&self) -> bool {
        self.custom
    }
}

/// How the sidebar is arranged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    form: Form,
    sections: Vec<Section>,
    /// Each page with the section it sits in, in order.
    pages: Vec<(String, String)>,
    /// The pages hidden, in the order they were hidden.
    hidden: Vec<String>,
    /// An album or a partner hidden, by a key the app makes for its account (the Mac and the iPhone).
    hidden_items: BTreeSet<String>,
    /// How many albums a section lists, 0 for all of them (the Mac and the iPhone).
    album_limits: BTreeMap<String, i64>,
    /// What a section's albums are sorted by, by the Albums page's code (the Mac and the iPhone).
    album_sorting: BTreeMap<String, String>,
    /// Where each page started, for a section deleted: its pages go back there.
    homes: Vec<(String, String)>,
    /// The sections that list albums.
    albums: Vec<String>,
}

/// Linux's arrangement, as kept.
#[derive(Default, Serialize, Deserialize)]
struct LinuxSaved {
    #[serde(default)]
    sections: Vec<LinuxSection>,
    #[serde(default)]
    pages: Vec<(String, String)>,
}

#[derive(Serialize, Deserialize)]
struct LinuxSection {
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

/// The Mac's and the iPhone's layout, as kept; every key optional, as layouts kept before a key existed lack it.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppleSaved {
    sections: Option<Vec<AppleSection>>,
    entries: Option<Vec<AppleEntry>>,
    hidden_links: Option<Vec<String>>,
    hidden_dynamic_items: Option<Vec<String>>,
    album_limits: Option<BTreeMap<String, i64>>,
    album_sorting: Option<BTreeMap<String, String>>,
}

/// A section as the Mac keeps it: `hidden` always, `collapsed` only while it is.
#[derive(Deserialize)]
struct AppleSection {
    id: String,
    name: Option<String>,
    hidden: bool,
    collapsed: Option<bool>,
}

#[derive(Deserialize)]
struct AppleEntry {
    link: String,
    group: String,
}

/// The Mac's form as written, its keys in Foundation's sorted order.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppleWritten<'a> {
    album_limits: &'a BTreeMap<String, i64>,
    album_sorting: &'a BTreeMap<String, String>,
    entries: Vec<AppleEntryWritten<'a>>,
    hidden_dynamic_items: &'a BTreeSet<String>,
    hidden_links: Vec<&'a str>,
    sections: Vec<AppleSectionWritten<'a>>,
}

#[derive(Serialize)]
struct AppleEntryWritten<'a> {
    group: &'a str,
    link: &'a str,
}

#[derive(Serialize)]
struct AppleSectionWritten<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    collapsed: Option<bool>,
    hidden: bool,
    id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
}

impl Layout {
    /// The built-in layout, nothing hidden or moved.
    pub fn new(form: Form, defaults: Defaults) -> Layout {
        Layout::made_whole(form, defaults, Vec::new(), Vec::new())
    }

    /// Linux's layout as kept: its arrangement and what is hidden, each absent while never changed.
    pub fn linux(arrangement: Option<&str>, hidden: Option<&str>, defaults: Defaults) -> Layout {
        let saved = arrangement.and_then(|text| serde_json::from_str::<LinuxSaved>(text).ok()).unwrap_or_default();
        let sections = saved.sections.into_iter().map(|section| (section.id, section.name, false, false)).collect();
        let mut layout = Layout::made_whole(Form::Linux, defaults, sections, saved.pages);
        for id in hidden.unwrap_or_default().split(',').filter(|id| !id.is_empty()) {
            match id.strip_prefix("section:") {
                Some(section) => {
                    layout.set_section_hidden(section, true);
                }
                None => layout.set_hidden(id, true),
            }
        }
        layout
    }

    /// The Mac's and the iPhone's layout as kept, in either of its forms; what is neither reads as the built-in one.
    pub fn apple(stored: &str, defaults: Defaults) -> Layout {
        let saved = serde_json::from_str::<AppleSaved>(stored).ok();
        let entries = saved.as_ref().and_then(|saved| saved.entries.as_ref()).map(|entries| entries.iter().map(|entry| (entry.link.clone(), entry.group.clone())).collect());
        // The first form: the entries alone.
        let entries = entries.or_else(|| serde_json::from_str::<Vec<AppleEntry>>(stored).ok().map(|entries| entries.into_iter().map(|entry| (entry.link, entry.group)).collect()));
        let Some(saved) = saved else {
            return Layout::made_whole(Form::Apple, defaults, Vec::new(), entries.unwrap_or_default());
        };
        let sections = saved.sections.unwrap_or_default().into_iter().map(|section| (section.id, section.name, section.hidden, section.collapsed == Some(true))).collect();
        let mut layout = Layout::made_whole(Form::Apple, defaults, sections, entries.unwrap_or_default());
        for link in saved.hidden_links.unwrap_or_default() {
            layout.set_hidden(&link, true);
        }
        layout.hidden_items = saved.hidden_dynamic_items.unwrap_or_default().into_iter().collect();
        layout.album_limits = saved.album_limits.unwrap_or_default().into_iter().filter(|(_, limit)| *limit >= 0).collect();
        layout.album_sorting = saved.album_sorting.unwrap_or_default();
        layout
    }

    /// The layout made whole from what was kept: a section or page it does not know is left out, a page placed twice
    /// keeps its first place, a page not placed joins the end of the section it started in, and a section of the
    /// person's own needs a name and an id of its form.
    fn made_whole(form: Form, defaults: Defaults, kept: Vec<(String, Option<String>, bool, bool)>, placed: Vec<(String, String)>) -> Layout {
        let built_in = |id: &str| defaults.iter().any(|(section, _)| *section == id);
        let custom_id = |id: &str| match form {
            Form::Linux => id.starts_with(CUSTOM),
            Form::Apple => is_uuid(id),
        };
        let mut seen = HashSet::new();
        let mut sections: Vec<Section> = kept
            .into_iter()
            .filter(|(id, name, _, _)| built_in(id) || (custom_id(id) && name.as_deref().is_some_and(|name| !name.trim().is_empty())))
            .filter(|(id, _, _, _)| seen.insert(id.clone()))
            .map(|(id, name, hidden, collapsed)| Section { custom: !built_in(&id), id, name, hidden, collapsed })
            .collect();
        for (id, _) in defaults {
            if !seen.contains(*id) {
                sections.push(Section { id: (*id).to_owned(), name: None, hidden: false, collapsed: false, custom: false });
            }
        }
        let homes: Vec<(String, String)> = defaults.iter().flat_map(|(section, pages)| pages.iter().map(move |page| ((*page).to_owned(), (*section).to_owned()))).collect();
        let albums: Vec<String> = defaults.iter().filter(|(_, pages)| pages.is_empty()).map(|(section, _)| (*section).to_owned()).collect();
        let mut layout = Layout { form, sections, pages: Vec::new(), hidden: Vec::new(), hidden_items: BTreeSet::new(), album_limits: BTreeMap::new(), album_sorting: BTreeMap::new(), homes, albums };
        let mut done = HashSet::new();
        for (page, section) in placed {
            if layout.home_of(&page).is_some() && layout.takes_pages(&section) && done.insert(page.clone()) {
                layout.pages.push((page, section));
            }
        }
        for (page, home) in layout.homes.clone() {
            if !done.contains(&page) {
                layout.put(page, home, None);
            }
        }
        layout
    }

    /// Linux's arrangement, as kept: its sections and where each page sits.
    pub fn linux_arrangement(&self) -> String {
        let saved = LinuxSaved {
            sections: self.sections.iter().map(|section| LinuxSection { id: section.id.clone(), name: section.name.clone() }).collect(),
            pages: self.pages.clone(),
        };
        serde_json::to_string(&saved).unwrap_or_default()
    }

    /// What Linux keeps hidden, the sections first; none while nothing is.
    pub fn linux_hidden(&self) -> Option<String> {
        let sections = self.sections.iter().filter(|section| section.hidden).map(|section| format!("section:{}", section.id));
        let ids: Vec<String> = sections.chain(self.hidden.iter().cloned()).collect();
        (!ids.is_empty()).then(|| ids.join(","))
    }

    /// The layout as the Mac and the iPhone keep it.
    pub fn apple_json(&self) -> String {
        let mut hidden_links: Vec<&str> = self.hidden.iter().map(String::as_str).collect();
        hidden_links.sort_unstable();
        let written = AppleWritten {
            album_limits: &self.album_limits,
            album_sorting: &self.album_sorting,
            entries: self.pages.iter().map(|(page, section)| AppleEntryWritten { group: section, link: page }).collect(),
            hidden_dynamic_items: &self.hidden_items,
            hidden_links,
            sections: self
                .sections
                .iter()
                .map(|section| AppleSectionWritten { collapsed: section.collapsed.then_some(true), hidden: section.hidden, id: &section.id, name: section.name.as_deref() })
                .collect(),
        };
        serde_json::to_string(&written).unwrap_or_default()
    }

    /// The sections, in order.
    pub fn sections(&self) -> &[Section] {
        &self.sections
    }

    pub fn section(&self, id: &str) -> Option<&Section> {
        self.sections.iter().find(|section| section.id == id)
    }

    /// The pages of a section, in order, hidden or not.
    pub fn pages_in(&self, section: &str) -> Vec<&str> {
        self.pages.iter().filter(|(_, at)| at == section).map(|(page, _)| page.as_str()).collect()
    }

    /// The section a page sits in.
    pub fn section_of(&self, page: &str) -> Option<&str> {
        self.pages.iter().find(|(known, _)| known == page).map(|(_, section)| section.as_str())
    }

    fn home_of(&self, page: &str) -> Option<&str> {
        self.homes.iter().find(|(known, _)| known == page).map(|(_, section)| section.as_str())
    }

    /// Whether a section takes pages: on Linux, the albums' sections list albums instead.
    pub fn takes_pages(&self, section: &str) -> bool {
        self.section(section).is_some() && (self.form == Form::Apple || !self.lists_albums(section))
    }

    /// Whether a section lists albums: a built-in one without pages of its own.
    pub fn lists_albums(&self, section: &str) -> bool {
        self.albums.iter().any(|known| known == section)
    }

    /// Put `page` into `section`, before `before` (a page of it), or at its end.
    fn put(&mut self, page: String, section: String, before: Option<&str>) {
        let at = before
            .and_then(|before| self.pages.iter().position(|(known, at)| known == before && *at == section))
            .or_else(|| self.pages.iter().rposition(|(_, at)| *at == section).map(|last| last + 1))
            .unwrap_or_else(|| {
                // An empty section: after the pages of the sections above it.
                let order: Vec<&str> = self.sections.iter().map(|known| known.id.as_str()).collect();
                let rank = |id: &str| order.iter().position(|known| *known == id).unwrap_or(usize::MAX);
                let mine = rank(&section);
                self.pages.iter().rposition(|(_, at)| rank(at) < mine).map_or(0, |last| last + 1)
            });
        self.pages.insert(at, (page, section));
    }

    /// Move a page into a section, before one of its pages, or to its end. Whether anything changed: nothing does for
    /// a section that takes no pages, a page it does not know, or a page to go before that is the page itself or not in
    /// the section.
    pub fn move_page(&mut self, page: &str, section: &str, before: Option<&str>) -> bool {
        if !self.takes_pages(section) || before == Some(page) || self.home_of(page).is_none() {
            return false;
        }
        if before.is_some_and(|before| !self.pages_in(section).contains(&before)) {
            return false;
        }
        let previous = self.pages.clone();
        self.pages.retain(|(known, _)| known != page);
        self.put(page.to_owned(), section.to_owned(), before);
        self.pages != previous
    }

    /// Move a page into a section beside one of its pages, before it or after it.
    pub fn move_beside(&mut self, page: &str, section: &str, target: &str, after: bool) -> bool {
        if !after {
            return self.move_page(page, section, Some(target));
        }
        let others: Vec<&str> = self.pages_in(section).into_iter().filter(|known| *known != page).collect();
        let Some(index) = others.iter().position(|known| *known == target) else { return false };
        let next = others.get(index + 1).map(|next| (*next).to_owned());
        self.move_page(page, section, next.as_deref())
    }

    /// Move a page to where a drop landed among the pages a section shows: before the one at `index`, or after the last.
    /// The pages not shown between them keep their places.
    pub fn move_among(&mut self, page: &str, section: &str, index: usize, shown: &[&str]) -> bool {
        match (shown.get(index), shown.last()) {
            (Some(target), _) => self.move_beside(page, section, target, false),
            (None, Some(last)) => self.move_beside(page, section, last, true),
            (None, None) => self.move_page(page, section, None),
        }
    }

    /// Move a page one place up (`by` -1) or down (1) in its section; from its first or last place, into the end of
    /// the section above, or the start of the one below, that takes pages.
    pub fn step_page(&mut self, page: &str, by: i32) -> bool {
        let Some(section) = self.section_of(page).map(str::to_owned) else { return false };
        let pages: Vec<String> = self.pages_in(&section).into_iter().map(str::to_owned).collect();
        let Some(index) = pages.iter().position(|known| known == page) else { return false };
        if by < 0 && index > 0 {
            return self.move_page(page, &section, Some(&pages[index - 1]));
        }
        if by > 0 && index + 1 < pages.len() {
            return self.move_page(page, &section, pages.get(index + 2).map(String::as_str));
        }
        let order: Vec<String> = self.sections.iter().map(|known| known.id.clone()).filter(|id| self.takes_pages(id)).collect();
        let Some(here) = order.iter().position(|id| *id == section) else { return false };
        let next = if by < 0 { here.checked_sub(1) } else { Some(here + 1) };
        let Some(next) = next.and_then(|next| order.get(next)) else { return false };
        let first = (by > 0).then(|| self.pages_in(next).first().map(|first| (*first).to_owned())).flatten();
        self.move_page(page, next, first.as_deref())
    }

    /// A new section of the person's own, last, named `name`; its id. None for a name of nothing but spaces.
    pub fn add_section(&mut self, name: &str) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        let id = match self.form {
            Form::Linux => {
                let next = self.sections.iter().filter_map(|section| section.id.strip_prefix(CUSTOM)?.parse::<u32>().ok()).max().unwrap_or(0) + 1;
                format!("{CUSTOM}{next}")
            }
            Form::Apple => new_uuid()?,
        };
        self.sections.push(Section { id: id.clone(), name: Some(name.to_owned()), hidden: false, collapsed: false, custom: true });
        Some(id)
    }

    /// Name a section of the person's own again.
    pub fn rename_section(&mut self, id: &str, name: &str) -> bool {
        let name = name.trim();
        match self.sections.iter_mut().find(|section| section.id == id && section.custom) {
            Some(section) if !name.is_empty() => {
                section.name = Some(name.to_owned());
                true
            }
            _ => false,
        }
    }

    /// Delete a section of the person's own; its pages go back to where they started, at the end.
    pub fn remove_section(&mut self, id: &str) -> bool {
        if !self.sections.iter().any(|section| section.id == id && section.custom) {
            return false;
        }
        let pages: Vec<String> = self.pages_in(id).into_iter().map(str::to_owned).collect();
        self.sections.retain(|section| section.id != id);
        for page in pages {
            if let Some(home) = self.home_of(&page).map(str::to_owned) {
                self.pages.retain(|(known, _)| *known != page);
                self.put(page, home, None);
            }
        }
        true
    }

    /// Move a section `by` places, up for less than 0; nowhere past the first or the last.
    pub fn shift_section(&mut self, id: &str, by: i64) -> bool {
        let Some(index) = self.sections.iter().position(|section| section.id == id) else { return false };
        let target = index as i64 + by;
        if by == 0 || target < 0 || target as usize >= self.sections.len() {
            return false;
        }
        let section = self.sections.remove(index);
        self.sections.insert(target as usize, section);
        true
    }

    /// Hide a section, or show it again; its pages keep their places, and each its own hiding.
    pub fn set_section_hidden(&mut self, id: &str, hidden: bool) -> bool {
        self.section_mut(id).is_some_and(|section| std::mem::replace(&mut section.hidden, hidden) != hidden)
    }

    /// Collapse a section, or expand it.
    pub fn set_section_collapsed(&mut self, id: &str, collapsed: bool) -> bool {
        self.section_mut(id).is_some_and(|section| std::mem::replace(&mut section.collapsed, collapsed) != collapsed)
    }

    fn section_mut(&mut self, id: &str) -> Option<&mut Section> {
        self.sections.iter_mut().find(|section| section.id == id)
    }

    /// The pages hidden, in the order they were hidden.
    pub fn hidden(&self) -> &[String] {
        &self.hidden
    }

    pub fn is_hidden(&self, page: &str) -> bool {
        self.hidden.iter().any(|known| known == page)
    }

    /// Hide a page, or show it again; a page the layout does not know is never hidden.
    pub fn set_hidden(&mut self, page: &str, hidden: bool) {
        self.hidden.retain(|known| known != page);
        if hidden && self.home_of(page).is_some() {
            self.hidden.push(page.to_owned());
        }
    }

    /// The albums and partners hidden, by the keys the app makes for them.
    pub fn hidden_items(&self) -> impl Iterator<Item = &str> {
        self.hidden_items.iter().map(String::as_str)
    }

    pub fn is_item_hidden(&self, key: &str) -> bool {
        self.hidden_items.contains(key)
    }

    /// Hide an album or a partner of an account, or show it again, by the key the app makes for it.
    pub fn set_item_hidden(&mut self, key: &str, hidden: bool) {
        if hidden {
            self.hidden_items.insert(key.to_owned());
        } else {
            self.hidden_items.remove(key);
        }
    }

    /// How many albums a section lists, none for all of them: `ALBUM_LIMIT` until the person chooses.
    pub fn album_limit(&self, section: &str) -> Option<usize> {
        match self.album_limits.get(section) {
            None => Some(ALBUM_LIMIT),
            Some(0) => None,
            Some(limit) => usize::try_from(*limit).ok(),
        }
    }

    /// List so many albums in a section, at least one, or all of them for none, kept as 0 so it is told from a section
    /// never set.
    pub fn set_album_limit(&mut self, section: &str, limit: Option<usize>) {
        let kept = limit.map_or(0, |limit| i64::try_from(limit.max(1)).unwrap_or(i64::MAX));
        self.album_limits.insert(section.to_owned(), kept);
    }

    /// What a section's albums are sorted by, by the Albums page's code; none until the person chooses.
    pub fn album_sorting(&self, section: &str) -> Option<&str> {
        self.album_sorting.get(section).map(String::as_str)
    }

    pub fn set_album_sorting(&mut self, section: &str, sort_by: Option<&str>) {
        match sort_by {
            Some(sort_by) => self.album_sorting.insert(section.to_owned(), sort_by.to_owned()),
            None => self.album_sorting.remove(section),
        };
    }
}

/// How Linux's own sections' ids begin; a built-in section's id is its heading in English (`Photos`), or `my-albums`
/// and `shared-albums`.
const CUSTOM: &str = "custom-";

/// Whether an id is a UUID as Foundation writes and reads one (`E621E1F8-C36C-495A-93FC-0C247A3E6E5F`), in either case.
fn is_uuid(id: &str) -> bool {
    id.len() == 36 && id.char_indices().all(|(index, letter)| if matches!(index, 8 | 13 | 18 | 23) { letter == '-' } else { letter.is_ascii_hexdigit() })
}

/// A random UUID, as Foundation's `UUID().uuidString` writes one: version 4, upper-case.
fn new_uuid() -> Option<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    Some(format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Mac's and the iPhone's built-in sections and pages.
    const APPLE: Defaults = &[
        ("photos", &["search", "library", "favorites", "videos"]),
        ("explore", &["map", "places", "memories", "tags", "folders"]),
        ("collections", &["albums", "people"]),
        ("sharing", &["sharedLinks", "partners"]),
        ("utilities", &["duplicates", "largeFiles", "geolocation", "archive", "trash", "locked"]),
        ("myAlbums", &[]),
        ("sharedAlbums", &[]),
    ];

    /// Linux's, shortened.
    const LINUX: Defaults = &[("Photos", &["library", "favorites", "videos"]), ("Explore", &["map", "places"]), ("my-albums", &[])];

    fn linux(saved: &str) -> Layout {
        Layout::linux(Some(saved), None, LINUX)
    }

    fn order(layout: &Layout) -> Vec<String> {
        layout.sections().iter().map(|section| format!("{}:{}", section.name.as_deref().unwrap_or(&section.id), layout.pages_in(&section.id).join(","))).collect()
    }

    fn every_page_once(layout: &Layout) -> bool {
        let mut pages: Vec<&str> = layout.sections().iter().flat_map(|section| layout.pages_in(&section.id)).collect();
        pages.sort_unstable();
        let mut all: Vec<&str> = APPLE.iter().flat_map(|(_, pages)| pages.iter().copied()).collect();
        all.sort_unstable();
        pages == all
    }

    fn ids(layout: &Layout) -> Vec<&str> {
        layout.sections().iter().map(|section| section.id.as_str()).collect()
    }

    #[test]
    fn pages_move_before_and_after_others_on_the_mac_and_a_move_that_changes_nothing_says_so() {
        let mut layout = Layout::new(Form::Apple, APPLE);
        assert_eq!(layout.pages_in("photos"), ["search", "library", "favorites", "videos"]);
        assert_eq!(layout.pages_in("utilities").last(), Some(&"locked"));
        assert!(layout.move_beside("videos", "photos", "search", false));
        assert_eq!(layout.pages_in("photos"), ["videos", "search", "library", "favorites"]);
        assert!(layout.move_beside("videos", "photos", "favorites", true));
        assert_eq!(layout.pages_in("photos").last(), Some(&"videos"));
        assert!(layout.move_beside("locked", "photos", "library", false));
        assert!(!layout.pages_in("utilities").contains(&"locked"));
        assert_eq!(layout.pages_in("photos"), ["search", "locked", "library", "favorites", "videos"]);
        let saved = layout.apple_json();
        assert!(!layout.move_beside("library", "photos", "library", false));
        assert!(!layout.move_beside("library", "photos", "archive", false), "a page of another section");
        assert_eq!(layout.apple_json(), saved);
        let restored = Layout::apple(&saved, APPLE);
        for (section, _) in APPLE {
            assert_eq!(restored.pages_in(section), layout.pages_in(section));
        }
        // Empty sections take a page; every page stays in the layout, whether its page is offered or not.
        for page in layout.pages_in("collections").into_iter().map(str::to_owned).collect::<Vec<_>>() {
            layout.move_page(&page, "photos", None);
        }
        assert!(layout.pages_in("collections").is_empty());
        assert!(layout.move_page("map", "collections", None));
        assert_eq!(layout.pages_in("collections"), ["map"]);
        assert!(every_page_once(&layout));
    }

    #[test]
    fn a_drop_lands_among_the_pages_a_section_shows() {
        let mut layout = Layout::new(Form::Apple, APPLE);
        // A lower page moved upwards.
        assert!(layout.move_beside("videos", "photos", "library", false));
        assert_eq!(layout.pages_in("photos"), ["search", "videos", "library", "favorites"]);
        assert!(!layout.move_beside("videos", "photos", "library", false));
        assert!(layout.move_beside("videos", "photos", "favorites", true));
        assert_eq!(layout.pages_in("photos"), ["search", "library", "favorites", "videos"]);
        assert!(!layout.move_beside("videos", "photos", "favorites", true));
        // A drop's place is among the pages shown, the dragged one with them.
        let shown = ["search", "library", "favorites", "videos"];
        assert!(layout.move_among("videos", "photos", 1, &shown));
        assert_eq!(layout.pages_in("photos"), ["search", "videos", "library", "favorites"]);
        let reordered = ["search", "videos", "library", "favorites"];
        assert!(!layout.move_among("videos", "photos", 1, &reordered), "dropped on its own place");
        assert!(!layout.move_among("videos", "photos", 2, &reordered));
        assert!(layout.move_among("search", "photos", 4, &reordered));
        assert_eq!(layout.pages_in("photos"), ["videos", "library", "favorites", "search"]);
        assert!(layout.move_among("map", "photos", 0, &["videos", "library", "favorites", "search"]));
        assert_eq!(layout.pages_in("photos").first(), Some(&"map"));
        assert!(!layout.pages_in("explore").contains(&"map"));
        // A page hidden is not shown, so a drop after the last page shown lands before it.
        layout.set_hidden("search", true);
        assert!(layout.move_among("places", "photos", 4, &["map", "videos", "library", "favorites"]));
        assert_eq!(layout.pages_in("photos"), ["map", "videos", "library", "favorites", "places", "search"]);
        let empty = layout.add_section("Empty").unwrap();
        assert!(layout.move_among("places", &empty, 0, &[]));
        assert_eq!(layout.pages_in(&empty), ["places"]);
    }

    #[test]
    fn the_macs_layout_is_made_whole_from_what_was_kept_in_either_form() {
        // Unknown, repeated and missing entries neither lose a page nor show one twice.
        let repaired = Layout::apple(r#"[{"link":"library","group":"utilities"},{"link":"library","group":"photos"},{"link":"unknown","group":"photos"},{"link":"search","group":"unknown"}]"#, APPLE);
        assert_eq!(repaired.pages_in("utilities").first(), Some(&"library"));
        assert!(!repaired.pages_in("photos").contains(&"library"));
        for layout in [&repaired, &Layout::apple("invalid", APPLE), &Layout::apple("", APPLE), &Layout::new(Form::Apple, APPLE)] {
            assert!(every_page_once(layout));
        }
        // The first form, the entries alone, keeps its order.
        let first = Layout::apple(r#"[{"link":"videos","group":"photos"},{"link":"library","group":"utilities"}]"#, APPLE);
        assert_eq!(first.pages_in("photos").first(), Some(&"videos"));
        assert_eq!(first.pages_in("utilities").first(), Some(&"library"));
        assert_eq!(ids(&first), ["photos", "explore", "collections", "sharing", "utilities", "myAlbums", "sharedAlbums"]);
    }

    #[test]
    fn sections_of_ones_own_hide_rename_shift_and_keep_on_the_mac() {
        let mut layout = Layout::apple(r#"[{"link":"videos","group":"photos"},{"link":"library","group":"utilities"}]"#, APPLE);
        assert!(layout.add_section("  ").is_none());
        let travel = layout.add_section("  Travel  ").unwrap();
        assert!(is_uuid(&travel) && travel == travel.to_uppercase(), "a UUID as Foundation writes one: {travel}");
        assert_eq!(layout.sections().last().and_then(|section| section.name.as_deref()), Some("Travel"));
        assert!(layout.move_page("map", &travel, None));
        assert!(layout.move_beside("places", &travel, "map", false));
        assert_eq!(layout.pages_in(&travel), ["places", "map"]);
        layout.set_hidden("map", true);
        layout.set_section_hidden(&travel, true);
        layout.set_item_hidden("account-a|album:123", true);
        assert!(!layout.is_item_hidden("account-b|album:123"));
        let mut layout = Layout::apple(&layout.apple_json(), APPLE);
        assert!(layout.is_hidden("map") && layout.is_item_hidden("account-a|album:123"));
        assert!(layout.section(&travel).is_some_and(|section| section.hidden));
        assert_eq!(layout.pages_in(&travel), ["places", "map"]);
        layout.set_section_hidden(&travel, false);
        assert!(layout.is_hidden("map"), "showing a section again keeps its pages hidden");
        layout.set_hidden("map", false);
        layout.set_item_hidden("account-a|album:123", false);
        assert!(!layout.is_hidden("map") && !layout.is_item_hidden("account-a|album:123"));
        assert!(layout.rename_section(&travel, "  Trips  "));
        assert!(!layout.rename_section(&travel, "   "));
        assert_eq!(layout.sections().last().and_then(|section| section.name.as_deref()), Some("Trips"));
        assert!(!layout.rename_section("photos", "Not a section of ones own"));
        assert_eq!(layout.sections()[0].name, None);
        assert!(layout.shift_section(&travel, -1));
        assert_eq!(layout.sections()[layout.sections().len() - 2].id, travel);
        assert!(!layout.shift_section(&travel, 0) && !layout.shift_section("photos", -1) && !layout.shift_section("missing", 1));
        for id in ids(&layout).into_iter().map(str::to_owned).collect::<Vec<_>>() {
            layout.set_section_hidden(&id, true);
        }
        assert!(Layout::apple(&layout.apple_json(), APPLE).sections().iter().all(|section| section.hidden));
        layout.set_section_hidden(&travel, false);
        assert_eq!(layout.sections().iter().filter(|section| !section.hidden).map(|section| section.id.as_str()).collect::<Vec<_>>(), [travel.as_str()]);
        assert!(!layout.move_page("search", "missing-section", None));
        let reset = Layout::apple("", APPLE);
        assert!(reset.sections().iter().all(|section| !section.hidden && !section.is_custom()));
        assert!(reset.hidden().is_empty());
        // A section of one's own lost from what was kept gives its pages back to where they started, and a section
        // kept twice is one.
        let mut kept: serde_json::Value = serde_json::from_str(&layout.apple_json()).unwrap();
        let sections = kept["sections"].as_array_mut().unwrap();
        sections.retain(|section| section["id"] != travel.as_str());
        let first = sections[0].clone();
        sections.push(first);
        let repaired = Layout::apple(&kept.to_string(), APPLE);
        assert_eq!(repaired.sections().len(), APPLE.len());
        assert!(repaired.pages_in("explore").contains(&"map") && repaired.pages_in("explore").contains(&"places"));
    }

    #[test]
    fn a_section_deleted_on_the_mac_gives_its_pages_back_and_keeps_what_else_was_hidden() {
        let mut layout = Layout::new(Form::Apple, APPLE);
        let deleted = layout.add_section("Remove me").unwrap();
        let kept = layout.add_section("Keep me").unwrap();
        layout.move_page("map", &deleted, None);
        layout.move_page("favorites", &deleted, None);
        layout.move_page("videos", &kept, None);
        layout.set_hidden("map", true);
        layout.set_section_hidden("utilities", true);
        layout.set_item_hidden("account-a|album:123", true);
        let built_in: Vec<Section> = layout.sections().iter().filter(|section| !section.is_custom()).cloned().collect();
        assert!(!layout.remove_section("photos") && !layout.remove_section("missing-section"));
        assert_eq!(layout.sections().iter().filter(|section| !section.is_custom()).cloned().collect::<Vec<_>>(), built_in);
        assert!(layout.remove_section(&deleted));
        assert!(layout.section(&deleted).is_none() && layout.pages_in(&deleted).is_empty());
        assert_eq!(layout.pages_in("explore").last(), Some(&"map"));
        assert_eq!(layout.pages_in("photos").last(), Some(&"favorites"));
        assert_eq!(layout.pages_in(&kept), ["videos"]);
        assert!(layout.is_hidden("map") && layout.is_item_hidden("account-a|album:123"));
        assert!(layout.section("utilities").is_some_and(|section| section.hidden));
        assert_eq!(Layout::apple(&layout.apple_json(), APPLE).apple_json(), layout.apple_json());
        // A layout kept before a key existed keeps its sections and order.
        let mut partial: serde_json::Value = serde_json::from_str(&layout.apple_json()).unwrap();
        let object = partial.as_object_mut().unwrap();
        object.remove("hiddenDynamicItems");
        object.remove("hiddenLinks");
        let partial = Layout::apple(&partial.to_string(), APPLE);
        assert_eq!(partial.sections(), layout.sections());
        assert_eq!(partial.pages_in(&kept), ["videos"]);
        assert!(!partial.is_hidden("map"));
    }

    #[test]
    fn album_sections_keep_their_count_and_order_on_the_mac_and_sections_collapse() {
        let mut layout = Layout::new(Form::Apple, APPLE);
        assert_eq!(layout.album_limit("myAlbums"), Some(5));
        layout.set_album_limit("myAlbums", Some(6));
        layout.set_album_limit("sharedAlbums", Some(0));
        layout.set_album_sorting("myAlbums", Some("MostRecentPhoto"));
        let mut layout = Layout::apple(&layout.apple_json(), APPLE);
        assert_eq!((layout.album_limit("myAlbums"), layout.album_limit("sharedAlbums")), (Some(6), Some(1)));
        assert_eq!((layout.album_sorting("myAlbums"), layout.album_sorting("sharedAlbums")), (Some("MostRecentPhoto"), None));
        layout.set_album_limit("myAlbums", None);
        assert_eq!(Layout::apple(&layout.apple_json(), APPLE).album_limit("myAlbums"), None);
        assert_eq!(Layout::apple(r#"{"albumLimits":{"myAlbums":-3}}"#, APPLE).album_limit("myAlbums"), Some(5));
        assert!(layout.lists_albums("sharedAlbums") && !layout.lists_albums("photos"));
        // The Mac's album sections take pages above their albums.
        assert!(layout.takes_pages("myAlbums") && layout.move_page("map", "myAlbums", None));
        // Collapsing is kept for each section, and a layout kept before it existed is expanded.
        assert!(layout.sections().iter().all(|section| !section.collapsed));
        assert!(layout.set_section_collapsed("utilities", true));
        let mut layout = Layout::apple(&layout.apple_json(), APPLE);
        assert_eq!(layout.sections().iter().filter(|section| section.collapsed).map(|section| section.id.as_str()).collect::<Vec<_>>(), ["utilities"]);
        layout.set_section_collapsed("utilities", false);
        assert!(!layout.apple_json().contains("collapsed"));
    }

    #[test]
    fn the_macs_form_is_written_as_foundation_wrote_it() {
        let mut layout = Layout::apple(r#"{"sections":[{"id":"photos","hidden":false},{"id":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","name":"Trips","hidden":true}],"entries":[{"link":"places","group":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13"}],"hiddenLinks":["tags","map"],"hiddenDynamicItems":["b","a"]}"#, APPLE);
        layout.set_section_collapsed("utilities", true);
        let written = layout.apple_json();
        assert!(written.starts_with(r#"{"albumLimits":{},"albumSorting":{},"entries":[{"group":"photos","link":"search"},"#), "{written}");
        assert!(written.contains(r#"{"group":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","link":"places"}"#), "{written}");
        assert!(written.contains(r#""hiddenDynamicItems":["a","b"],"hiddenLinks":["map","tags"],"sections":[{"hidden":false,"id":"photos"},{"hidden":true,"id":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","name":"Trips"},"#), "{written}");
        assert!(written.contains(r#"{"collapsed":true,"hidden":false,"id":"utilities"}"#), "{written}");
        assert_eq!(layout.pages_in("8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13"), ["places"]);
        // A section of one's own needs a UUID and a name on the Mac; Linux's ids are not its.
        let other = Layout::apple(r#"{"sections":[{"id":"custom-1","name":"Kids","hidden":false},{"id":"8a1f6c52-3b9e-4d7a-9c1e-2f4b6d8e0a13","name":" ","hidden":false}]}"#, APPLE);
        assert_eq!(other.sections().len(), APPLE.len());
        // A section kept without whether it is hidden is no layout Foundation reads.
        assert!(Layout::apple(r#"{"sections":[{"id":"photos"}],"hiddenLinks":["map"]}"#, APPLE).hidden().is_empty());
    }

    #[test]
    fn linuxs_layout_is_made_whole_from_what_was_remembered() {
        assert_eq!(order(&linux("")), ["Photos:library,favorites,videos", "Explore:map,places", "my-albums:"]);
        assert_eq!(order(&Layout::linux(None, None, LINUX)), order(&linux("")));
        // An unknown page and section go, a nameless section of one's own goes, and so does the Mac's, and a new page
        // joins its home.
        let saved = r#"{"sections":[{"id":"Explore"},{"id":"custom-1","name":"Kids"},{"id":"custom-2"},{"id":"Gone"},{"id":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","name":"Mac"}],
                        "pages":[["map","custom-1"],["gone","Photos"],["videos","Photos"],["library","Photos"],["places","my-albums"]]}"#;
        assert_eq!(order(&linux(saved)), ["Explore:places", "Kids:map", "Photos:videos,library,favorites", "my-albums:"]);
    }

    #[test]
    fn pages_move_within_and_between_sections_on_linux() {
        let mut layout = linux("");
        assert!(layout.move_page("videos", "Photos", Some("library")));
        assert_eq!(layout.pages_in("Photos"), ["videos", "library", "favorites"]);
        assert!(layout.step_page("library", -1));
        assert_eq!(layout.pages_in("Photos"), ["library", "videos", "favorites"]);
        // From the last place down: the start of the next section that takes pages.
        assert!(layout.step_page("favorites", 1));
        assert_eq!(order(&layout), ["Photos:library,videos", "Explore:favorites,map,places", "my-albums:"]);
        // From the first place up: the end of the section above. Nowhere above the first section, and never into
        // the albums.
        assert!(layout.step_page("favorites", -1));
        assert!(!layout.step_page("library", -1));
        assert!(!layout.step_page("places", 1));
        assert!(!layout.takes_pages("my-albums") && !layout.move_page("map", "my-albums", None));
        assert!(!layout.move_page("map", "Photos", Some("places")), "before a page of another section");
        assert_eq!(order(&layout), ["Photos:library,videos,favorites", "Explore:map,places", "my-albums:"]);
    }

    #[test]
    fn sections_of_ones_own_come_rename_move_and_go_on_linux() {
        let mut layout = linux("");
        let kids = layout.add_section(" Kids ").unwrap();
        assert_eq!(kids, "custom-1");
        assert!(layout.add_section("  ").is_none());
        assert!(layout.move_page("places", &kids, None));
        assert!(layout.move_page("library", &kids, Some("places")));
        assert!(layout.rename_section(&kids, "Family"));
        assert!(!layout.rename_section("Photos", "Mine"));
        assert!(layout.shift_section(&kids, -1));
        assert!(!layout.shift_section("Photos", -1));
        assert_eq!(order(&layout), ["Photos:favorites,videos", "Explore:map", "Family:library,places", "my-albums:"]);
        assert_eq!(Layout::linux(Some(&layout.linux_arrangement()), layout.linux_hidden().as_deref(), LINUX), layout);
        assert_eq!(layout.clone().add_section("Pets").as_deref(), Some("custom-2"));
        // Deleted, its pages go home, at the end, and its hiding with it.
        layout.set_section_hidden(&kids, true);
        assert!(layout.remove_section(&kids));
        assert!(!layout.remove_section("Photos"));
        assert_eq!(order(&layout), ["Photos:favorites,videos,library", "Explore:map,places", "my-albums:"]);
        assert_eq!(layout.linux_hidden(), None);
    }

    #[test]
    fn linux_keeps_what_is_hidden_beside_the_layout() {
        let mut layout = Layout::linux(None, Some("map,section:Explore,,gone,section:Gone"), LINUX);
        assert!(layout.is_hidden("map") && !layout.is_hidden("places") && !layout.is_hidden("gone"));
        assert!(layout.section("Explore").is_some_and(|section| section.hidden));
        assert_eq!(layout.linux_hidden().as_deref(), Some("section:Explore,map"));
        layout.set_hidden("favorites", true);
        layout.set_hidden("map", true);
        assert_eq!(layout.hidden(), ["favorites", "map"]);
        layout.set_hidden("map", false);
        layout.set_section_hidden("Explore", false);
        assert_eq!(layout.linux_hidden().as_deref(), Some("favorites"));
        layout.set_hidden("favorites", false);
        assert_eq!(layout.linux_hidden(), None);
        // Linux's form keeps no collapsed sections.
        layout.set_section_collapsed("Photos", true);
        assert!(!layout.linux_arrangement().contains("collapsed"));
    }
}
