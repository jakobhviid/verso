//! The app icon chosen in Preferences on the desktop, a look for its light style (`app.icon`) and one for its dark style
//! (`app.icon_dark`) (ARCHITECTURE.md, "The app icon's designs on Linux"). The app grid, the dash and the window's
//! place in them show the icon Verso's launcher entry names (`dev.hviid.Verso.desktop`), so Verso names the look of the
//! desktop's style there: Mist's Day look by the name every install puts in the icon theme, another look by the path
//! of a copy in Verso's own data folder, made from the drawings the install carries among the app's own icons. The
//! service puts the entry right as it starts (after an upgrade replaced it, at every login) and whenever the desktop's
//! colour scheme changes, which it hears from the portal; the window as it starts, when its style changes and when the
//! choice changes.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use verso_core::product::{self, Product};
use verso_core::settings::{Config, DEFAULT_APP_ICON, DEFAULT_APP_ICON_DARK};

use crate::paths::Paths;

/// Whether the desktop's style is dark, as last named in the entry: the service hears it from the portal, the window
/// from libadwaita. A notification's picture is that style's look.
static DARK: AtomicBool = AtomicBool::new(false);

/// The first line of an entry Verso writes in the user's folder over a package's own, in `$XDG_DATA_DIRS`: written
/// again from the package's at each start, so it follows the package's changes, and removed while the look named is
/// Mist's Day look in colour, the package's own, or once the package's entry is gone. Its words stay as they are, as
/// they are how Verso knows the entry for its own.
const WRITTEN: &str = "# Written by Verso over the installed entry, for the app icon chosen in Preferences (app.icon).\n";

/// The folders the app's own icons are in: `icons` in the install's folder, as the tarball has them, or, run from a
/// checkout, beside the sources.
pub fn icon_folders() -> Vec<PathBuf> {
    let beside = crate::programs::install_folder().map(|folder| folder.join("icons"));
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packaging/icons");
    beside.into_iter().chain([checkout]).filter(|folder| folder.is_dir()).collect()
}

/// Say whether the desktop's style is dark, as the window sees it, for a notification's picture and the next change of
/// choice; [`apply`] says it too.
pub fn set_dark_style(dark_style: bool) {
    DARK.store(dark_style, Ordering::Relaxed);
}

/// Whether the desktop's style was dark, as last said.
pub fn dark_style() -> bool {
    DARK.load(Ordering::Relaxed)
}

/// The looks chosen, the light style's and the dark style's, as `config.toml` has them now; the defaults where it
/// cannot be read.
pub fn chosen(paths: &Paths) -> (&'static str, &'static str) {
    std::fs::read_to_string(paths.config_file())
        .ok()
        .and_then(|text| Config::from_toml(&text).ok())
        .map_or((DEFAULT_APP_ICON, DEFAULT_APP_ICON_DARK), |config| (config.app_icon, config.app_icon_dark))
}

/// The look of a style among the two chosen.
fn for_style((light, dark): (&'static str, &'static str), dark_style: bool) -> &'static str {
    if dark_style { dark } else { light }
}

/// Name the look chosen for the desktop's style in Verso's launcher entry: `app.icon`'s in the light style,
/// `app.icon_dark`'s in the dark, read from `config.toml` now, with a copy of each kept. Nothing in a Flatpak, which
/// offers no choice and cannot reach its entry.
pub fn apply(paths: &Paths, dark_style: bool) {
    set_dark_style(dark_style);
    let product = product::current();
    if product.sandboxed {
        return;
    }
    // The user's folder of entries beside Verso's data (`$XDG_DATA_HOME`), then the system's (`$XDG_DATA_DIRS`).
    let own = paths.data_directory.parent().unwrap_or(&paths.home).join("applications");
    let folders: Vec<PathBuf> = std::iter::once(own).chain(crate::crosslink_apps::application_folders().into_iter().skip(1)).collect();
    let look = for_style(chosen(paths), dark_style);
    match name_look(paths, &folders, product, dark_style) {
        Ok(true) => log::info!("Verso's launcher shows the app icon {look}"),
        Ok(false) => {}
        Err(error) => log::warn!("could not give Verso's launcher the app icon {look}: {error}"),
    }
}

/// [`apply`] with the entries' `folders`, the user's first: whether the entry changed.
fn name_look(paths: &Paths, folders: &[PathBuf], product: &Product, dark_style: bool) -> std::io::Result<bool> {
    let [light_icon, dark_icon] = icons_for(paths, product, chosen(paths));
    match if dark_style { dark_icon } else { light_icon } {
        Some(icon) => name_icon(folders, product.id, &icon),
        None => Ok(false),
    }
}

/// The icon that shows the chosen look outside the window, as an entry's `Icon` and a notification's picture take it:
/// that of the style last named (`apply`), the product's own name for Mist's Day look, else the path of Verso's copy,
/// or the product's own name while it has none.
pub fn shown(paths: &Paths) -> String {
    let product = product::current();
    let look = for_style(chosen(paths), DARK.load(Ordering::Relaxed));
    let copy = paths.data_directory.join("icons").join(format!("{}.svg", product.app_icon(look)));
    if look != DEFAULT_APP_ICON && copy.is_file() { copy.to_string_lossy().into_owned() } else { product.id.to_owned() }
}

