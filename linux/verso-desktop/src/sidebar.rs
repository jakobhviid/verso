//! The sidebar's layout as Linux remembers it, in the gallery's settings: its arrangement under `sidebar.layout`, and
//! what is hidden under `sidebar.hidden`. The layout and its rules are the core's (`verso_core::sidebar`), as on the
//! Mac and the iPhone, read and written here in Linux's form.

pub use verso_core::sidebar::{Defaults, Layout, Section};

use crate::settings::Settings;

const KEY: &str = "sidebar.hidden";
const LAYOUT_KEY: &str = "sidebar.layout";

/// The layout remembered, made whole for the built-in sections and pages.
pub fn load(settings: &Settings, defaults: Defaults) -> Layout {
    Layout::linux(settings.get(LAYOUT_KEY).as_deref(), settings.get(KEY).as_deref(), defaults)
}

/// Remember the layout, its arrangement and what is hidden.
pub fn save(settings: &Settings, layout: &Layout) {
    settings.set(LAYOUT_KEY, Some(&layout.linux_arrangement()));
    save_hidden(settings, layout);
}

/// Remember what is hidden alone, so a sidebar never arranged keeps following the built-in order.
pub fn save_hidden(settings: &Settings, layout: &Layout) {
    settings.set(KEY, layout.linux_hidden().as_deref());
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

    #[test]
    fn a_layout_is_remembered_in_two_keys_and_hiding_leaves_the_arrangement_unwritten() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        let mut layout = load(&settings, DEFAULTS);
        layout.set_hidden("map", true);
        layout.set_section_hidden("Explore", true);
        save_hidden(&settings, &layout);
        assert_eq!(settings.get(KEY).as_deref(), Some("section:Explore,map"));
        assert!(settings.get(LAYOUT_KEY).is_none(), "a sidebar never arranged follows the built-in order");
        let kids = layout.add_section("Kids").unwrap();
        assert!(layout.move_page("places", &kids, None));
        save(&settings, &layout);
        assert_eq!(load(&settings, DEFAULTS), layout);
        reset(&settings);
        assert!(settings.get(KEY).is_none() && settings.get(LAYOUT_KEY).is_none());
        assert_eq!(load(&settings, DEFAULTS), Layout::linux(None, None, DEFAULTS));
    }
}
