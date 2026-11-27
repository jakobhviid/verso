//! Telling of a newer release (ARCHITECTURE.md, "Updates on Linux"): for packages downloaded from the download page,
//! which no repository updates, the daemon looks once a day and says so once per version, in a notification and on
//! the tray's menu. The look itself is the caller's (`Check`), which has the HTTP client.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::time::Duration;

use crate::i18n::tr;

/// The newest release, as the download page names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    /// The page that offers it.
    pub page: String,
}

/// One look at the newest release; `None` when the page cannot be read.
pub type Check = Box<dyn Fn() -> Pin<Box<dyn Future<Output = Option<Release>> + Send>> + Send + Sync>;

const EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// A look asked for from the tray's Check for Updates, which wakes `follow` at once.
fn requested() -> &'static tokio::sync::Notify {
    static REQUESTED: std::sync::OnceLock<tokio::sync::Notify> = std::sync::OnceLock::new();
    REQUESTED.get_or_init(tokio::sync::Notify::new)
}

/// Look now, as the tray's Check for Updates asks: what is found is told as a daily look tells it, and when nothing
/// newer is out the person who asked is told so.
pub fn check_now() {
    requested().notify_one();
}
/// The first look waits until the session has settled, so it never slows the login.
const FIRST: Duration = Duration::from_secs(5 * 60);

/// A release's version, `major.minor.patch` and a beta's suffix (`0.78.0-beta.2`), ordered as semantic versioning
/// orders them: a beta before the release it leads to, and its parts by number where they are numbers.
#[derive(Debug, PartialEq, Eq)]
struct Version {
    release: (u64, u64, u64),
    beta: Option<Vec<String>>,
}

impl Version {
    fn parse(text: &str) -> Option<Version> {
        let text = text.trim().trim_start_matches('v');
        let (numbers, beta) = match text.split_once('-') {
            Some((numbers, beta)) => (numbers, Some(beta.split('.').map(str::to_owned).collect())),
            None => (text, None),
        };
        let mut parts = numbers.split('.').map(|part| part.parse::<u64>().ok());
        let release = (parts.next()??, parts.next()??, parts.next()??);
        parts.next().is_none().then_some(Version { release, beta })
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        self.release.cmp(&other.release).then_with(|| match (&self.beta, &other.beta) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(mine), Some(theirs)) => {
                for (one, two) in mine.iter().zip(theirs) {
                    let order = match (one.parse::<u64>(), two.parse::<u64>()) {
                        (Ok(one), Ok(two)) => one.cmp(&two),
                        (Ok(_), Err(_)) => Ordering::Less,
                        (Err(_), Ok(_)) => Ordering::Greater,
                        (Err(_), Err(_)) => one.cmp(two),
                    };
                    if order != Ordering::Equal {
                        return order;
                    }
                }
                mine.len().cmp(&theirs.len())
            }
        })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// Whether `latest` is newer than `running`, each a release's version or a beta's. A development build (`0.0.0`) never
/// is behind: its version is not a release's.
pub fn is_newer(latest: &str, running: &str) -> bool {
    match (Version::parse(latest), Version::parse(running)) {
        (Some(latest), Some(running)) => running.release != (0, 0, 0) && latest > running,
        _ => false,
    }
}

/// Whether `version` is a beta's (`0.78.0-beta.1`), whose install looks at the beta channel.
pub fn is_beta(version: &str) -> bool {
    Version::parse(version).is_some_and(|version| version.beta.is_some())
}

/// Look now and then once a day, for as long as the daemon runs. `told` keeps the last version told of, so each is
/// told once, across restarts.
pub async fn follow(check: Check, running: &'static str, connection: Option<zbus::Connection>, told: PathBuf) {
    let mut asked = tokio::select! {
        _ = tokio::time::sleep(FIRST) => false,
        _ = requested().notified() => true,
    };
    loop {
        let newer = check().await.filter(|release| is_newer(&release.version, running));
        if newer.is_none() && asked {
            crate::notify::notify_in_background(
                tr("{app} is up to date").replace("{app}", verso_core::product::current().name),
                tr("{version} is the newest version.").replace("{version}", running),
            );
        }
        if let Some(release) = newer {
            log::info!("{} {} is out ({running} runs here)", verso_core::product::current().name, release.version);
            if let Some(connection) = &connection {
                crate::tray::offer_update(connection, &release).await;
            }
            let already = std::fs::read_to_string(&told).ok().is_some_and(|version| version.trim() == release.version);
            if !already {
                crate::notify::notify_in_background(
                    tr("{app} {version} is available").replace("{app}", verso_core::product::current().name).replace("{version}", &release.version),
                    tr("Get it from jakob.hviid.phd/verso.").to_owned(),
                );
                if let Some(folder) = told.parent() {
                    let _ = std::fs::create_dir_all(folder);
                }
                let _ = std::fs::write(&told, &release.version);
            }
        }
        asked = tokio::select! {
            _ = tokio::time::sleep(EVERY) => false,
            _ = requested().notified() => true,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_by_their_numbers() {
        assert!(is_newer("2.20.0", "2.19.1"));
        assert!(is_newer("2.10.0", "2.9.9"), "numbers, not text");
        assert!(is_newer("v3.0.0", "2.99.0"));
        assert!(!is_newer("2.19.1", "2.19.1"));
        assert!(!is_newer("2.19.0", "2.19.1"));
        assert!(!is_newer("2.20.0", "0.0.0"), "a development build is never behind");
        assert!(!is_newer("not a version", "2.19.1"));
    }

    #[test]
    fn a_beta_comes_before_its_release_and_after_the_last() {
        assert!(is_newer("0.78.0", "0.78.0-beta.2"), "the release a beta leads to");
        assert!(is_newer("0.78.0-beta.2", "0.78.0-beta.1"));
        assert!(is_newer("0.78.0-beta.10", "0.78.0-beta.9"), "numbers, not text");
        assert!(is_newer("0.78.0-beta.1", "0.77.0"));
        assert!(!is_newer("0.77.0", "0.78.0-beta.1"));
        assert!(!is_newer("0.78.0-beta.1", "0.78.0"));
        assert!(!is_newer("0.78.0-beta.1", "0.78.0-beta.1"));
        assert!(is_beta("0.78.0-beta.1") && !is_beta("0.78.0") && !is_beta("nonsense"));
    }
}
