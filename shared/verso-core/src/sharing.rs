//! How far an album or a link reaches, from only its owner to anyone with its address: Linux's window, the Mac and the
//! iPhone (through `verso-bridge`) all tell it here, and each shows it in its own icon and words, the same wherever it
//! shows (an album's page, its cover or card, a link's card). An album reaches as far as the widest of its people and
//! its links still working; a link reaches anyone with it, and its password where it has one.

use chrono::{DateTime, Utc};
use immich_api::SharedLink;

use crate::shared_links;

/// How far an album or a link reaches, narrowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Audience {
    /// Only its owner.
    Private,
    /// People on the server it is shared with besides its owner.
    People,
    /// Anyone with a link and its password.
    Password,
    /// Anyone with a link.
    Public,
}

impl Audience {
    /// Whom a link lets in, whether or not it still works: anyone with it, and its password where it has one. A link's
    /// own card and page show it.
    pub fn of_link(link: &SharedLink) -> Audience {
        if link.password.is_some() { Audience::Password } else { Audience::Public }
    }

    /// A link's reach while it works; none once it has expired, when it reaches nobody.
    pub fn of_working_link(link: &SharedLink, now: DateTime<Utc>) -> Option<Audience> {
        (!shared_links::is_expired(link, now)).then(|| Audience::of_link(link))
    }

    /// An album's reach: shared with `others` people besides its owner, and its `links`, of which those still working
    /// count.
    pub fn of_album(others: usize, links: &[SharedLink], now: DateTime<Utc>) -> Audience {
        let people = if others > 0 { Audience::People } else { Audience::Private };
        links.iter().filter_map(|link| Audience::of_working_link(link, now)).fold(people, Audience::max)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn link(password: bool, expires: Option<DateTime<Utc>>) -> SharedLink {
        SharedLink { password: password.then(|| immich_api::Secret::new("secret")), expires_at: expires, ..SharedLink::default() }
    }

    #[test]
    fn an_album_reaches_as_far_as_its_widest_way_still_working() {
        let now = Utc::now();
        let (past, future) = (Some(now - Duration::days(1)), Some(now + Duration::days(1)));
        assert_eq!(Audience::of_album(0, &[], now), Audience::Private, "nobody and no link is private");
        assert_eq!(Audience::of_album(2, &[], now), Audience::People, "people without a link");
        assert_eq!(Audience::of_album(2, &[link(true, None)], now), Audience::Password, "a password link reaches further than people");
        assert_eq!(Audience::of_album(0, &[link(true, None), link(false, future)], now), Audience::Public, "one working public link makes it public");
        assert_eq!(Audience::of_album(1, &[link(false, past)], now), Audience::People, "an expired link reaches nobody");
        assert_eq!(Audience::of_album(0, &[link(false, past)], now), Audience::Private, "only expired links is private");
        assert_eq!(Audience::of_album(1, &[link(false, future)], now), Audience::Public);
        assert_eq!(Audience::of_album(0, &[link(false, Some(now))], now), Audience::Private, "a link's last moment is past");
    }

    #[test]
    fn a_link_reaches_anyone_with_it_and_its_password_while_it_works() {
        let now = Utc::now();
        let past = Some(now - Duration::days(1));
        assert_eq!((Audience::of_link(&link(true, None)), Audience::of_link(&link(false, None))), (Audience::Password, Audience::Public));
        assert_eq!(Audience::of_link(&link(true, past)), Audience::Password, "its own reach, expired or not");
        assert_eq!(Audience::of_working_link(&link(true, None), now), Some(Audience::Password));
        assert_eq!(Audience::of_working_link(&link(false, past), now), None);
    }
}
