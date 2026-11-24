//! What the Mac and the iPhone keep for each account on the device, worked out in the core as for Linux's window: the
//! recent searches (`verso_core::recent_searches`) and Verso's own notifications (`verso_core::notifications`), each
//! in the form the apps have always kept it in. Swift hands over what its settings keep and gets back what to keep,
//! with what it shows.

use std::time::SystemTime;

use chrono::{DateTime, Utc};
use verso_core::{notifications, recent_searches};

/// Where the settings keep an account's recent searches, by its server's API address and its user.
#[uniffi::export]
pub fn recent_searches_key(api_url: String, user_id: String) -> String {
    recent_searches::apple_key(&api_url, &user_id)
}

/// The recent searches, newest first, as the settings keep them and each as the app's `SearchQuery` encodes one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RecentSearches {
    /// What the settings keep.
    pub stored: String,
    /// Each search, as JSON its `SearchQuery` decodes.
    pub searches: Vec<String>,
}

fn recent(searches: &[recent_searches::Search]) -> RecentSearches {
    RecentSearches {
        stored: recent_searches::searches_json(searches),
        searches: searches.iter().map(|search| serde_json::to_string(search).unwrap_or_default()).collect(),
    }
}

/// The recent searches the settings keep; none from what is not a JSON array of searches.
#[uniffi::export]
pub fn recent_searches_read(stored: String) -> RecentSearches {
    recent(&recent_searches::read_searches(&stored))
}

/// The recent searches once `search` (as the app's `SearchQuery` encodes it) is made: first, the same search but for
/// its order earlier going, at most 20. A search with neither words nor a filter, or what is no search, changes
/// nothing.
#[uniffi::export]
pub fn recent_searches_remembered(stored: String, search: String) -> RecentSearches {
    let kept = recent_searches::read_searches(&stored);
    match serde_json::from_str::<recent_searches::Search>(&search) {
        Ok(search) => recent(&recent_searches::remember_search(kept, search)),
        Err(_) => recent(&kept),
    }
}

/// A file an import did not bring in, and why.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeptNotificationFile {
    pub name: String,
    pub reason: String,
}

/// One of Verso's own notifications.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeptNotification {
    /// A UUID, as the app makes them.
    pub id: String,
    pub created_at: SystemTime,
    pub title: String,
    /// The line under the title.
    pub detail: Option<String>,
    /// Something failed, was cancelled or stopped: it arrives unread.
    pub needs_look: bool,
    /// None while unread.
    pub read_at: Option<SystemTime>,
    pub files: Vec<KeptNotificationFile>,
}

/// Verso's notifications for an account, the newest first, as the settings keep them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeptNotifications {
    /// What the settings keep.
    pub stored: String,
    pub notifications: Vec<KeptNotification>,
    pub unread: u32,
}

fn kept(list: &[notifications::Notification]) -> KeptNotifications {
    let time = |date: DateTime<Utc>| SystemTime::from(date);
    KeptNotifications {
        stored: notifications::apple_json(list),
        notifications: list
            .iter()
            .map(|notification| KeptNotification {
                id: notification.id.clone(),
                created_at: time(notification.created_at),
                title: notification.title.clone(),
                detail: notification.caption.clone(),
                needs_look: notification.needs_look,
                read_at: notification.read_at.map(time),
                files: notification.files.iter().map(|file| KeptNotificationFile { name: file.name.clone(), reason: file.reason.clone() }).collect(),
            })
            .collect(),
        unread: notifications::unread(list) as u32,
    }
}

/// Where the settings keep an account's notifications, by its key (`<API address>|<user>`).
#[uniffi::export]
pub fn verso_notifications_key(account: String) -> String {
    notifications::key(&account)
}

/// The notifications the settings keep, as they are read at launch: the newest 20, none older than a week.
#[uniffi::export]
pub fn verso_notifications_read(stored: String, now: SystemTime) -> KeptNotifications {
    let mut list = notifications::read_apple(&stored);
    notifications::prune(&mut list, DateTime::from(now));
    kept(&list)
}

/// The notifications once `notification` is kept, first: read as it was made unless it needs a look; the newest 20,
/// none older than a week.
#[uniffi::export]
pub fn verso_notifications_added(stored: String, notification: KeptNotification, now: SystemTime) -> KeptNotifications {
    let mut list = notifications::read_apple(&stored);
    let added = notifications::Notification {
        id: notification.id,
        created_at: DateTime::from(notification.created_at),
        title: notification.title,
        caption: notification.detail,
        needs_look: notification.needs_look,
        read_at: notification.read_at.map(DateTime::from),
        files: notification.files.into_iter().map(|file| notifications::File { name: file.name, reason: file.reason }).collect(),
    };
    notifications::add(&mut list, added, DateTime::from(now));
    kept(&list)
}

