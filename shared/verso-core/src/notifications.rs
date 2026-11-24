//! Verso's own notifications, beside the server's in the bell (in the account's sheet on the iPhone), kept on the device
//! for each account (one per server and user), never sent to Immich: what an import came to, and on the iPhone what
//! backing up needs. The newest 20, none older than a week; one that went cleanly arrives read, as it was seen
//! happening, and one that needs a look unread. Linux's window, the Mac and the iPhone (through `verso-bridge`) all
//! keep them here. The server's own notifications are Immich's (`immich_api::notification`).
//!
//! Each platform keeps them in a form of its own, which the core reads and writes as it is, so nothing kept needs
//! migrating: one JSON array on each, with RFC 3339 dates and the line under the title as `caption` on Linux, and
//! Foundation's dates (seconds since 2001), that line as `detail` and UUIDs for ids on the Mac and the iPhone.

use chrono::{DateTime, Duration, TimeZone, Utc};
use serde::{Deserialize, Serialize};

/// How many are kept.
pub const KEPT: usize = 20;

/// How long one is kept, in days.
pub const KEPT_FOR: i64 = 7;

/// A file an import did not bring in, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    pub name: String,
    pub reason: String,
}

/// One of Verso's notifications, as Linux keeps it.
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
    /// A notification made `now`, with an id of its own (Linux's: the time in nanoseconds, in hexadecimal): read at
    /// once, unless it needs a look.
    pub fn new(title: String, caption: Option<String>, needs_look: bool, files: Vec<File>, now: DateTime<Utc>) -> Notification {
        let id = format!("{:x}", now.timestamp_nanos_opt().unwrap_or_else(|| now.timestamp()));
        Notification { id, created_at: now, title, caption, needs_look, read_at: (!needs_look).then_some(now), files }
    }
}

/// One as the Mac and the iPhone keep it.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppleNotification {
    id: String,
    created_at: f64,
    title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    #[serde(default)]
    needs_look: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    read_at: Option<f64>,
    #[serde(default)]
    files: Vec<File>,
}

/// Foundation's reference date, 2001-01-01 at midnight UTC, in seconds since 1970.
const FOUNDATION_EPOCH: i64 = 978_307_200;

/// A date as Foundation encodes one: seconds since its reference date.
pub fn foundation_seconds(date: DateTime<Utc>) -> f64 {
    (date.timestamp() - FOUNDATION_EPOCH) as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9
}

/// A date Foundation encoded; none for one out of range.
pub fn from_foundation_seconds(seconds: f64) -> Option<DateTime<Utc>> {
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1e9).round().min(999_999_999.0) as u32;
    Utc.timestamp_opt(whole as i64 + FOUNDATION_EPOCH, nanos).single()
}

/// Linux's, as kept; none from what is not that.
pub fn read_linux(stored: &str) -> Vec<Notification> {
    serde_json::from_str(stored).unwrap_or_default()
}

/// Linux's, as kept; none while there are none.
pub fn linux_json(notifications: &[Notification]) -> Option<String> {
    serde_json::to_string(notifications).ok().filter(|_| !notifications.is_empty())
}

/// The Mac's and the iPhone's, as kept; none from what is not that.
pub fn read_apple(stored: &str) -> Vec<Notification> {
    let kept: Vec<AppleNotification> = serde_json::from_str(stored).unwrap_or_default();
    kept.into_iter()
        .filter_map(|kept| {
            Some(Notification {
                created_at: from_foundation_seconds(kept.created_at)?,
                read_at: kept.read_at.and_then(from_foundation_seconds),
                id: kept.id,
                title: kept.title,
                caption: kept.detail,
                needs_look: kept.needs_look,
                files: kept.files,
            })
        })
        .collect()
}

/// The Mac's and the iPhone's, as kept: `[]` while there are none.
pub fn apple_json(notifications: &[Notification]) -> String {
    let kept: Vec<AppleNotification> = notifications
        .iter()
        .map(|notification| AppleNotification {
            id: notification.id.clone(),
            created_at: foundation_seconds(notification.created_at),
            title: notification.title.clone(),
            detail: notification.caption.clone(),
            needs_look: notification.needs_look,
            read_at: notification.read_at.map(foundation_seconds),
            files: notification.files.clone(),
        })
        .collect();
    serde_json::to_string(&kept).unwrap_or_else(|_| "[]".to_owned())
}

/// The newest 20, none older than a week, the newest first.
pub fn prune(notifications: &mut Vec<Notification>, now: DateTime<Utc>) {
    let oldest = now - Duration::days(KEPT_FOR);
    notifications.retain(|notification| notification.created_at >= oldest);
    notifications.sort_by_key(|notification| std::cmp::Reverse(notification.created_at));
    notifications.truncate(KEPT);
}

/// Keep `notification`, first: read as it was made, unless it needs a look.
pub fn add(notifications: &mut Vec<Notification>, mut notification: Notification, now: DateTime<Utc>) {
    if !notification.needs_look && notification.read_at.is_none() {
        notification.read_at = Some(notification.created_at);
    }
    notifications.insert(0, notification);
    prune(notifications, now);
}

/// Mark the notifications `ids` read, those still unread.
pub fn mark_read(notifications: &mut [Notification], ids: &[String], now: DateTime<Utc>) {
    for notification in notifications.iter_mut().filter(|notification| notification.read_at.is_none() && ids.contains(&notification.id)) {
        notification.read_at = Some(now);
    }
}

