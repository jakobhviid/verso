//! How this Verso was installed, told as it starts from what each way of installing it leaves behind, so one build of
//! the programs serves the tarball, the rpm and the AppImage (ARCHITECTURE.md, "One build for Fedora's files"): the
//! product it then is (`verso_core::product`) decides the drive, the sandbox's limits and the look for a newer release.

use std::path::Path;

use verso_core::product::{self, Product};

/// What this process was installed as. Both programs ask it, so they agree.
pub fn product() -> &'static Product {
    let executable = std::env::current_exe().ok();
    product_for(&Signs {
        installed: std::env::var("VERSO_INSTALLED").ok(),
        flatpak: std::env::var_os("FLATPAK_ID").is_some() || Path::new("/.flatpak-info").exists(),
        appimage: std::env::var_os("APPIMAGE").is_some(),
        appimage_mount: std::env::var_os("APPDIR").map(Into::into),
        executable,
    })
}

/// What tells one way of installing from another.
#[derive(Debug, Default)]
pub struct Signs {
    /// `VERSO_INSTALLED`, said outright (`tarball`, `package`, `appimage`, `flatpak`), for a check of each.
    pub installed: Option<String>,
    /// In a Flatpak's sandbox: `FLATPAK_ID` set, or its `/.flatpak-info`.
    pub flatpak: bool,
    /// Started by an AppImage's runtime, which sets `APPIMAGE` to the file it runs.
    pub appimage: bool,
    /// Where that runtime mounted the AppImage (`APPDIR`), which its programs run from.
    pub appimage_mount: Option<std::path::PathBuf>,
    /// This program's own file.
    pub executable: Option<std::path::PathBuf>,
}

/// The product the signs make: a Flatpak's sandbox; an AppImage whose mount this program runs from (a program started
/// from a process an AppImage started inherits `APPIMAGE`, but runs from elsewhere); the rpm's and the deb's programs
/// in `/usr/bin` and `/usr/libexec`; else the tarball's Verso, which Homebrew installs.
pub fn product_for(signs: &Signs) -> &'static Product {
    match signs.installed.as_deref() {
        Some("tarball") => return &product::VERSO,
        Some("package") => return &product::VERSO_PACKAGE,
        Some("appimage") => return &product::VERSO_APPIMAGE,
        Some("flatpak") => return &product::VERSO_FLATPAK,
        _ => {}
    }
    if signs.flatpak {
        return &product::VERSO_FLATPAK;
    }
    let executable = signs.executable.as_deref();
    let from_mount = match (&signs.appimage_mount, executable) {
        (Some(mount), Some(executable)) => executable.starts_with(mount),
        (None, _) => true,
        (Some(_), None) => false,
    };
    if signs.appimage && from_mount {
        return &product::VERSO_APPIMAGE;
    }
    if executable.is_some_and(|executable| executable.starts_with("/usr/bin") || executable.starts_with("/usr/libexec")) {
        return &product::VERSO_PACKAGE;
    }
    &product::VERSO
}

#[cfg(test)]
mod tests {
    use super::*;

    fn running(executable: &str) -> Signs {
        Signs { executable: Some(executable.into()), ..Signs::default() }
    }

    #[test]
    fn each_way_of_installing_is_told_apart() {
        assert_eq!(product_for(&running("/home/linuxbrew/.linuxbrew/Cellar/verso/0.77.0/libexec/verso")), &product::VERSO);
        assert_eq!(product_for(&running("/home/someone/verso/verso-service")), &product::VERSO);
        assert_eq!(product_for(&running("/usr/libexec/verso")), &product::VERSO_PACKAGE);
        assert_eq!(product_for(&running("/usr/bin/verso-service")), &product::VERSO_PACKAGE);
        assert_eq!(product_for(&Signs { flatpak: true, ..running("/app/bin/verso") }), &product::VERSO_FLATPAK);
        let appimage = Signs {
            appimage: true,
            appimage_mount: Some("/tmp/.mount_versoAb12".into()),
            ..running("/tmp/.mount_versoAb12/usr/libexec/verso")
        };
        assert_eq!(product_for(&appimage), &product::VERSO_APPIMAGE);
    }

    #[test]
    fn a_program_that_inherits_an_appimages_signs_is_what_it_runs_as() {
        // The rpm's Verso, started from a terminal an AppImage's Verso opened, inherits APPIMAGE and APPDIR.
        let inherited = Signs { appimage: true, appimage_mount: Some("/tmp/.mount_versoAb12".into()), ..running("/usr/libexec/verso") };
        assert_eq!(product_for(&inherited), &product::VERSO_PACKAGE);
    }

    #[test]
    fn verso_installed_says_it_outright() {
        for (said, product) in [("tarball", &product::VERSO), ("package", &product::VERSO_PACKAGE),
                                ("appimage", &product::VERSO_APPIMAGE), ("flatpak", &product::VERSO_FLATPAK)] {
            let signs = Signs { installed: Some(said.into()), ..running("/usr/libexec/verso") };
            assert_eq!(product_for(&signs), product, "{said}");
        }
    }
}
