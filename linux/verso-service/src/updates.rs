//! The look at Verso's page for a newer release (ARCHITECTURE.md, "Updates on Linux"), and which installs make it: the
//! rpm and the deb, which nothing else updates, built as `verso_core::product::VERSO_PACKAGE`, whose `updates.check`
//! is on until switched off. Every other product reads the setting as off; Homebrew updates its own, a Flatpak's
//! remote updates it, and a development build has no release to compare (`verso_linux::updates`).

use std::path::Path;
use std::time::Duration;

use verso_core::settings::Config;
use verso_linux::updates::{Check, Release};

/// Written by Verso's page for its latest release (site/build.py): the version and the page's address.
const LATEST: &str = "https://jakob.hviid.phd/verso/latest.json";

#[derive(serde::Deserialize)]
struct Latest {
    version: String,
    page: String,
}

/// Whether this install looks: with `updates.check` on, as only the rpm's and the deb's product reads it unless it was
/// switched off, and never under Homebrew or in a Flatpak, whatever the setting.
pub fn wanted(config: &Config) -> bool {
    if !config.update_check || std::env::var_os("FLATPAK_ID").is_some() {
        return false;
    }
    let program = std::env::current_exe().and_then(|program| program.canonicalize()).unwrap_or_default();
    !installed_by_homebrew(&program)
}

/// A program in Homebrew's cellar or a cask's folder, which `brew upgrade` keeps current.
fn installed_by_homebrew(program: &Path) -> bool {
    let text = program.to_string_lossy();
    ["/Caskroom/", "/Cellar/", "/.linuxbrew/"].iter().any(|part| text.contains(part))
}

/// One look, as the daemon makes it once a day. Nothing is sent but the request and its User-Agent.
pub fn check() -> Check {
    Box::new(|| Box::pin(latest()))
}

async fn latest() -> Option<Release> {
    let client = reqwest::Client::builder()
        .user_agent(verso_core::product::user_agent())
        .timeout(Duration::from_secs(30))
        .build()
        .ok()?;
    let response = client.get(LATEST).send().await.ok()?.error_for_status().ok()?;
    let latest: Latest = response.json().await.ok()?;
    Some(Release { version: latest.version, page: latest.page })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn homebrew_installs_are_left_to_homebrew() {
        assert!(installed_by_homebrew(Path::new("/home/linuxbrew/.linuxbrew/Caskroom/verso/2.19.1/verso/verso-service")));
        assert!(installed_by_homebrew(Path::new("/home/linuxbrew/.linuxbrew/Cellar/verso/2.19.1/bin/verso-service")));
        assert!(!installed_by_homebrew(Path::new("/usr/bin/verso-service")));
        assert!(!installed_by_homebrew(Path::new("/home/me/.local/bin/verso-service")));
    }

    #[test]
    fn the_setting_turns_it_off() {
        let off = Config::from_toml("[updates]\ncheck = false\n").expect("the settings parse");
        assert!(!wanted(&off));
    }

    #[test]
    fn the_packages_look_and_the_tarball_does_not() {
        use verso_core::product::{VERSO, VERSO_PACKAGE};
        assert!(wanted(&Config::from_toml_for("", &VERSO_PACKAGE).expect("the settings parse")));
        assert!(!wanted(&Config::from_toml_for("[updates]\ncheck = true\n", &VERSO).expect("the settings parse")));
    }
}