/// The notifications once those of `ids` still unread are read, at `now`.
#[uniffi::export]
pub fn verso_notifications_marked_read(stored: String, ids: Vec<String>, now: SystemTime) -> KeptNotifications {
    let mut list = notifications::read_apple(&stored);
    notifications::mark_read(&mut list, &ids, DateTime::from(now));
    kept(&list)
}

/// The notifications once those of `ids` are cleared.
#[uniffi::export]
pub fn verso_notifications_deleted(stored: String, ids: Vec<String>) -> KeptNotifications {
    let mut list = notifications::read_apple(&stored);
    notifications::delete(&mut list, &ids);
    kept(&list)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn recent_searches_keep_the_newest_first_and_the_same_search_in_another_order_once() {
        let key = recent_searches_key("https://demo.immich.app/api".into(), "me".into());
        assert!(key.starts_with("searchHistory."));
        let beach = r#"{"text":"beach","mode":"Context","sort":"automatic","personIDs":[],"personNames":{},"country":"","state":"","city":"","make":"","model":"","lensModel":"","mediaType":"","archived":false,"favorites":false,"notInAlbum":false}"#;
        let first = recent_searches_remembered(String::new(), beach.into());
        assert_eq!(first.searches.len(), 1);
        let videos = r#"{"text":"","mode":"Context","sort":"newest","personIDs":[],"personNames":{},"country":"Denmark","state":"","city":"","make":"","model":"","lensModel":"","mediaType":"VIDEO","archived":false,"favorites":true,"notInAlbum":false,"rating":4}"#;
        let second = recent_searches_remembered(first.stored, videos.into());
        let again = recent_searches_remembered(second.stored.clone(), beach.replace("automatic", "oldest"));
        assert_eq!(again.searches.len(), 2);
        assert!(again.searches[0].contains(r#""text":"beach""#) && again.searches[0].contains(r#""sort":"oldest""#));
        assert!(again.searches[1].contains(r#""rating":4"#));
        assert_eq!(recent_searches_read(again.stored.clone()), again);
        let nothing = recent_searches_remembered(again.stored.clone(), r#"{"sort":"newest"}"#.into());
        assert_eq!(nothing, again, "nothing to look for");
        assert_eq!(recent_searches_remembered(again.stored.clone(), "not a search".into()), again);
        assert!(recent_searches_read("garbage".into()).searches.is_empty());
    }

    #[test]
    fn notifications_arrive_read_unless_they_need_a_look_and_go_after_a_week() {
        let now = SystemTime::now();
        let note = |id: &str, title: &str, needs_look: bool, made: SystemTime| KeptNotification {
            id: id.into(),
            created_at: made,
            title: title.into(),
            detail: needs_look.then(|| "2 not imported".to_owned()),
            needs_look,
            read_at: None,
            files: vec![KeptNotificationFile { name: "a.jpg".into(), reason: "offline".into() }],
        };
        assert_eq!(verso_notifications_key("https://demo.immich.app/api|me".into()), "notifications.verso.https://demo.immich.app/api|me");
        let old = verso_notifications_added(String::new(), note("A", "Old", false, now - Duration::from_secs(8 * 86_400)), now - Duration::from_secs(8 * 86_400));
        let clean = verso_notifications_added(old.stored, note("B", "Imported 12", false, now - Duration::from_secs(60)), now);
        let failed = verso_notifications_added(clean.stored, note("C", "Imported 3 of 5", true, now), now);
        assert_eq!(failed.notifications.iter().map(|notification| notification.title.as_str()).collect::<Vec<_>>(), ["Imported 3 of 5", "Imported 12"]);
        assert_eq!((failed.unread, failed.notifications[1].read_at.is_some()), (1, true));
        assert_eq!(failed.notifications[0].detail.as_deref(), Some("2 not imported"));
        let read = verso_notifications_marked_read(failed.stored.clone(), vec!["C".into()], now);
        assert_eq!(read.unread, 0);
        let all = verso_notifications_deleted(read.stored.clone(), vec!["B".into(), "C".into()]);
        assert!(all.notifications.is_empty() && all.stored == "[]");
        // A week on, at launch, the clean one is gone.
        let later = verso_notifications_read(read.stored, now + Duration::from_secs(7 * 86_400 - 30));
        assert_eq!(later.notifications.len(), 1);
    }
}