/// Clear the notifications `ids`.
pub fn delete(notifications: &mut Vec<Notification>, ids: &[String]) {
    notifications.retain(|notification| !ids.contains(&notification.id));
}

/// How many are unread.
pub fn unread(notifications: &[Notification]) -> usize {
    notifications.iter().filter(|notification| notification.read_at.is_none()).count()
}

/// Where an account's are kept, by the platform's key for the account: Linux's cache folder's name
/// (`Connection::account_key`), the Mac's and the iPhone's API address and user (`https://host/api|<user>`).
pub fn key(account: &str) -> String {
    format!("notifications.verso.{account}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn import(title: &str, needs_look: bool, at: DateTime<Utc>) -> Notification {
        Notification::new(title.to_owned(), None, needs_look, Vec::new(), at)
    }

    fn titles(notifications: &[Notification]) -> Vec<&str> {
        notifications.iter().map(|notification| notification.title.as_str()).collect()
    }

    #[test]
    fn a_clean_import_arrives_read_and_one_that_needs_a_look_unread() {
        let now = Utc::now();
        let mut kept = Vec::new();
        add(&mut kept, import("Imported 3", false, now), now);
        let failed = Notification::new("Imported 1".into(), Some("2 not imported".into()), true, vec![File { name: "a.jpg".into(), reason: "offline".into() }], now + Duration::seconds(1));
        add(&mut kept, failed.clone(), now);
        let kept_now = read_linux(&linux_json(&kept).unwrap());
        assert_eq!(titles(&kept_now), ["Imported 1", "Imported 3"], "newest first, kept across runs");
        assert_eq!((kept_now[0].read_at, kept_now[1].read_at.is_some()), (None, true));
        assert_eq!((kept_now[0].files.clone(), unread(&kept_now)), (failed.files.clone(), 1));
        let mut kept = kept_now;
        mark_read(&mut kept, std::slice::from_ref(&failed.id), now);
        assert!(kept.iter().all(|notification| notification.read_at.is_some()));
        delete(&mut kept, std::slice::from_ref(&failed.id));
        assert_eq!(kept.len(), 1);
        let last = kept[0].id.clone();
        delete(&mut kept, &[last]);
        assert_eq!(linux_json(&kept), None);
    }

    #[test]
    fn a_notification_made_on_the_mac_arrives_read_at_its_own_making() {
        let now = Utc::now();
        let made = now - Duration::seconds(5);
        let mut kept = Vec::new();
        let clean = Notification { id: "6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B".into(), created_at: made, title: "Imported 12".into(), caption: None, needs_look: false, read_at: None, files: Vec::new() };
        add(&mut kept, clean, now);
        assert_eq!(kept[0].read_at, Some(made));
        // Marking read again keeps the first time.
        mark_read(&mut kept, &["6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B".to_owned()], now);
        assert_eq!(kept[0].read_at, Some(made));
    }

    #[test]
    fn the_newest_twenty_are_kept_for_a_week() {
        let now = Utc::now();
        let mut kept = Vec::new();
        add(&mut kept, import("Old", false, now - Duration::days(8)), now - Duration::days(8));
        prune(&mut kept, now);
        assert!(kept.is_empty(), "older than a week");
        for minute in 0..25 {
            let at = now - Duration::minutes(25 - minute);
            add(&mut kept, import(&format!("Import {minute}"), false, at), now);
        }
        assert_eq!(kept.len(), 20);
        assert_eq!((kept[0].title.as_str(), kept[19].title.as_str()), ("Import 24", "Import 5"));
    }

    #[test]
    fn the_macs_are_read_and_written_as_foundation_keeps_them() {
        let kept = r#"[{"id":"7A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9","createdAt":785577600.5,"title":"Imported 3 of 5","detail":"2 not imported","needsLook":true,"files":[{"name":"IMG_0001.HEIC","reason":"The server refused it"}]},{"id":"6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B","createdAt":785574000,"title":"Imported 12 photos","needsLook":false,"readAt":785574000,"files":[]}]"#;
        let read = read_apple(kept);
        assert_eq!(titles(&read), ["Imported 3 of 5", "Imported 12 photos"]);
        assert_eq!(read[0].created_at, Utc.with_ymd_and_hms(2025, 11, 23, 8, 0, 0).unwrap() + Duration::milliseconds(500));
        assert_eq!((read[0].caption.as_deref(), read[0].read_at, read[1].read_at.is_some()), (Some("2 not imported"), None, true));
        let written = apple_json(&read);
        assert_eq!(written, r#"[{"id":"7A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9","createdAt":785577600.5,"title":"Imported 3 of 5","detail":"2 not imported","needsLook":true,"files":[{"name":"IMG_0001.HEIC","reason":"The server refused it"}]},{"id":"6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B","createdAt":785574000.0,"title":"Imported 12 photos","needsLook":false,"readAt":785574000.0,"files":[]}]"#);
        assert_eq!(read_apple(&written), read);
        assert_eq!(apple_json(&[]), "[]");
        assert!(read_apple("not json").is_empty() && read_linux("").is_empty());
        assert_eq!(foundation_seconds(from_foundation_seconds(785_577_600.123_456).unwrap()), 785_577_600.123_456);
    }

    #[test]
    fn each_account_keeps_its_own() {
        assert_eq!(key("4f2a"), "notifications.verso.4f2a");
        assert_eq!(key("https://demo.immich.app/api|me"), "notifications.verso.https://demo.immich.app/api|me");
    }
}
