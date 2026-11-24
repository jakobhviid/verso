//! Shared links on Linux: which the page shows, as Linux remembers it in `gallery.json`, a link's address and what it
//! is called. Which links show is the core's (`verso_core::shared_links`), as on the Mac and the iPhone.

use immich_api::SharedLink;
use verso_core::links::server_address;
use verso_core::shared_links::{Arrangement, Filter};

use crate::settings::Settings;

/// The links chosen to show, all of them when nothing was chosen.
pub fn load(settings: &Settings) -> Arrangement {
    Arrangement {
        filter: settings.get("sharedLinks.filter").and_then(|code| Filter::from_code(&code)).unwrap_or_default(),
        hide_expired: settings.get("sharedLinks.hideExpired").as_deref() == Some("true"),
    }
}

/// Remember the links chosen to show; what is shown with no choice is remembered as none.
pub fn save(arrangement: &Arrangement, settings: &Settings) {
    settings.set("sharedLinks.filter", (arrangement.filter != Filter::All).then_some(arrangement.filter.code()));
    settings.set("sharedLinks.hideExpired", arrangement.hide_expired.then_some("true"));
}

/// The link's public address, as Immich's web app gives it: by its slug when it has one, else by its key.
pub fn address(server_url: &str, link: &SharedLink) -> String {
    match link.slug.as_deref().filter(|slug| !slug.is_empty()) {
        Some(slug) => format!("{}/s/{slug}", server_address(server_url)),
        None => format!("{}/share/{}", server_address(server_url), link.key.expose()),
    }
}

/// What a link is called: its description, its album's name, or what it shows. Not how many photos: the list of
/// links carries only some of each link's photos (Immich 3.3.5).
pub fn title(link: &SharedLink) -> String {
    link.description
        .clone()
        .filter(|description| !description.trim().is_empty())
        .or_else(|| link.album.as_ref().map(|album| album.name.clone()))
        .unwrap_or_else(|| verso_linux::i18n::tr("Shared Photos").to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_is_reached_by_its_slug_or_its_key_and_named_by_what_it_shows() {
        let mut shown = SharedLink { key: immich_api::Secret::new("k3y"), ..SharedLink::default() };
        assert_eq!(address("https://photos.example.org/api", &shown), "https://photos.example.org/share/k3y");
        shown.slug = Some("summer".to_owned());
        assert_eq!(address("https://photos.example.org", &shown), "https://photos.example.org/s/summer");
        shown.album = Some(immich_api::Album { name: "Summer".to_owned(), ..immich_api::Album::default() });
        assert_eq!(title(&shown), "Summer");
        shown.description = Some("For Gran".to_owned());
        assert_eq!(title(&shown), "For Gran");
    }

    #[test]
    fn the_choice_is_remembered() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(load(&settings), Arrangement::default());
        let chosen = Arrangement { filter: Filter::Individual, hide_expired: true };
        save(&chosen, &settings);
        assert_eq!(load(&settings), chosen);
        save(&Arrangement::default(), &settings);
        assert_eq!(settings.get("sharedLinks.filter"), None);
        assert_eq!(settings.get("sharedLinks.hideExpired"), None);
    }
}
