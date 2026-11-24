//! The Duplicates page's order as Linux remembers it, in `gallery.json`; the order itself is the core's
//! (`verso_core::duplicates`), as on the Mac and the iPhone.

use verso_core::duplicates::SortBy;

use crate::settings::Settings;

const KEY: &str = "duplicates.sortBy";

/// The order chosen, the server's when none was.
pub fn load(settings: &Settings) -> SortBy {
    settings.get(KEY).and_then(|code| SortBy::from_code(&code)).unwrap_or_default()
}

/// Remember the order chosen; the server's is remembered as no choice.
pub fn save(sort: SortBy, settings: &Settings) {
    settings.set(KEY, (sort != SortBy::Default).then_some(sort.code()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_order_is_remembered() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(load(&settings), SortBy::Default);
        save(SortBy::TotalSize, &settings);
        assert_eq!(load(&settings), SortBy::TotalSize);
        save(SortBy::Default, &settings);
        assert_eq!(settings.get(KEY), None);
    }
}
