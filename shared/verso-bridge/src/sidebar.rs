//! The sidebar's layout, worked out in the core for the Mac's sidebar and the iPhone's Collections as for Linux's
//! window (`verso_core::sidebar`), and kept in the form the Mac and the iPhone have always kept it in: Swift hands over
//! what its settings keep, with its built-in sections and pages, and gets back what to keep and what it shows.

use verso_core::sidebar::Layout;

/// A built-in section and its pages, by the ids the app keeps them by; a section without pages lists albums.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SidebarDefault {
    pub section: String,
    pub pages: Vec<String>,
}

/// A section of the sidebar, as it stands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SidebarSection {
    pub id: String,
    /// The name the person gave it; a built-in section is named by the app.
    pub name: Option<String>,
    pub hidden: bool,
    pub is_collapsed: bool,
    /// The person's own, which can be renamed and deleted.
    pub is_custom: bool,
    pub lists_albums: bool,
    /// Its pages, in order, hidden or not.
    pub pages: Vec<String>,
    /// How many albums it lists, none for all of them: 5 until the person chooses.
    pub album_limit: Option<u32>,
    /// What its albums are sorted by, by the Albums page's code; none until the person chooses.
    pub album_sort_by: Option<String>,
}

/// The sidebar as arranged: what the settings keep, its sections, and what is hidden.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SidebarArrangement {
    /// What the settings keep, in the Mac's and the iPhone's form.
    pub stored: String,
    pub sections: Vec<SidebarSection>,
    /// The pages hidden.
    pub hidden_pages: Vec<String>,
    /// The albums and partners hidden, by the keys the app makes for them.
    pub hidden_items: Vec<String>,
}

/// A change Edit Sidebar or Customize makes.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SidebarEdit {
    /// A page into a section: beside one of its pages, before it or after it, or at its end without one.
    MovePage { page: String, section: String, target: Option<String>, after: bool },
    /// A page dropped among the pages a section shows: before the one at `index`, or after the last.
    DropPage { page: String, section: String, index: u32, shown: Vec<String> },
    /// A page one place up (-1) or down (1), into the section above or below from its first or last place.
    StepPage { page: String, by: i32 },
    HidePage { page: String, hidden: bool },
    /// An album or a partner of an account, by the key the app makes for it.
    HideItem { key: String, hidden: bool },
    HideSection { id: String, hidden: bool },
    CollapseSection { id: String, collapsed: bool },
    /// A section of the person's own, last.
    AddSection { name: String },
    RenameSection { id: String, name: String },
    /// A section of the person's own deleted, its pages back where they started.
    RemoveSection { id: String },
    /// A section moved `by` places, up for less than 0.
    ShiftSection { id: String, by: i32 },
    /// How many albums a section lists, at least one; none for all.
    AlbumLimit { section: String, limit: Option<u32> },
    AlbumSortBy { section: String, sort_by: Option<String> },
}

/// A layout once changed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SidebarEdited {
    pub arrangement: SidebarArrangement,
    /// Whether anything changed.
    pub changed: bool,
    /// The id of a section added.
    pub added: Option<String>,
}

fn layout(stored: &str, defaults: &[SidebarDefault]) -> Layout {
    let pages: Vec<Vec<&str>> = defaults.iter().map(|default| default.pages.iter().map(String::as_str).collect()).collect();
    let defaults: Vec<(&str, &[&str])> = defaults.iter().zip(&pages).map(|(default, pages)| (default.section.as_str(), pages.as_slice())).collect();
    Layout::apple(stored, &defaults)
}

fn arrangement(layout: &Layout) -> SidebarArrangement {
    let sections = layout
        .sections()
        .iter()
        .map(|section| SidebarSection {
            id: section.id.clone(),
            name: section.name.clone(),
            hidden: section.hidden,
            is_collapsed: section.collapsed,
            is_custom: section.is_custom(),
            lists_albums: layout.lists_albums(&section.id),
            pages: layout.pages_in(&section.id).into_iter().map(str::to_owned).collect(),
            album_limit: layout.album_limit(&section.id).map(|limit| u32::try_from(limit).unwrap_or(u32::MAX)),
            album_sort_by: layout.album_sorting(&section.id).map(str::to_owned),
        })
        .collect();
    SidebarArrangement {
        stored: layout.apple_json(),
        sections,
        hidden_pages: layout.hidden().to_vec(),
        hidden_items: layout.hidden_items().map(str::to_owned).collect(),
    }
}