/// What the entry's `Icon` says for each of `looks`, the light style's and the dark style's: the product's own name for
/// Mist's Day look; for another, the path of its drawing, copied into Verso's data folder (`icons/`), where any other
/// copy goes. None for a look the install has no drawing of, which leaves the entry as it is.
fn icons_for(paths: &Paths, product: &Product, looks: (&str, &str)) -> [Option<String>; 2] {
    let folder = paths.data_directory.join("icons");
    let kept = [looks.0, looks.1].map(|look| format!("{}.svg", product.app_icon(look)));
    if let Ok(listing) = std::fs::read_dir(&folder) {
        for entry in listing.flatten() {
            let other = entry.file_name().to_string_lossy().into_owned();
            if !kept.contains(&other) && other.starts_with(product.id) && other.ends_with(".svg") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    [looks.0, looks.1].map(|look| {
        let name = product.app_icon(look);
        if look == DEFAULT_APP_ICON {
            return Some(name);
        }
        let file_name = format!("{name}.svg");
        let Some(drawing) = icon_folders().into_iter().find_map(|icons| std::fs::read(icons.join(&file_name)).ok()) else {
            log::warn!("this install of Verso has no drawing of the app icon {look} ({file_name})");
            return None;
        };
        let copy = folder.join(&file_name);
        if let Err(error) = replace_if_changed(&copy, &drawing) {
            log::warn!("could not keep the app icon {look} in {}: {error}", folder.display());
            return None;
        }
        copy.to_str().map(str::to_owned)
    })
}

/// The portal's word for the desktop's style (`org.freedesktop.appearance`, `color-scheme`): 1 prefers dark; 0, no
/// preference, and 2, prefers light, are the light style, as libadwaita reads them.
const PREFERS_DARK: u32 = 1;
const PORTAL: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const SETTINGS: &str = "org.freedesktop.portal.Settings";
const APPEARANCE: &str = "org.freedesktop.appearance";
const COLOUR_SCHEME: &str = "color-scheme";

/// The number a setting's value carries, the portal's `ReadOne` giving it in a variant and the older `Read` in a
/// variant inside one.
fn scheme_number(value: &zbus::zvariant::Value<'_>) -> Option<u32> {
    match value {
        zbus::zvariant::Value::U32(number) => Some(*number),
        zbus::zvariant::Value::Value(inner) => scheme_number(inner),
        _ => None,
    }
}

/// Whether the desktop prefers the dark style, as its portal says; None where there is no portal to ask.
pub async fn prefers_dark(connection: &zbus::Connection) -> Option<bool> {
    let read = |method: &'static str| async move {
        let reply = connection.call_method(Some(PORTAL), PORTAL_PATH, Some(SETTINGS), method, &(APPEARANCE, COLOUR_SCHEME)).await.ok()?;
        let value: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
        scheme_number(&value)
    };
    let number = match read("ReadOne").await {
        Some(number) => Some(number),
        None => read("Read").await,
    }?;
    Some(number == PREFERS_DARK)
}

/// Whether the desktop prefers the dark style now, for a program without a runtime of its own (`configure`): asked of
/// the portal on a runtime made for it, a second at most; the light style where there is no answer.
pub fn prefers_dark_now() -> bool {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else { return false };
    runtime.block_on(async {
        let asked = async { prefers_dark(&zbus::Connection::session().await.ok()?).await };
        tokio::time::timeout(Duration::from_secs(1), asked).await.ok().flatten().unwrap_or(false)
    })
}

/// The service's watch on the desktop's style: name its look in the entry now, and again at each change of colour
/// scheme the portal announces, reading the choice again each time. Without a portal the light style's look is named
/// once.
pub async fn follow_style(paths: Paths) {
    use futures_util::StreamExt;
    let Ok(connection) = zbus::Connection::session().await else {
        apply(&paths, false);
        return;
    };
    let dark = prefers_dark(&connection).await;
    if dark.is_none() {
        log::debug!("no portal says the desktop's colour scheme; the app icon is the light style's");
    }
    apply(&paths, dark.unwrap_or(false));
    let built = async {
        zbus::proxy::Builder::<zbus::Proxy>::new(&connection)
            .destination(PORTAL)?
            .path(PORTAL_PATH)?
            .interface(SETTINGS)?
            .cache_properties(zbus::proxy::CacheProperties::No)
            .build()
            .await
    };
    let Ok(proxy) = built.await else { return };
    let Ok(mut changes) = proxy.receive_signal("SettingChanged").await else { return };
    while let Some(message) = changes.next().await {
        let Ok((namespace, key, value)) = message.body().deserialize::<(String, String, zbus::zvariant::OwnedValue)>() else { continue };
        if namespace != APPEARANCE || key != COLOUR_SCHEME {
            continue;
        }
        if let Some(number) = scheme_number(&value) {
            apply(&paths, number == PREFERS_DARK);
        }
    }
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

    fn paths_in(home: &Path) -> Paths {
        Paths {
            config_directory: home.join(".config/verso"),
            cache_directory: home.join(".cache/verso"),
            state_directory: home.join(".local/state/verso"),
            data_directory: home.join(".local/share/verso"),
            thumbnail_directory: home.join(".cache/thumbnails"),
            home: home.to_path_buf(),
        }
    }

    #[test]
    fn the_chosen_looks_are_copied_and_the_others_go() {
        use verso_core::product::VERSO;
        let root = tempfile::tempdir().unwrap();
        let paths = paths_in(root.path());
        let icons = paths.data_directory.join("icons");
        let [sand, night] = icons_for(&paths, &VERSO, ("sand", "mist-night"));
        let (sand, night) = (sand.expect("the checkout has Sand's drawing"), night.expect("and Mist Night's"));
        assert_eq!(PathBuf::from(&sand), icons.join("dev.hviid.Verso-sand.svg"));
        assert!(std::fs::read_to_string(&sand).unwrap().contains("#f0e8d8"), "Sand's picture");
        assert_eq!(PathBuf::from(&night), icons.join("dev.hviid.Verso-mist-night.svg"));
        let [sky, night_again] = icons_for(&paths, &VERSO, ("sky", "mist-night"));
        let sky = sky.unwrap();
        assert!(PathBuf::from(&sky).is_file() && !PathBuf::from(&sand).exists(), "the light style's copy, the chosen one's");
        assert_eq!(night_again.as_deref(), Some(night.as_str()));
        assert!(PathBuf::from(&night).is_file(), "the dark style's copy is kept beside it");
        // A notification's picture is the look of the style last named.
        DARK.store(false, Ordering::Relaxed);
        assert_eq!(shown(&paths), "dev.hviid.Verso", "Mist until Sky is chosen");
        write(&paths.config_file(), "[app]\nicon = \"sky\"\n");
        assert_eq!(shown(&paths), sky);
        DARK.store(true, Ordering::Relaxed);
        assert_eq!(shown(&paths), night, "in the dark style, Mist Night's copy");
        DARK.store(false, Ordering::Relaxed);
        let [mist, graphite] = icons_for(&paths, &VERSO, ("mist", "dark-night-graphite"));
        assert_eq!(mist.as_deref(), Some("dev.hviid.Verso"), "Mist is the install's own, by its name");
        assert!(PathBuf::from(graphite.unwrap()).is_file());
        assert!(!PathBuf::from(&sky).exists() && !PathBuf::from(&night).exists(), "no copy of a look no longer chosen");
    }

    #[test]
    fn the_entry_names_the_look_of_the_desktops_style() {
        use verso_core::product::VERSO;
        let root = tempfile::tempdir().unwrap();
        let paths = paths_in(root.path());
        let folders = folders(root.path());
        let own = folders[0].join("dev.hviid.Verso.desktop");
        write(&own, ENTRY);
        let icons = paths.data_directory.join("icons");
        // The defaults: Mist by its name in the light style, Mist Night's copy in the dark.
        assert!(!name_look(&paths, &folders, &VERSO, false).unwrap(), "the light style's Mist: the entry as installed");
        assert!(name_look(&paths, &folders, &VERSO, true).unwrap());
        let named = format!("\nIcon={}\n", icons.join("dev.hviid.Verso-mist-night.svg").display());
        assert!(std::fs::read_to_string(&own).unwrap().contains(&named));
        write(&paths.config_file(), "[app]\nicon = \"paper-graphite\"\nicon_dark = \"sky-night\"\n");
        assert!(name_look(&paths, &folders, &VERSO, true).unwrap());
        assert!(std::fs::read_to_string(&own).unwrap().contains(&format!("\nIcon={}\n", icons.join("dev.hviid.Verso-sky-night.svg").display())));
        assert!(name_look(&paths, &folders, &VERSO, false).unwrap());
        assert!(std::fs::read_to_string(&own).unwrap().contains(&format!("\nIcon={}\n", icons.join("dev.hviid.Verso-paper-graphite.svg").display())));
    }

    #[test]
    fn a_scheme_reads_from_either_portal_reply() {
        use zbus::zvariant::Value;
        assert_eq!(scheme_number(&Value::U32(1)), Some(PREFERS_DARK));
        assert_eq!(scheme_number(&Value::Value(Box::new(Value::U32(2)))), Some(2), "`Read`'s variant in a variant");
        assert_eq!(scheme_number(&Value::from("dark")), None);
    }

    #[test]
    fn every_look_offered_is_drawn() {
        let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packaging/icons");
        for look in verso_core::settings::APP_ICONS {
            let name = verso_core::product::VERSO.app_icon(look);
            let drawing = checkout.join(format!("{name}.svg"));
            assert!(drawing.is_file(), "{look}: {} is missing", drawing.display());
        }
    }
}
