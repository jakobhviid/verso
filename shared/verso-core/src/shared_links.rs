//! Which shared links show (after Immich Gallery's `SharedLinksArrangement`): Immich's web app's All, Album and
//! Individual tabs, and hiding expired links. Linux's window, the Mac and the iPhone (through `verso-bridge`) all
//! filter here.

use chrono::{DateTime, Utc};
use immich_api::{SharedLink, SharedLinkKind};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Filter {
    #[default]
    All,
    Album,
    Individual,
}

impl Filter {
    pub const ALL: [Filter; 3] = [Filter::All, Filter::Album, Filter::Individual];

    /// Immich's tab names, which the choice is kept by on Linux and the Mac.
    pub fn code(self) -> &'static str {
        match self {
            Filter::All => "all",
            Filter::Album => "album",
            Filter::Individual => "individual",
        }
    }

    pub fn from_code(code: &str) -> Option<Filter> {
        Filter::ALL.into_iter().find(|filter| filter.code() == code)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Arrangement {
    pub filter: Filter,
    pub hide_expired: bool,
}

impl Arrangement {
    pub fn is_filtered(&self) -> bool {
        *self != Arrangement::default()
    }

    /// Whether a link shows.
    pub fn shows(&self, link: &SharedLink, now: DateTime<Utc>) -> bool {
        let kind = match self.filter {
            Filter::All => true,
            Filter::Album => link.kind == SharedLinkKind::Album,
            Filter::Individual => link.kind == SharedLinkKind::Individual,
        };
        kind && !(self.hide_expired && is_expired(link, now))
    }

    /// The links shown, in the server's order.
    pub fn links<'a>(&self, links: &'a [SharedLink], now: DateTime<Utc>) -> Vec<&'a SharedLink> {
        links.iter().filter(|link| self.shows(link, now)).collect()
    }
}

/// Whether a link is past its last day, so it no longer opens.
pub fn is_expired(link: &SharedLink, now: DateTime<Utc>) -> bool {
    link.expires_at.is_some_and(|expires| expires <= now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn link(id: &str, kind: SharedLinkKind, expires_at: Option<DateTime<Utc>>) -> SharedLink {
        SharedLink { id: id.to_owned(), kind, expires_at, ..SharedLink::default() }
    }

    #[test]
    fn links_show_by_kind_and_without_the_expired() {
        let now = Utc::now();
        let links = [
            link("a", SharedLinkKind::Album, None),
            link("b", SharedLinkKind::Individual, Some(now - Duration::days(1))),
            link("c", SharedLinkKind::Album, Some(now + Duration::days(1))),
        ];
        let ids = |arrangement: Arrangement| arrangement.links(&links, now).into_iter().map(|link| link.id.as_str()).collect::<Vec<_>>();
        assert_eq!(ids(Arrangement::default()), ["a", "b", "c"]);
        assert_eq!(ids(Arrangement { filter: Filter::Album, hide_expired: false }), ["a", "c"]);
        assert_eq!(ids(Arrangement { filter: Filter::Individual, hide_expired: false }), ["b"]);
        assert_eq!(ids(Arrangement { filter: Filter::All, hide_expired: true }), ["a", "c"]);
        assert!(ids(Arrangement { filter: Filter::Individual, hide_expired: true }).is_empty());
        assert!(is_expired(&links[1], now) && !is_expired(&links[0], now) && !is_expired(&links[2], now));
        assert!(is_expired(&link("now", SharedLinkKind::Album, Some(now)), now), "its last moment is past");
    }

    #[test]
    fn only_a_choice_other_than_all_links_filters() {
        assert!(!Arrangement::default().is_filtered());
        assert!(Arrangement { filter: Filter::All, hide_expired: true }.is_filtered());
        assert!(Arrangement { filter: Filter::Album, hide_expired: false }.is_filtered());
    }

    #[test]
    fn the_choice_is_kept_by_immichs_tab_names() {
        for filter in Filter::ALL {
            assert_eq!(Filter::from_code(filter.code()), Some(filter));
        }
        assert_eq!(Filter::from_code("album"), Some(Filter::Album));
        assert_eq!(Filter::from_code("individual"), Some(Filter::Individual));
        assert_eq!(Filter::from_code("Album"), None);
    }
}