/// The sidebar as the settings keep it (`stored`, in either form the Mac has kept it in; empty for the built-in one),
/// made whole for the app's built-in sections and pages: a section or page it does not know is left out, a page
/// placed twice keeps its first place, and a page not placed joins the end of the section it started in.
#[uniffi::export]
pub fn sidebar_arrangement(stored: String, defaults: Vec<SidebarDefault>) -> SidebarArrangement {
    arrangement(&layout(&stored, &defaults))
}

/// The sidebar once a change is made to what the settings keep. A move into a section that does not exist, beside a
/// page that is not in it or beside itself changes nothing, as do a name of nothing but spaces and the deletion or
/// renaming of a built-in section.
#[uniffi::export]
pub fn sidebar_edited(stored: String, defaults: Vec<SidebarDefault>, edit: SidebarEdit) -> SidebarEdited {
    let mut layout = layout(&stored, &defaults);
    let before = layout.apple_json();
    let mut added = None;
    match edit {
        SidebarEdit::MovePage { page, section, target: Some(target), after } => {
            layout.move_beside(&page, &section, &target, after);
        }
        SidebarEdit::MovePage { page, section, target: None, .. } => {
            layout.move_page(&page, &section, None);
        }
        SidebarEdit::DropPage { page, section, index, shown } => {
            let shown: Vec<&str> = shown.iter().map(String::as_str).collect();
            layout.move_among(&page, &section, index as usize, &shown);
        }
        SidebarEdit::StepPage { page, by } => {
            layout.step_page(&page, by);
        }
        SidebarEdit::HidePage { page, hidden } => layout.set_hidden(&page, hidden),
        SidebarEdit::HideItem { key, hidden } => layout.set_item_hidden(&key, hidden),
        SidebarEdit::HideSection { id, hidden } => {
            layout.set_section_hidden(&id, hidden);
        }
        SidebarEdit::CollapseSection { id, collapsed } => {
            layout.set_section_collapsed(&id, collapsed);
        }
        SidebarEdit::AddSection { name } => added = layout.add_section(&name),
        SidebarEdit::RenameSection { id, name } => {
            layout.rename_section(&id, &name);
        }
        SidebarEdit::RemoveSection { id } => {
            layout.remove_section(&id);
        }
        SidebarEdit::ShiftSection { id, by } => {
            layout.shift_section(&id, i64::from(by));
        }
        SidebarEdit::AlbumLimit { section, limit } => layout.set_album_limit(&section, limit.map(|limit| limit as usize)),
        SidebarEdit::AlbumSortBy { section, sort_by } => layout.set_album_sorting(&section, sort_by.as_deref()),
    }
    let arrangement = arrangement(&layout);
    SidebarEdited { changed: arrangement.stored != before, arrangement, added }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Mac's and the iPhone's built-in sections and pages, as `SidebarLayout.defaults` hands them over.
    fn defaults() -> Vec<SidebarDefault> {
        let section = |id: &str, pages: &[&str]| SidebarDefault { section: id.to_owned(), pages: pages.iter().map(|page| (*page).to_owned()).collect() };
        vec![
            section("photos", &["search", "library", "favorites", "videos"]),
            section("explore", &["map", "places", "memories", "tags", "folders"]),
            section("collections", &["albums", "people"]),
            section("sharing", &["sharedLinks", "partners"]),
            section("utilities", &["duplicates", "largeFiles", "geolocation", "archive", "trash", "locked"]),
            section("myAlbums", &[]),
            section("sharedAlbums", &[]),
        ]
    }

    fn edited(stored: &str, edit: SidebarEdit) -> SidebarEdited {
        sidebar_edited(stored.to_owned(), defaults(), edit)
    }

    fn pages<'a>(arrangement: &'a SidebarArrangement, section: &str) -> Vec<&'a str> {
        arrangement.sections.iter().find(|known| known.id == section).map(|known| known.pages.iter().map(String::as_str).collect()).unwrap_or_default()
    }

    #[test]
    fn the_built_in_sidebar_lists_every_page_where_it_starts_with_five_albums_in_each_album_section() {
        let arrangement = sidebar_arrangement(String::new(), defaults());
        assert_eq!(arrangement.sections.iter().map(|section| section.id.as_str()).collect::<Vec<_>>(), ["photos", "explore", "collections", "sharing", "utilities", "myAlbums", "sharedAlbums"]);
        assert_eq!(pages(&arrangement, "photos"), ["search", "library", "favorites", "videos"]);
        let albums = arrangement.sections.iter().find(|section| section.id == "myAlbums").unwrap();
        assert!(albums.lists_albums && !albums.is_custom && albums.album_limit == Some(5) && albums.album_sort_by.is_none());
        assert!(arrangement.hidden_pages.is_empty() && arrangement.hidden_items.is_empty());
        assert!(arrangement.stored.starts_with(r#"{"albumLimits":{},"albumSorting":{},"entries":["#));
    }

    #[test]
    fn each_change_comes_back_with_what_to_keep_and_whether_anything_changed() {
        let moved = edited("", SidebarEdit::MovePage { page: "videos".into(), section: "photos".into(), target: Some("search".into()), after: false });
        assert!(moved.changed);
        assert_eq!(pages(&moved.arrangement, "photos"), ["videos", "search", "library", "favorites"]);
        let stored = moved.arrangement.stored;
        let again = edited(&stored, SidebarEdit::MovePage { page: "videos".into(), section: "photos".into(), target: Some("search".into()), after: false });
        assert!(!again.changed && again.arrangement.stored == stored);
        let after = edited(&stored, SidebarEdit::MovePage { page: "videos".into(), section: "photos".into(), target: Some("favorites".into()), after: true });
        assert_eq!(pages(&after.arrangement, "photos"), ["search", "library", "favorites", "videos"]);
        let dropped = edited(&stored, SidebarEdit::DropPage { page: "map".into(), section: "photos".into(), index: 9, shown: vec!["videos".into(), "search".into()] });
        assert_eq!(pages(&dropped.arrangement, "photos"), ["videos", "search", "map", "library", "favorites"]);
        assert!(!edited(&stored, SidebarEdit::MovePage { page: "map".into(), section: "missing".into(), target: None, after: false }).changed);

        let added = edited(&stored, SidebarEdit::AddSection { name: " Trips ".into() });
        let trips = added.added.clone().unwrap();
        let section = added.arrangement.sections.last().unwrap();
        assert!(section.id == trips && section.is_custom && section.name.as_deref() == Some("Trips"));
        assert!(edited(&stored, SidebarEdit::AddSection { name: "  ".into() }).added.is_none());
        let stored = edited(&added.arrangement.stored, SidebarEdit::MovePage { page: "places".into(), section: trips.clone(), target: None, after: false }).arrangement.stored;
        let shifted = edited(&stored, SidebarEdit::ShiftSection { id: trips.clone(), by: -6 });
        assert_eq!(shifted.arrangement.sections[1].id, trips);
        let hidden = edited(&shifted.arrangement.stored, SidebarEdit::HideSection { id: "sharing".into(), hidden: true });
        let collapsed = edited(&hidden.arrangement.stored, SidebarEdit::CollapseSection { id: "utilities".into(), collapsed: true });
        let page = edited(&collapsed.arrangement.stored, SidebarEdit::HidePage { page: "tags".into(), hidden: true });
        let item = edited(&page.arrangement.stored, SidebarEdit::HideItem { key: "https://demo.immich.app/api|me|album:1".into(), hidden: true });
        let limit = edited(&item.arrangement.stored, SidebarEdit::AlbumLimit { section: "myAlbums".into(), limit: None });
        let sorted = edited(&limit.arrangement.stored, SidebarEdit::AlbumSortBy { section: "myAlbums".into(), sort_by: Some("Title".into()) });
        let read = sidebar_arrangement(sorted.arrangement.stored.clone(), defaults());
        assert_eq!(read, sorted.arrangement);
        let section = |id: &str| read.sections.iter().find(|section| section.id == id).unwrap();
        assert!(section("sharing").hidden && section("utilities").is_collapsed);
        assert_eq!((section("myAlbums").album_limit, section("myAlbums").album_sort_by.as_deref()), (None, Some("Title")));
        assert_eq!((read.hidden_pages.as_slice(), read.hidden_items.as_slice()), (&["tags".to_owned()][..], &["https://demo.immich.app/api|me|album:1".to_owned()][..]));
        let renamed = edited(&read.stored, SidebarEdit::RenameSection { id: trips.clone(), name: "Travel".into() });
        assert_eq!(renamed.arrangement.sections[1].name.as_deref(), Some("Travel"));
        let removed = edited(&renamed.arrangement.stored, SidebarEdit::RemoveSection { id: trips.clone() });
        assert!(removed.arrangement.sections.iter().all(|section| section.id != trips));
        assert_eq!(pages(&removed.arrangement, "explore").last(), Some(&"places"));
        assert!(!edited(&removed.arrangement.stored, SidebarEdit::RemoveSection { id: "photos".into() }).changed);
        let stepped = edited(&removed.arrangement.stored, SidebarEdit::StepPage { page: "search".into(), by: -1 });
        assert_eq!(pages(&stepped.arrangement, "photos"), ["search", "videos", "library", "favorites"]);
        assert!(!edited(&stepped.arrangement.stored, SidebarEdit::StepPage { page: "search".into(), by: -1 }).changed, "nowhere above the first section");
    }

    #[test]
    fn a_layout_the_mac_kept_reads_as_it_did() {
        let kept = r#"{"albumLimits":{"myAlbums":0,"sharedAlbums":10},"albumSorting":{"myAlbums":"Title"},"entries":[{"group":"photos","link":"search"},{"group":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","link":"places"},{"group":"collections","link":"people"},{"group":"collections","link":"albums"}],"hiddenDynamicItems":["https:\/\/demo.immich.app\/api|me|partner:zoe"],"hiddenLinks":["tags"],"sections":[{"hidden":false,"id":"photos"},{"hidden":false,"id":"8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13","name":"Trips"},{"hidden":false,"id":"collections"},{"hidden":false,"id":"explore"},{"hidden":true,"id":"sharing"},{"collapsed":true,"hidden":false,"id":"utilities"},{"hidden":false,"id":"myAlbums"},{"hidden":false,"id":"sharedAlbums"}]}"#;
        let read = sidebar_arrangement(kept.to_owned(), defaults());
        assert_eq!(read.sections.iter().map(|section| section.id.as_str()).collect::<Vec<_>>(), ["photos", "8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13", "collections", "explore", "sharing", "utilities", "myAlbums", "sharedAlbums"]);
        assert_eq!(pages(&read, "8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13"), ["places"]);
        assert_eq!(pages(&read, "collections"), ["people", "albums"]);
        assert_eq!(pages(&read, "photos"), ["search", "library", "favorites", "videos"]);
        assert_eq!(pages(&read, "explore"), ["map", "memories", "tags", "folders"]);
        assert_eq!(read.hidden_items, ["https://demo.immich.app/api|me|partner:zoe"]);
        let section = |id: &str| read.sections.iter().find(|section| section.id == id).unwrap();
        assert_eq!((section("myAlbums").album_limit, section("sharedAlbums").album_limit), (None, Some(10)));
        assert!(section("sharing").hidden && section("utilities").is_collapsed && section("8A1F6C52-3B9E-4D7A-9C1E-2F4B6D8E0A13").is_custom);
        // What the core writes back, the Mac reads the same.
        assert_eq!(sidebar_arrangement(read.stored.clone(), defaults()), read);
    }
}
