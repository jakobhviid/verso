//! Verso's own notifications as Linux keeps them, in the gallery's settings (`settings`), for each account as the
//! recent searches are: what each import came to, once it went from the foot of the sidebar. What is kept, for how
//! long and how each arrives are the core's (`verso_core::notifications`), as on the Mac and the iPhone. The server's
//! own notifications are Immich's (`immich_api::notification`).

use chrono::{DateTime, Utc};
pub use verso_core::notifications::{File, Notification};
use verso_core::notifications::{self, key};

use crate::settings::Settings;

/// The notifications of an account (one per server and user, `Connection::account_key`), newest first: the newest 20,
/// none older than a week.
pub fn kept(settings: &Settings, account: &str, now: DateTime<Utc>) -> Vec<Notification> {
    let mut kept = notifications::read_linux(&settings.get(&key(account)).unwrap_or_default());
    notifications::prune(&mut kept, now);
    kept
}

fn save(settings: &Settings, account: &str, kept: &[Notification]) {
    settings.set(&key(account), notifications::linux_json(kept).as_deref());
}

/// Keep `notification`, first.
pub fn add(settings: &Settings, account: &str, notification: Notification, now: DateTime<Utc>) {
    let mut list = kept(settings, account, now);
    notifications::add(&mut list, notification, now);
    save(settings, account, &list);
}

/// Mark the notifications `ids` read, those still unread.
pub fn mark_read(settings: &Settings, account: &str, ids: &[String], now: DateTime<Utc>) {
    let mut list = kept(settings, account, now);
    notifications::mark_read(&mut list, ids, now);
    save(settings, account, &list);
}

pub fn delete(settings: &Settings, account: &str, id: &str, now: DateTime<Utc>) {
    let mut list = kept(settings, account, now);
    notifications::delete(&mut list, &[id.to_owned()]);
    save(settings, account, &list);
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn they_are_kept_for_each_account_across_runs() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("gallery.json"));
        let now = Utc::now();
        add(&settings, "me", Notification::new("Imported 3".into(), None, false, Vec::new(), now), now);
        let failed = Notification::new("Imported 1".into(), Some("2 not imported".into()), true, vec![File { name: "a.jpg".into(), reason: "offline".into() }], now + Duration::seconds(1));
        add(&settings, "me", failed.clone(), now);
        let kept_now = kept(&Settings::open(&folder.path().join("gallery.json")), "me", now);
        assert_eq!(kept_now.iter().map(|notification| notification.title.as_str()).collect::<Vec<_>>(), ["Imported 1", "Imported 3"]);
        assert!(kept(&settings, "someone else", now).is_empty());
        mark_read(&settings, "me", std::slice::from_ref(&failed.id), now);
        assert!(kept(&settings, "me", now).iter().all(|notification| notification.read_at.is_some()));
        delete(&settings, "me", &failed.id, now);
        assert_eq!(kept(&settings, "me", now).len(), 1);
        assert!(kept(&settings, "me", now + Duration::days(8)).is_empty(), "older than a week");
    }
}
