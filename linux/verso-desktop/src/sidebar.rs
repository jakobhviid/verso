//! The sidebar as Edit Sidebar arranges it, after the Mac gallery's `SidebarLayout`: its sections in order, the
//! built-in ones and the user's own, which page sits in which and in what order (`Layout`), and what is hidden, pages
//! and whole sections by id. Remembered in the gallery's settings.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::settings::Settings;

const KEY: &str = "sidebar.hidden";
const LAYOUT_KEY: &str = "sidebar.layout";
/// The user's own sections' ids begin so; a built-in section's id is its heading in English (`Photos`), or
/// `my-albums` and `shared-albums`, as hidden sections have been remembered by them (`section:Photos`).
const CUSTOM: &str = "custom-";

/// A section of the sidebar: a built-in one, or the user's own with its name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl Section {
    pub fn is_custom(&self) -> bool {
        self.id.starts_with(CUSTOM)
    }
}

/// The built-in sections in their first order, each with its pages; a section with none lists albums, and takes no
/// pages.
pub type Defaults<'a> = &'a [(&'a str, &'a [&'a str])];

/// How the sidebar is arranged: its sections in order, and each page with the section it sits in, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    pub sections: Vec<Section>,
    pub pages: Vec<(String, String)>,
    /// Where each page started, for a section deleted: its pages go back there.
    homes: Vec<(String, String)>,
    /// The sections that list albums, and take no pages.
    albums: Vec<String>,
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    #[serde(default)]
    sections: Vec<Section>,
    #[serde(default)]
    pages: Vec<(String, String)>,
}

impl Layout {
    /// The layout remembered, made whole: a section or page it no longer knows is left out, a new one joins at the
    /// end of its own section, and a section of the user's own needs a name.
    pub fn load(settings: &Settings, defaults: Defaults) -> Layout {
        let saved = settings.get(LAYOUT_KEY).and_then(|text| serde_json::from_str::<Saved>(&text).ok()).unwrap_or_default();
        Layout::from_saved(saved, defaults)
    }

    fn from_saved(saved: Saved, defaults: Defaults) -> Layout {
        let built_in = |id: &str| defaults.iter().any(|(section, _)| *section == id);
        let mut seen = HashSet::new();
        let mut sections: Vec<Section> = saved
            .sections
            .into_iter()
            .filter(|section| built_in(&section.id) || (section.is_custom() && section.name.as_deref().is_some_and(|name| !name.trim().is_empty())))
            .filter(|section| seen.insert(section.id.clone()))
            .collect();
        for (id, _) in defaults {
            if !seen.contains(*id) {
                sections.push(Section { id: (*id).to_owned(), name: None });
            }
        }
        let homes: Vec<(String, String)> = defaults.iter().flat_map(|(section, pages)| pages.iter().map(move |page| ((*page).to_owned(), (*section).to_owned()))).collect();
        let albums: Vec<String> = defaults.iter().filter(|(_, pages)| pages.is_empty()).map(|(section, _)| (*section).to_owned()).collect();
        let mut layout = Layout { sections, pages: Vec::new(), homes, albums };
        let mut placed = HashSet::new();
        for (page, section) in saved.pages {
            if layout.home_of(&page).is_some() && layout.takes_pages(&section) && placed.insert(page.clone()) {
                layout.pages.push((page, section));
            }
        }
        for (page, home) in layout.homes.clone() {
            if !placed.contains(&page) {
                layout.put(page, home, None);
            }
        }
        layout
    }

    pub fn save(&self, settings: &Settings) {
        let saved = Saved { sections: self.sections.clone(), pages: self.pages.clone() };
        if let Ok(text) = serde_json::to_string(&saved) {
            settings.set(LAYOUT_KEY, Some(&text));
        }
    }

    /// The pages of a section, in order.
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

    /// Whether a section takes pages: the albums' sections list albums instead.
    pub fn takes_pages(&self, section: &str) -> bool {
        self.sections.iter().any(|known| known.id == section) && !self.lists_albums(section)
    }

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

    /// Move a page into a section, before one of its pages, or to its end. Whether anything changed.
    pub fn move_page(&mut self, page: &str, section: &str, before: Option<&str>) -> bool {
        if !self.takes_pages(section) || before == Some(page) || self.home_of(page).is_none() {
            return false;
        }
        let previous = self.pages.clone();
        self.pages.retain(|(known, _)| known != page);
        self.put(page.to_owned(), section.to_owned(), before);
        self.pages != previous
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

    /// A new section of the user's own, last, named `name`; its id.
    pub fn add_section(&mut self, name: &str) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        let next = self.sections.iter().filter_map(|section| section.id.strip_prefix(CUSTOM)?.parse::<u32>().ok()).max().unwrap_or(0) + 1;
        let id = format!("{CUSTOM}{next}");
        self.sections.push(Section { id: id.clone(), name: Some(name.to_owned()) });
        Some(id)
    }

    /// Name a section of the user's own again.
    pub fn rename_section(&mut self, id: &str, name: &str) -> bool {
        let name = name.trim();
        match self.sections.iter_mut().find(|section| section.id == id && section.is_custom()) {
            Some(section) if !name.is_empty() => {
                section.name = Some(name.to_owned());
                true
            }
            _ => false,
        }
    }

    /// Delete a section of the user's own; its pages go back to where they started, at the end.
    pub fn remove_section(&mut self, id: &str) -> bool {
        if !self.sections.iter().any(|section| section.id == id && section.is_custom()) {
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

    /// Move a section one place up (`by` -1) or down (1).
    pub fn step_section(&mut self, id: &str, by: i32) -> bool {
        let Some(index) = self.sections.iter().position(|section| section.id == id) else { return false };
        let target = index as i64 + i64::from(by.signum());
        if target < 0 || target as usize >= self.sections.len() {
            return false;
        }
        self.sections.swap(index, target as usize);
        true
    }
}

/// The ids hidden: pages by their id, sections as `section:` and their name.
pub fn hidden(settings: &Settings) -> Vec<String> {
    settings.get(KEY).map(|text| text.split(',').filter(|id| !id.is_empty()).map(str::to_owned).collect()).unwrap_or_default()
}

pub fn is_hidden(settings: &Settings, id: &str) -> bool {
    hidden(settings).iter().any(|known| known == id)
}

pub fn set_hidden(settings: &Settings, id: &str, hide: bool) {
    let mut ids = hidden(settings);
    ids.retain(|known| known != id);
    if hide {
        ids.push(id.to_owned());
    }
    settings.set(KEY, (!ids.is_empty()).then(|| ids.join(",")).as_deref());
}

/// Reset Sidebar: everything shows again, where it first was.
pub fn reset(settings: &Settings) {
    settings.set(KEY, None);
    settings.set(LAYOUT_KEY, None);
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULTS: Defaults = &[("Photos", &["library", "favorites", "videos"]), ("Explore", &["map", "places"]), ("my-albums", &[])];

    fn layout(saved: &str) -> Layout {
        Layout::from_saved(serde_json::from_str(saved).unwrap_or_default(), DEFAULTS)
    }

    fn order(layout: &Layout) -> Vec<String> {
        layout.sections.iter().map(|section| format!("{}:{}", section.name.as_deref().unwrap_or(&section.id), layout.pages_in(&section.id).join(","))).collect()
    }

    #[test]
    fn a_layout_is_made_whole_from_what_was_remembered() {
        assert_eq!(order(&layout("")), ["Photos:library,favorites,videos", "Explore:map,places", "my-albums:"]);
        // An unknown page and section go, a nameless section of the user's own goes, and a new page joins its home.
        let saved = r#"{"sections":[{"id":"Explore"},{"id":"custom-1","name":"Kids"},{"id":"custom-2"},{"id":"Gone"}],
                        "pages":[["map","custom-1"],["gone","Photos"],["videos","Photos"],["library","Photos"],["places","my-albums"]]}"#;
        assert_eq!(order(&layout(saved)), ["Explore:places", "Kids:map", "Photos:videos,library,favorites", "my-albums:"]);
    }

    #[test]
    fn pages_move_within_and_between_sections() {
        let mut layout = layout("");
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
        assert!(!layout.move_page("map", "my-albums", None));
        assert_eq!(order(&layout), ["Photos:library,videos,favorites", "Explore:map,places", "my-albums:"]);
    }

    #[test]
    fn sections_of_ones_own_come_rename_move_and_go() {
        let mut layout = layout("");
        let kids = layout.add_section(" Kids ").unwrap();
        assert!(layout.add_section("  ").is_none());
        assert!(layout.move_page("places", &kids, None));
        assert!(layout.move_page("library", &kids, Some("places")));
        assert!(layout.rename_section(&kids, "Family"));
        assert!(!layout.rename_section("Photos", "Mine"));
        assert!(layout.step_section(&kids, -1));
        assert!(!layout.step_section("Photos", -1));
        assert_eq!(order(&layout), ["Photos:favorites,videos", "Explore:map", "Family:library,places", "my-albums:"]);
        let settings_folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&settings_folder.path().join("settings.json"));
        layout.save(&settings);
        assert_eq!(Layout::load(&settings, DEFAULTS), layout);
        // Deleted, its pages go home, at the end.
        assert!(layout.remove_section(&kids));
        assert!(!layout.remove_section("Photos"));
        assert_eq!(order(&layout), ["Photos:favorites,videos,library", "Explore:map,places", "my-albums:"]);
        reset(&settings);
        assert_eq!(order(&Layout::load(&settings, DEFAULTS)), ["Photos:library,favorites,videos", "Explore:map,places", "my-albums:"]);
    }

    #[test]
    fn pages_and_sections_hide_and_show_again() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        set_hidden(&settings, "map", true);
        set_hidden(&settings, "section:Sharing", true);
        set_hidden(&settings, "map", true);
        assert_eq!(hidden(&settings), ["section:Sharing", "map"]);
        assert!(is_hidden(&settings, "map") && !is_hidden(&settings, "places"));
        set_hidden(&settings, "map", false);
        assert_eq!(hidden(&settings), ["section:Sharing"]);
        reset(&settings);
        assert!(hidden(&settings).is_empty() && settings.get(KEY).is_none());
    }
}
