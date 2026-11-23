//! The app icon chosen in Preferences (`app.icon`) on the desktop (ARCHITECTURE.md, "The app icon's designs on
//! Linux"). The app grid, the dash and the window's place in them show the icon Verso's launcher entry names
//! (`dev.hviid.Verso.desktop`), so Verso names the chosen design there: Mist by the name every install puts in the icon
//! theme, another design by the path of a copy in Verso's own data folder, made from the drawings the install carries
//! among the app's own icons. The service puts the entry right as it starts (after an upgrade replaced it, at every
//! login), and the window as it starts and when the choice changes.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use verso_core::product::{self, Product};
use verso_core::settings::DEFAULT_APP_ICON;

use crate::paths::Paths;

/// The first line of an entry Verso writes in the user's folder over a package's own, in `$XDG_DATA_DIRS`: written
/// again from the package's at each start, so it follows the package's changes, and removed when the choice is Mist or
/// the package's entry is gone.
const WRITTEN: &str = "# Written by Verso over the installed entry, for the app icon chosen in Preferences (app.icon).\n";

/// The folders the app's own icons are in: `icons` in the install's folder, as the tarball has them, or, run from a
/// checkout, beside the sources.
pub fn icon_folders() -> Vec<PathBuf> {
    let beside = crate::programs::install_folder().map(|folder| folder.join("icons"));
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packaging/icons");
    beside.into_iter().chain([checkout]).filter(|folder| folder.is_dir()).collect()
}

/// Name `design` in Verso's launcher entry. Nothing in a Flatpak, which offers no choice and cannot reach its entry.
pub fn apply(paths: &Paths, design: &str) {
    let product = product::current();
    if product.sandboxed {
        return;
    }
    let Some(icon) = icon_for(paths, product, design) else { return };
    // The user's folder of entries beside Verso's data (`$XDG_DATA_HOME`), then the system's (`$XDG_DATA_DIRS`).
    let own = paths.data_directory.parent().unwrap_or(&paths.home).join("applications");
    let folders: Vec<PathBuf> = std::iter::once(own).chain(crate::crosslink_apps::application_folders().into_iter().skip(1)).collect();
    match name_icon(&folders, product.id, &icon) {
        Ok(true) => log::info!("Verso's launcher shows the app icon {design}"),
        Ok(false) => {}
        Err(error) => log::warn!("could not give Verso's launcher the app icon {design}: {error}"),
    }
}

/// The icon that shows the chosen design outside the window, as an entry's `Icon` and a notification's picture take it:
/// the product's own name for Mist, else the path of Verso's copy, or the product's own name while it has none.
pub fn shown(paths: &Paths) -> String {
    let product = product::current();
    let design = std::fs::read_to_string(paths.config_file())
        .ok()
        .and_then(|text| verso_core::settings::Config::from_toml(&text).ok())
        .map_or(DEFAULT_APP_ICON, |config| config.app_icon);
    let copy = paths.data_directory.join("icons").join(format!("{}.svg", product.app_icon(design)));
    if design != DEFAULT_APP_ICON && copy.is_file() { copy.to_string_lossy().into_owned() } else { product.id.to_owned() }
}

/// What the entry's `Icon` says for `design`: the product's own name for Mist; for another, the path of its drawing,
/// copied into Verso's data folder (`icons/`), where the copies of the others go. None when the install has no
/// drawing of it, which leaves the entry as it is.
fn icon_for(paths: &Paths, product: &Product, design: &str) -> Option<String> {
    let folder = paths.data_directory.join("icons");
    let name = product.app_icon(design);
    let file_name = format!("{name}.svg");
    if let Ok(listing) = std::fs::read_dir(&folder) {
        for entry in listing.flatten() {
            let other = entry.file_name().to_string_lossy().into_owned();
            if other != file_name && other.starts_with(product.id) && other.ends_with(".svg") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    if design == DEFAULT_APP_ICON {
        return Some(name);
    }
    let Some(drawing) = icon_folders().into_iter().find_map(|icons| std::fs::read(icons.join(&file_name)).ok()) else {
        log::warn!("this install of Verso has no drawing of the app icon {design} ({file_name})");
        return None;
    };
    let copy = folder.join(&file_name);
    if let Err(error) = replace_if_changed(&copy, &drawing) {
        log::warn!("could not keep the app icon {design} in {}: {error}", folder.display());
        return None;
    }
    copy.to_str().map(str::to_owned)
}

/// Name `icon` in the launcher entry `<id>.desktop`, in the first of `folders` (the user's own) or after it. The
/// install's entry in the user's folder (Homebrew's cask, the tarball, a build of one's own) has its `Icon` line
/// changed and nothing else; over a package's entry, Verso writes one of its own in the user's folder, while a design
/// other than the product's own (`id`) is chosen. Whether anything changed.
fn name_icon(folders: &[PathBuf], id: &str, icon: &str) -> std::io::Result<bool> {
    let Some((own_folder, others)) = folders.split_first() else { return Ok(false) };
    let file_name = format!("{id}.desktop");
    let own = own_folder.join(&file_name);
    // A link is the user's own arrangement, and what it points at may be anyone's: left alone.
    if own.is_symlink() {
        return Ok(false);
    }
    match std::fs::read(&own) {
        Ok(bytes) => {
            let Ok(text) = String::from_utf8(bytes) else { return Ok(false) };
            if !text.starts_with(WRITTEN) {
                return replace_if_changed(&own, with_icon(&text, icon).as_bytes());
            }
        }
        Err(error) if error.kind() != ErrorKind::NotFound => return Err(error),
        Err(_) => {}
    }
    let installed = others.iter().find_map(|folder| std::fs::read_to_string(folder.join(&file_name)).ok());
    match installed {
        Some(text) if icon != id => replace_if_changed(&own, format!("{WRITTEN}{}", with_icon(&text, icon)).as_bytes()),
        // Verso's own entry, if any, goes: the package's shows its own icon.
        _ => match std::fs::remove_file(&own) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error),
        },
    }
}

