//! The AppImage's service at login (ARCHITECTURE.md, "Verso as an AppImage"): an autostart entry in the user's
//! `autostart` folder that runs the AppImage file's service. A systemd unit would name a path inside a mount that goes
//! with the process that made it, and the file itself may move, so the entry names the file as it is now and is written
//! again where it differs. Only the AppImage's product has one; for every other, each function does nothing.

use std::path::{Path, PathBuf};

use crate::paths::Paths;

/// The entry's file name, in `~/.config/autostart`.
const ENTRY: &str = "dev.hviid.Verso.Service.desktop";

/// The AppImage file this process runs from, as the runtime says (`APPIMAGE`): where it is now, which is not where it
/// was when it was downloaded, and not its mount, which goes when the process does.
pub fn image() -> Result<PathBuf, String> {
    std::env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .filter(|file| file.is_absolute())
        .ok_or_else(|| "this is not run from an AppImage file (the runtime sets APPIMAGE)".to_owned())
}

/// The entry's place.
fn entry(paths: &Paths) -> PathBuf {
    paths.config_directory.parent().unwrap_or(&paths.home).join("autostart").join(ENTRY)
}

/// A program path as an `Exec` value: in quotes, with what the Desktop Entry Specification reserves escaped, twice
/// where it escapes the escape (the entry's string syntax, then the quoting's), and `%` doubled.
fn exec_quoted(program: &Path) -> String {
    let mut quoted = String::from("\"");
    for character in program.to_string_lossy().chars() {
        match character {
            '"' | '`' | '$' => {
                quoted.push_str("\\\\");
                quoted.push(character);
            }
            '\\' => quoted.push_str("\\\\\\\\"),
            '%' => quoted.push_str("%%"),
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

/// The entry that runs the AppImage `file`'s service.
fn text(file: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Verso\nComment=Verso's icon in the top bar, while you are signed in\n\
         Exec={} verso-service daemon\nIcon=dev.hviid.Verso\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n",
        exec_quoted(file)
    )
}

/// Write the entry for the AppImage file this runs from, unless it says so already.
pub fn write(paths: &Paths) -> Result<(), String> {
    if !verso_core::product::current().appimage {
        return Ok(());
    }
    let place = entry(paths);
    let wanted = text(&image()?);
    if std::fs::read_to_string(&place).ok().as_deref() == Some(wanted.as_str()) {
        return Ok(());
    }
    if let Some(folder) = place.parent() {
        std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
    }
    std::fs::write(&place, wanted).map_err(|error| format!("{}: {error}", place.display()))
}

/// Name the AppImage file's place as it is now in the entry, where there is one: the file may have moved since it was
/// written, and a person who took the entry away asked for no service at login, which stays so.
pub fn refresh(paths: &Paths) {
    if verso_core::product::current().appimage && entry(paths).exists() {
        let _ = write(paths);
    }
}

/// Take the entry away (signing out), so the service no longer starts at login.
pub fn remove(paths: &Paths) {
    if verso_core::product::current().appimage {
        let _ = std::fs::remove_file(entry(paths));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_programs_path_is_quoted_for_the_entry() {
        assert_eq!(exec_quoted(Path::new("/home/me/Apps/Verso.AppImage")), "\"/home/me/Apps/Verso.AppImage\"");
        assert_eq!(exec_quoted(Path::new("/home/me/My Apps/100%.AppImage")), "\"/home/me/My Apps/100%%.AppImage\"");
        assert_eq!(exec_quoted(Path::new("/a\"b$c`d\\e")), "\"/a\\\\\"b\\\\$c\\\\`d\\\\\\\\e\"");
    }

    #[test]
    fn the_entry_runs_the_service_of_the_file() {
        let wanted = text(Path::new("/home/me/Verso.AppImage"));
        assert!(wanted.lines().any(|line| line == "Exec=\"/home/me/Verso.AppImage\" verso-service daemon"));
        assert!(wanted.contains("NoDisplay=true") && wanted.contains("X-GNOME-Autostart-enabled=true"));
    }

    #[test]
    fn it_is_the_appimages_alone() {
        let paths = Paths::from_environment();
        // The test's product is the tarball's Verso: nothing is written or removed.
        assert_eq!(write(&paths), Ok(()));
    }
}
