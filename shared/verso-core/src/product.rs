//! Which Verso the shared code runs as: the tarball's, the rpm's and the deb's, which also tell of a newer release, or
//! the Flatpak's, whose sandbox leaves the drive out (ARCHITECTURE.md, "What Verso is"). Every name the service and the window share comes from here: the folders,
//! the keyring's items, the service's D-Bus name, user service and program, the tray, and Verso's own defaults.
//!
//! A program says which it is once, first thing in `main` ([`set`]); unset, it is the tarball's Verso. Immich Mount,
//! whose account Verso takes over, is described here too ([`IMMICH_MOUNT`]), so Verso can read its settings and
//! sign-in and never touch them; nothing runs as it.

use std::sync::OnceLock;

/// This build's version: the one its release was built as (`VERSO_VERSION`, from `ci/version.sh`, which
/// `linux/packaging/verso-tarball.sh` and the Flatpak's build set), else Cargo's, 0.0.0 for a build without one.
pub const VERSION: &str = match option_env!("VERSO_VERSION") {
    Some(version) if !version.is_empty() => version,
    _ => env!("CARGO_PKG_VERSION"),
};

/// A command of the product's program as its messages name it (`verso-service login`): the program that is running,
/// which is the one the person can run.
pub fn command(arguments: &str) -> String {
    format!("{} {arguments}", current().program)
}

/// What the product's program tells a server it is: its name and version (`verso-service/0.6.0`).
pub fn user_agent() -> String {
    format!("{}/{VERSION}", current().program)
}

#[derive(Debug, PartialEq, Eq)]
pub struct Product {
    /// The name people see: notifications, the tray, the thumbnails' `Software` tag.
    pub name: &'static str,
    /// The application id: the icon's name, the keyring items' `application`, the stem of the daemon's D-Bus name.
    pub id: &'static str,
    /// The folders' name under the XDG base directories, the tray item's id, and the user service's name.
    pub folder: &'static str,
    /// The program that runs the daemon and the command line.
    pub program: &'static str,
    /// The drive's icon: in a file manager, a dock, and on the mount point's folder. Verso's has a badge of its own, so
    /// the drive is not taken for the app.
    pub drive_icon: &'static str,
    /// The names the drive may take in a file manager's sidebar (`mount.name`'s choices), the first by default.
    pub drive_names: &'static [&'static str],
    /// Defaults that differ from the settings table's, which are Verso's, by key.
    pub defaults: &'static [(&'static str, &'static str)],
    /// Settings its windows leave out, and read as the product's own defaults: Verso's service starts at login while
    /// signed in, whether its drive is on or not, and only the rpm and the deb look for a newer release.
    pub hidden_settings: &'static [&'static str],
    /// Built for a Flatpak's sandbox (`VERSO_FLATPAK`): no drive, no systemd service, no announcements written at run
    /// time, no other app's account to take over (ARCHITECTURE.md, "Verso as a Flatpak").
    pub sandboxed: bool,
}

/// Immich Mount, the app Verso's drive comes from, as Verso reads it to take its account over: its folders, its keyring
/// items' `application` and its own defaults. Nothing runs as it.
pub const IMMICH_MOUNT: Product = Product {
    name: "Immich Mount",
    id: "dev.hviid.ImmichMount",
    folder: "immich-mount",
    program: "immich-mount",
    drive_icon: "dev.hviid.ImmichMount",
    drive_names: &["immich-mount", "immich-drive", "immich"],
    defaults: &[("mount.enabled", "true"), ("mount.path", "~/Immich"), ("mount.name", "immich-mount"), ("updates.check", "true")],
    hidden_settings: &[],
    sandboxed: false,
};

/// Verso, with the settings table's defaults: the drive is its to switch on (`mount.enabled`), and mounts at its own
/// place under its own name ("Verso", at `~/Verso`), apart from Immich Mount's.
pub const VERSO: Product = Product {
    name: "Verso",
    id: "dev.hviid.Verso",
    folder: "verso",
    program: "verso-service",
    drive_icon: "dev.hviid.Verso.Drive",
    drive_names: &["verso", "verso-drive", "immich"],
    defaults: &[],
    hidden_settings: &["mount.at_login", "updates.check"],
    sandboxed: false,
};

/// Verso from its own rpm or deb (`--features package` on both programs; ARCHITECTURE.md, "Updates on Linux"): the same
/// app, names and folders, which tells of a newer release, as nothing else updates a package downloaded from a release
/// page. The look is on until switched off in Preferences (`updates.check`). Homebrew's tarball and the Flatpak are
/// updated by their own channels, and keep it off and hidden.
pub const VERSO_PACKAGE: Product = Product {
    defaults: &[("updates.check", "true")],
    hidden_settings: &["mount.at_login"],
    ..VERSO
};