/// The entry's text with the `Icon` line of its `[Desktop Entry]` group saying `icon`, added under the group's heading
/// where it has none; every other line as it was.
fn with_icon(text: &str, icon: &str) -> String {
    // A value's backslash is written doubled (the Desktop Entry Specification's escapes).
    let line = format!("Icon={}", icon.replace('\\', "\\\\"));
    let mut group = "";
    let mut named = false;
    let mut lines: Vec<String> = Vec::new();
    for current in text.lines() {
        if current.starts_with('[') {
            group = current.trim();
        }
        if group == "[Desktop Entry]" && !named && current.starts_with("Icon=") {
            lines.push(line.clone());
            named = true;
        } else {
            lines.push(current.to_owned());
        }
    }
    if !named {
        if let Some(heading) = lines.iter().position(|current| current.trim() == "[Desktop Entry]") {
            lines.insert(heading + 1, line);
        }
    }
    lines.join("\n") + "\n"
}

/// Write `contents` to `path` unless it holds them already: through a file beside it, renamed into place, so the file
/// is never missing or half written. Homebrew moves its own entry back at an upgrade, and the upgrade fails where it is
/// gone. Whether it was written.
fn replace_if_changed(path: &Path, contents: &[u8]) -> std::io::Result<bool> {
    if std::fs::read(path).ok().as_deref() == Some(contents) {
        return Ok(false);
    }
    let folder = path.parent().ok_or_else(|| std::io::Error::from(ErrorKind::InvalidInput))?;
    std::fs::create_dir_all(folder)?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    // Hidden, and not named `.desktop`, so nothing reads it as an entry meanwhile; the process's own, as the window and
    // the service may both write at once.
    let temporary = folder.join(format!(".{name}.{}.verso", std::process::id()));
    std::fs::write(&temporary, contents)?;
    std::fs::rename(&temporary, path)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENTRY: &str = "[Desktop Entry]\nName=Verso\nExec=/home/linuxbrew/.linuxbrew/bin/verso %u\nIcon=dev.hviid.Verso\n\
                         # app.immich is the sign-in's redirect\nMimeType=x-scheme-handler/app.immich;\n";

    fn folders(root: &Path) -> Vec<PathBuf> {
        vec![root.join("home/applications"), root.join("system/applications")]
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn only_the_icon_line_of_the_entry_changes() {
        let sand = with_icon(ENTRY, "/home/me/.local/share/verso/icons/dev.hviid.Verso-sand.svg");
        assert_eq!(sand, ENTRY.replace("Icon=dev.hviid.Verso\n", "Icon=/home/me/.local/share/verso/icons/dev.hviid.Verso-sand.svg\n"));
        assert_eq!(with_icon(&sand, "dev.hviid.Verso"), ENTRY, "back at Mist, the entry is as it was");
        // An action's icon is its own; an entry without an icon gets one under its heading.
        let action = format!("{ENTRY}\n[Desktop Action new]\nName=New\nIcon=document-new\n");
        assert!(with_icon(&action, "x").ends_with("Icon=document-new\n"));
        assert_eq!(with_icon("[Desktop Entry]\nName=Verso\n", "x"), "[Desktop Entry]\nIcon=x\nName=Verso\n");
    }

    #[test]
    fn the_users_own_entry_is_changed_in_place_and_kept() {
        let root = tempfile::tempdir().unwrap();
        let folders = folders(root.path());
        let own = folders[0].join("dev.hviid.Verso.desktop");
        write(&own, ENTRY);
        assert!(name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-sky.svg").unwrap());
        assert!(std::fs::read_to_string(&own).unwrap().contains("\nIcon=/icons/dev.hviid.Verso-sky.svg\n"));
        assert!(!name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-sky.svg").unwrap(), "already so");
        // Back at Mist the entry stays, Homebrew's or the tarball's, with the install's icon again.
        assert!(name_icon(&folders, "dev.hviid.Verso", "dev.hviid.Verso").unwrap());
        assert_eq!(std::fs::read_to_string(&own).unwrap(), ENTRY);
        let left: Vec<_> = std::fs::read_dir(&folders[0]).unwrap().flatten().map(|entry| entry.file_name()).collect();
        assert_eq!(left, ["dev.hviid.Verso.desktop"], "no file of its own left beside it");
    }

    #[test]
    fn over_a_packages_entry_verso_writes_its_own_while_another_design_is_chosen() {
        let root = tempfile::tempdir().unwrap();
        let folders = folders(root.path());
        let own = folders[0].join("dev.hviid.Verso.desktop");
        assert!(!name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-sand.svg").unwrap(), "no entry: nothing");
        write(&folders[1].join("dev.hviid.Verso.desktop"), ENTRY);
        assert!(!name_icon(&folders, "dev.hviid.Verso", "dev.hviid.Verso").unwrap(), "Mist: the package's as it is");
        assert!(!own.exists());
        assert!(name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-sand.svg").unwrap());
        let written = std::fs::read_to_string(&own).unwrap();
        assert!(written.starts_with(WRITTEN) && written.contains("\nIcon=/icons/dev.hviid.Verso-sand.svg\n"));
        // Another design rewrites it; Mist, or the package gone, takes it away.
        assert!(name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-dark.svg").unwrap());
        assert!(std::fs::read_to_string(&own).unwrap().contains("\nIcon=/icons/dev.hviid.Verso-dark.svg\n"));
        assert!(name_icon(&folders, "dev.hviid.Verso", "dev.hviid.Verso").unwrap());
        assert!(!own.exists());
        assert!(name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-dark.svg").unwrap());
        std::fs::remove_file(folders[1].join("dev.hviid.Verso.desktop")).unwrap();
        assert!(name_icon(&folders, "dev.hviid.Verso", "/icons/dev.hviid.Verso-dark.svg").unwrap());
        assert!(!own.exists(), "the package's entry is gone, so Verso's goes with it");
    }

    #[test]
    fn the_chosen_design_is_copied_and_the_others_go() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().to_path_buf();
        let paths = Paths {
            config_directory: home.join(".config/verso"),
            cache_directory: home.join(".cache/verso"),
            state_directory: home.join(".local/state/verso"),
            data_directory: home.join(".local/share/verso"),
            thumbnail_directory: home.join(".cache/thumbnails"),
            home,
        };
        let icons = paths.data_directory.join("icons");
        let sand = icon_for(&paths, &verso_core::product::VERSO, "sand").expect("the checkout has its drawing");
        assert_eq!(PathBuf::from(&sand), icons.join("dev.hviid.Verso-sand.svg"));
        assert!(std::fs::read_to_string(&sand).unwrap().contains("#f0e8d8"), "Sand's picture");
        let sky = icon_for(&paths, &verso_core::product::VERSO, "sky").unwrap();
        assert!(PathBuf::from(&sky).is_file() && !PathBuf::from(&sand).exists(), "one copy, the chosen one's");
        assert_eq!(shown(&paths), "dev.hviid.Verso", "a notification shows Mist until Sky is chosen");
        write(&paths.config_file(), "[app]\nicon = \"sky\"\n");
        assert_eq!(shown(&paths), sky);
        assert_eq!(icon_for(&paths, &verso_core::product::VERSO, "mist").as_deref(), Some("dev.hviid.Verso"));
        assert!(!PathBuf::from(&sky).exists(), "Mist is the install's own, by its name");
    }

    #[test]
    fn every_design_offered_is_drawn() {
        let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packaging/icons");
        for design in verso_core::settings::APP_ICONS {
            let name = verso_core::product::VERSO.app_icon(design);
            let drawing = checkout.join(format!("{name}.svg"));
            assert!(drawing.is_file(), "{design}: {} is missing", drawing.display());
        }
    }
}
