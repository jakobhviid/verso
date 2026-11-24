//! The gallery's remembered choices (a page's view options, the albums' order, the sidebar's album sections), in one
//! small JSON file: `$XDG_CONFIG_HOME/verso/gallery.json`, beside the drive's `config.toml`. Missing or unreadable,
//! every choice is its default; each change is written at once, to a new file moved into place. Immich Gallery's
//! file, from before the app was Verso, is taken over once.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// `$XDG_CONFIG_HOME`.
fn config_home() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
    std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|path| path.is_absolute()).unwrap_or_else(|| home.join(".config"))
}

/// The settings file.
pub fn settings_path() -> PathBuf {
    path_in(&config_home())
}

fn path_in(config_home: &Path) -> PathBuf {
    config_home.join("verso").join("gallery.json")
}

/// Copy Immich Gallery's settings to Verso's file, where Verso has none yet. The old file stays, for an Immich Gallery
/// still installed.
fn adopt_earlier(config_home: &Path) {
    let (earlier, path) = (config_home.join("immich-gallery").join("settings.json"), path_in(config_home));
    if !path.exists() && earlier.exists() {
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        let _ = std::fs::copy(earlier, path);
    }
}

/// The app's settings, read once.
pub fn shared() -> &'static Settings {
    static SHARED: std::sync::OnceLock<Settings> = std::sync::OnceLock::new();
    SHARED.get_or_init(|| {
        adopt_earlier(&config_home());
        Settings::open(&settings_path())
    })
}

/// Choices by key, such as `grid.library.order`.
pub struct Settings {
    path: PathBuf,
    values: Mutex<BTreeMap<String, String>>,
}

impl Settings {
    pub fn open(path: &Path) -> Settings {
        let values = std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default();
        Settings { path: path.to_owned(), values: Mutex::new(values) }
    }

    pub fn get(&self, key: &str) -> Option<String> {
        self.values.lock().ok()?.get(key).cloned()
    }

    /// Remember a choice; `None` forgets it. A failed write keeps it for this run only.
    pub fn set(&self, key: &str, value: Option<&str>) {
        let Ok(mut values) = self.values.lock() else { return };
        match value {
            Some(value) => values.insert(key.to_owned(), value.to_owned()),
            None => values.remove(key),
        };
        let Ok(text) = serde_json::to_vec_pretty(&*values) else { return };
        if let Some(folder) = self.path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        let partial = self.path.with_extension("json.partial");
        if std::fs::write(&partial, text).is_ok() {
            let _ = std::fs::rename(&partial, &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_choice_is_remembered_across_runs_and_a_bad_file_means_defaults() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("verso/gallery.json");
        let settings = Settings::open(&path);
        assert_eq!(settings.get("grid.library.order"), None);
        settings.set("grid.library.order", Some("asc"));
        assert_eq!(Settings::open(&path).get("grid.library.order").as_deref(), Some("asc"));
        settings.set("grid.library.order", None);
        assert_eq!(Settings::open(&path).get("grid.library.order"), None);
        std::fs::write(&path, b"not json").unwrap();
        assert_eq!(Settings::open(&path).get("anything"), None);
    }

    #[test]
    fn immich_gallerys_settings_are_taken_over_once() {
        let home = tempfile::tempdir().unwrap();
        let earlier = home.path().join("immich-gallery/settings.json");
        std::fs::create_dir_all(earlier.parent().unwrap()).unwrap();
        std::fs::write(&earlier, br#"{"grid.library.order":"asc"}"#).unwrap();
        adopt_earlier(home.path());
        assert_eq!(Settings::open(&path_in(home.path())).get("grid.library.order").as_deref(), Some("asc"));
        Settings::open(&path_in(home.path())).set("grid.library.order", Some("desc"));
        adopt_earlier(home.path());
        assert_eq!(Settings::open(&path_in(home.path())).get("grid.library.order").as_deref(), Some("desc"), "only once");
        assert!(earlier.exists(), "the old file stays");
    }
}
