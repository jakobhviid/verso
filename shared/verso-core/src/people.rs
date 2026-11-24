//! People's filter (after Immich Gallery's `PeopleArrangement`): the favorite and hidden filters of Immich's web app's
//! people page (PeopleFilterModal.svelte), all people, the favorites or the hidden ones, with the hidden shown beside
//! the rest when asked. Immich v3.3 filters on the server; from an older one every page comes and the app filters it.
//! Linux's window, the Mac and the iPhone (through `verso-bridge`) all filter here.

use immich_api::version::ServerVersion;

/// Whom the People page shows.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Show {
    #[default]
    All,
    Favorites,
    Hidden,
}

impl Show {
    pub const ALL: [Show; 3] = [Show::All, Show::Favorites, Show::Hidden];

    /// The codes the choice is kept by, the same on Linux and the Mac.
    pub fn code(self) -> &'static str {
        match self {
            Show::All => "All",
            Show::Favorites => "Favorites",
            Show::Hidden => "Hidden",
        }
    }

    pub fn from_code(code: &str) -> Option<Show> {
        Show::ALL.into_iter().find(|show| show.code() == code)
    }
}

/// The People page's view options.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Arrangement {
    pub show: Show,
    /// Hidden people shown beside the others.
    pub include_hidden: bool,
}

/// What Immich is asked to filter itself, where it can.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ServerFilter {
    pub favorites_only: bool,
    pub hidden_only: bool,
}

/// The first Immich that filters people itself (`isFavorite` and `isHidden` on `GET /people`).
const SERVER_FILTERS: ServerVersion = ServerVersion { major: 3, minor: 3, patch: 0 };

impl Arrangement {
    /// Whether the options leave some people out.
    pub fn is_filtered(&self) -> bool {
        *self != Arrangement::default()
    }

    /// Whether hidden people are asked for: when they show beside the others, or alone.
    pub fn with_hidden(&self) -> bool {
        self.include_hidden || self.show == Show::Hidden
    }

    /// Whether a person shows.
    pub fn includes(&self, is_favorite: bool, is_hidden: bool) -> bool {
        match self.show {
            Show::All => self.with_hidden() || !is_hidden,
            Show::Favorites => is_favorite && (self.with_hidden() || !is_hidden),
            Show::Hidden => is_hidden,
        }
    }

    /// What to ask a server of this version to filter itself: nothing of one older than Immich v3.3, or unknown.
    pub fn server_filter(&self, server: Option<&ServerVersion>) -> ServerFilter {
        if server.is_none_or(|version| *version < SERVER_FILTERS) {
            return ServerFilter::default();
        }
        ServerFilter { favorites_only: self.show == Show::Favorites, hidden_only: self.show == Show::Hidden }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arrangement(show: Show, include_hidden: bool) -> Arrangement {
        Arrangement { show, include_hidden }
    }

    fn version(major: u32, minor: u32, patch: u32) -> ServerVersion {
        ServerVersion { major, minor, patch }
    }

    #[test]
    fn all_people_leave_the_hidden_out_unless_asked() {
        let all = Arrangement::default();
        assert!(!all.is_filtered() && !all.with_hidden());
        assert!(all.includes(false, false) && !all.includes(true, true));
        let everyone = arrangement(Show::All, true);
        assert!(everyone.is_filtered() && everyone.with_hidden() && everyone.includes(false, true));
    }

    #[test]
    fn favorites_are_the_favorite_and_shown_and_hidden_are_the_hidden() {
        let favorites = arrangement(Show::Favorites, false);
        assert!(favorites.is_filtered() && !favorites.with_hidden());
        assert!(favorites.includes(true, false));
        assert!(!favorites.includes(false, false) && !favorites.includes(true, true));
        assert!(arrangement(Show::Favorites, true).includes(true, true));
        let hidden = arrangement(Show::Hidden, false);
        assert!(hidden.with_hidden() && hidden.includes(false, true) && !hidden.includes(true, false));
    }

    #[test]
    fn the_server_filters_only_where_immich_understands_it() {
        let favorites = arrangement(Show::Favorites, false);
        let only_favorites = ServerFilter { favorites_only: true, hidden_only: false };
        assert_eq!(favorites.server_filter(Some(&version(3, 2, 9))), ServerFilter::default());
        assert_eq!(favorites.server_filter(None), ServerFilter::default());
        assert_eq!(favorites.server_filter(Some(&version(3, 3, 0))), only_favorites);
        assert_eq!(favorites.server_filter(Some(&version(4, 0, 0))), only_favorites);
        assert_eq!(arrangement(Show::Hidden, false).server_filter(Some(&version(3, 3, 0))), ServerFilter { favorites_only: false, hidden_only: true });
        assert_eq!(Arrangement::default().server_filter(Some(&version(3, 3, 0))), ServerFilter::default());
    }

    #[test]
    fn the_choice_is_kept_by_its_code() {
        for show in Show::ALL {
            assert_eq!(Show::from_code(show.code()), Some(show));
        }
        assert_eq!(Show::from_code("Hidden"), Some(Show::Hidden));
        assert_eq!(Show::from_code("Favorites"), Some(Show::Favorites));
        assert_eq!(Show::from_code("hidden"), None);
    }
}