/// Verso's window, which the tray opens and the service's `app` command runs.
pub const WINDOW: &str = "verso";

/// Verso built as a Flatpak (`--features flatpak` on both programs): the same app, names and folders, with what a
/// sandbox cannot reach left out. The drive is off for good, its settings unread; the app icon is its own (Mist, and
/// Mist Night in the dark style), as a sandboxed app cannot change its launcher.
pub const VERSO_FLATPAK: Product = Product {
    hidden_settings: &["mount.enabled", "mount.at_login", "mount.path", "mount.name", "mount.unmount_button", "cache.limit", "thumbnails.sharp", "updates.check", "app.icon", "app.icon_dark"],
    sandboxed: true,
    ..VERSO
};

static CURRENT: OnceLock<&'static Product> = OnceLock::new();

/// The product a build of the programs is, by its features: `flatpak` (the Flatpak), `package` (the rpm and the deb),
/// else the tarball's Verso. Both programs ask this, so they agree.
pub fn built_for(flatpak: bool, package: bool) -> &'static Product {
    if flatpak {
        &VERSO_FLATPAK
    } else if package {
        &VERSO_PACKAGE
    } else {
        &VERSO
    }
}

/// Say which product this program is. Only the first call counts.
pub fn set(product: &'static Product) {
    let _ = CURRENT.set(product);
}

/// The product this program is: the tarball's Verso unless [`set`] said otherwise.
pub fn current() -> &'static Product {
    CURRENT.get().copied().unwrap_or(&VERSO)
}

impl Product {
    /// The user service that runs the daemon.
    pub fn service(&self) -> String {
        format!("{}.service", self.folder)
    }

    /// The daemon's well-known name on the session bus.
    pub fn bus_name(&self) -> String {
        format!("{}.Daemon", self.id)
    }

    /// The symbolic icon, for the tray.
    pub fn symbolic_icon(&self) -> String {
        format!("{}-symbolic", self.id)
    }

    /// The app icon of one of its looks (`app.icon`, `app.icon_dark`): the product's own for Mist's Day look in colour,
    /// else the look's beside it (`dev.hviid.Verso-sand`, `dev.hviid.Verso-mist-night`).
    pub fn app_icon(&self, look: &str) -> String {
        if look == crate::settings::DEFAULT_APP_ICON { self.id.to_owned() } else { format!("{}-{look}", self.id) }
    }

    /// Whether its windows show the setting `key`.
    pub fn shows(&self, key: &str) -> bool {
        !self.hidden_settings.contains(&key)
    }

    /// The product's own default for `key`, where it differs from the settings table's.
    pub fn default_for(&self, key: &str) -> Option<&'static str> {
        self.defaults.iter().find(|(overridden, _)| *overridden == key).map(|(_, value)| *value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_products_share_no_name() {
        assert_ne!(IMMICH_MOUNT.folder, VERSO.folder);
        assert_ne!(IMMICH_MOUNT.bus_name(), VERSO.bus_name());
        assert_ne!(IMMICH_MOUNT.service(), VERSO.service());
        assert_ne!(IMMICH_MOUNT.program, VERSO.program);
        assert_ne!(IMMICH_MOUNT.default_for("mount.path"), VERSO.default_for("mount.path"));
        assert_eq!((VERSO.service(), VERSO.bus_name().as_str()), ("verso.service".to_owned(), "dev.hviid.Verso.Daemon"));
        assert_eq!(VERSO.default_for("mount.enabled"), None, "the table's are Verso's");
        assert_eq!(IMMICH_MOUNT.default_for("mount.enabled"), Some("true"));
        assert_eq!((VERSO_FLATPAK.folder, VERSO_FLATPAK.bus_name()), (VERSO.folder, VERSO.bus_name()));
        assert!(VERSO_FLATPAK.sandboxed && !VERSO_FLATPAK.shows("mount.enabled") && VERSO.shows("mount.enabled"));
    }

    #[test]
    fn only_the_packages_look_for_a_newer_release() {
        assert_eq!((built_for(true, false), built_for(false, true), built_for(false, false)), (&VERSO_FLATPAK, &VERSO_PACKAGE, &VERSO));
        assert_eq!((VERSO_PACKAGE.folder, VERSO_PACKAGE.bus_name(), VERSO_PACKAGE.sandboxed), (VERSO.folder, VERSO.bus_name(), false));
        assert!(VERSO_PACKAGE.shows("updates.check") && !VERSO_PACKAGE.shows("mount.at_login"));
        assert_eq!(VERSO_PACKAGE.default_for("updates.check"), Some("true"));
        assert!(!VERSO.shows("updates.check") && !VERSO_FLATPAK.shows("updates.check"));
    }
}
