//! Verso's own notifications, kept on this computer for each account, as the Mac keeps them: for now what each import
//! came to, once it went from the foot of the sidebar. The newest 20, none older than a week, in the gallery's settings
//! (`settings`), by account as the recent searches are. An import that ended with everything in arrives read, as it
//! was seen happening; one that needs a look arrives unread. The server's own notifications are Immich's
//! (`immich_api::notification`).

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::settings::Settings;

/// How many are kept.
const KEPT: usize = 20;

/// How long one is kept, in days.
const KEPT_FOR: i64 = 7;

/// A file an import did not bring in, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    pub name: String,
    pub reason: String,
}

/// One of Verso's notifications.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    pub id: String,
    pub created_at: DateTime<Utc>,
    pub title: String,
    /// What else it came to, or why it stopped.
    #[serde(default)]
    pub caption: Option<String>,
    /// Something failed, was cancelled or stopped the import.
    #[serde(default)]
    pub needs_look: bool,
    /// `None` while unread.
    #[serde(default)]
    pub read_at: Option<DateTime<Utc>>,
    /// The files not imported or cancelled, and why.
    #[serde(default)]
    pub files: Vec<File>,
}

impl Notification {
    /// A notification made `now`: read at once, unless it needs a look.
    pub fn new(title: String, caption: Option<String>, needs_look: bool, files: Vec<File>, now: DateTime<Utc>) -> Notification {
        let id = format!("{:x}", now.timestamp_nanos_opt().unwrap_or_else(|| now.timestamp()));
        Notification { id, created_at: now, title, caption, needs_look, read_at: (!needs_look).then_some(now), files }
    }
}

fn key(account: &str) -> String {
    format!("notifications.verso.{account}")
}

/// The notifications of an account (one per server and user, `Connection::account_key`), newest first.
pub fn kept(settings: &Settings, account: &str, now: DateTime<Utc>) -> Vec<Notification> {
    let mut notifications: Vec<Notification> = settings.get(&key(account)).and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default();
    prune(&mut notifications, now);
    notifications
}

/// The newest 20, none older than a week.
fn prune(notifications: &mut Vec<Notification>, now: DateTime<Utc>) {
    let oldest = now - Duration::days(KEPT_FOR);
    notifications.retain(|notification| notification.created_at >= oldest);
    notifications.sort_by_key(|notification| std::cmp::Reverse(notification.created_at));
    notifications.truncate(KEPT);
}

fn save(settings: &Settings, account: &str, notifications: &[Notification]) {
    let text = serde_json::to_string(notifications).ok().filter(|_| !notifications.is_empty());
    settings.set(&key(account), text.as_deref());
}

/// Keep `notification`, first.
pub fn add(settings: &Settings, account: &str, notification: Notification, now: DateTime<Utc>) {
    let mut notifications = kept(settings, account, now);
    notifications.insert(0, notification);
    prune(&mut notifications, now);
    save(settings, account, &notifications);
}

/// Mark the notifications `ids` read, those still unread.
pub fn mark_read(settings: &Settings, account: &str, ids: &[String], now: DateTime<Utc>) {
    let mut notifications = kept(settings, account, now);
    for notification in notifications.iter_mut().filter(|notification| notification.read_at.is_none() && ids.contains(&notification.id)) {
        notification.read_at = Some(now);
    }
    save(settings, account, &notifications);
}

pub fn delete(settings: &Settings, account: &str, id: &str, now: DateTime<Utc>) {
    let mut notifications = kept(settings, account, now);
    notifications.retain(|notification| notification.id != id);
    save(settings, account, &notifications);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn import(title: &str, needs_look: bool, at: DateTime<Utc>) -> Notification {
        Notification::new(title.to_owned(), None, needs_look, Vec::new(), at)
    }

    #[test]
    fn a_clean_import_arrives_read_and_one_that_needs_a_look_unread() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("gallery.json"));
        let now = Utc::now();
        add(&settings, "me", import("Imported 3", false, now), now);
        let failed = Notification::new("Imported 1".into(), Some("2 not imported".into()), true, vec![File { name: "a.jpg".into(), reason: "offline".into() }], now + Duration::seconds(1));
        add(&settings, "me", failed.clone(), now);
        let kept_now = kept(&Settings::open(&folder.path().join("gallery.json")), "me", now);
        assert_eq!(kept_now.iter().map(|notification| notification.title.as_str()).collect::<Vec<_>>(), ["Imported 1", "Imported 3"], "newest first, kept across runs");
        assert_eq!((kept_now[0].read_at, kept_now[1].read_at.is_some()), (None, true));
        assert_eq!(kept_now[0].files, failed.files);
        assert!(kept(&settings, "someone else", now).is_empty());
        mark_read(&settings, "me", std::slice::from_ref(&failed.id), now);
        assert!(kept(&settings, "me", now).iter().all(|notification| notification.read_at.is_some()));
        delete(&settings, "me", &failed.id, now);
        assert_eq!(kept(&settings, "me", now).len(), 1);
    }

    #[test]
    fn the_newest_twenty_are_kept_for_a_week() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("gallery.json"));
        let now = Utc::now();
        add(&settings, "me", import("Old", false, now - Duration::days(8)), now - Duration::days(8));
        assert_eq!(kept(&settings, "me", now).len(), 0, "older than a week");
        for minute in 0..25 {
            let at = now - Duration::minutes(25 - minute);
            add(&settings, "me", import(&format!("Import {minute}"), false, at), now);
        }
        let kept_now = kept(&settings, "me", now);
        assert_eq!(kept_now.len(), 20);
        assert_eq!((kept_now[0].title.as_str(), kept_now[19].title.as_str()), ("Import 24", "Import 5"));
    }
}
