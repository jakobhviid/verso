//! Verso's own participants in Immich Crosslink (ARCHITECTURE.md, "Links on Linux, and the Files extension"): one per place it shows items in, Verso
//! Gallery (the window) and Verso Drive (the drive in Files), each a desktop entry of its own, kept out of the app grid
//! (`NoDisplay`), which Verso writes while it takes part that way and removes otherwise. Other apps then offer Show in
//! Verso Gallery and Show in Verso Drive, and the two send to each other as to any participant.

use std::path::{Path, PathBuf};

use verso_core::product::{self, VERSO};
use verso_core::settings::Config;

use crate::paths::Paths;

/// One of Verso's participants: its desktop entry, its name, and the program that receives its links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Participant {
    pub id: &'static str,
    pub name: &'static str,
    comment: &'static str,
    program: &'static str,
    /// What comes before the link on the command line.
    arguments: &'static str,
}

/// The gallery: a link opens the item in the window.
pub const GALLERY: Participant = Participant {
    id: "dev.hviid.Verso.Gallery.desktop",
    name: "Verso Gallery",
    comment: "Shows a photo, album, person or place from another app in Verso",
    program: "verso",
    arguments: "",
};

/// The drive: a link shows the item's file or folder in the file manager, through the service.
pub const DRIVE: Participant = Participant {
    id: "dev.hviid.Verso.Drive.desktop",
    name: "Verso Drive",
    comment: "Shows a photo, album, person or place from another app in Files, in Verso Drive",
    program: "verso-service",
    arguments: "app ",
};

/// Both, as the settings leave them out of the other apps' list (they are Verso's own switches there).
pub const ALL: [Participant; 2] = [GALLERY, DRIVE];

/// Whether `participant` is announced with these settings: Immich Crosslink on, its own switch on, and for the drive,
/// the drive on.
pub fn wanted(participant: &Participant, config: &Config) -> bool {
    config.crosslink_enabled
        && match participant.id {
            id if id == GALLERY.id => config.crosslink_gallery,
            _ => config.crosslink_drive && config.mount_enabled,
        }
}

/// The desktop entry announcing `participant`, receiving through `program`. The program is quoted only where it must
/// be (a space, a quote): GIO gives an `Exec` program back with its quotes, and senders that check it can start (as
/// Files' extensions do, with `g_app_info_get_executable`) then find nothing, and leave the participant out.
pub fn entry_text(participant: &Participant, program: &Path) -> String {
    let path = program.display().to_string();
    let reserved = |c: char| c.is_whitespace() || "\"'\\><~|&;$*?#()`".contains(c);
    let exec = if path.contains(reserved) { format!("\"{}\"", path.replace('\\', "\\\\").replace('"', "\\\"")) } else { path.clone() };
    let program = path;
    format!(
        "[Desktop Entry]\n\
         # Written by Verso while it takes part in Immich Crosslink as {name}; removed when it does not.\n\
         Type=Application\n\
         Name={name}\n\
         Comment={comment}\n\
         TryExec={program}\n\
         Exec={exec} {arguments}%u\n\
         Icon={icon}\n\
         NoDisplay=true\n\
         Terminal=false\n\
         MimeType={scheme};\n\
         X-Immich-Crosslink-Version={version}\n\
         X-Immich-Crosslink-Shows=asset;album;person;place;page;\n",
        name = participant.name,
        comment = participant.comment,
        arguments = participant.arguments,
        // Verso Drive with the drive's icon, so other apps' Show in tells the two apart.
        icon = if participant.id == DRIVE.id { VERSO.drive_icon } else { VERSO.id },
        scheme = crate::crosslink_apps::SCHEME_TYPE,
        version = crate::crosslink_apps::DRAFT,
    )
}

/// The user's applications folder, where desktop entries a user installs go.
fn applications(paths: &Paths) -> PathBuf {
    paths.data_directory.parent().unwrap_or(&paths.home).join("applications")
}

/// Write the entries these settings want and remove the others. The system reads the folder
/// again by itself; the MIME cache is brought up to date for tools that read only it.
pub fn sync(paths: &Paths, config: &Config) {
    // A Flatpak announces with the entry it exports, and cannot write to the user's applications folder.
    if verso_core::product::current().sandboxed {
        return;
    }
    let folder = applications(paths);
    let mut changed = false;
    let mut announced = Vec::new();
    for participant in ALL {
        let file = folder.join(participant.id);
        let wanted = wanted(&participant, config).then(|| crate::programs::find(participant.program)).flatten();
        match wanted {
            Some(program) => {
                announced.push(participant.id);
                let text = entry_text(&participant, &program);
                if std::fs::read_to_string(&file).ok().as_deref() != Some(text.as_str()) {
                    let _ = std::fs::create_dir_all(&folder);
                    match std::fs::write(&file, text) {
                        Ok(()) => changed = true,
                        Err(error) => log::warn!("could not announce {}: {error}", participant.name),
                    }
                }
            }
            None => changed |= std::fs::remove_file(&file).is_ok(),
        }
    }
    // GIO finds an app for a scheme through the folder's MIME cache: brought up to date when an entry changed, or when
    // the cache lacks one (it was made before, or without the tool, which some minimal systems do not have).
    let cache = std::fs::read_to_string(folder.join("mimeinfo.cache")).unwrap_or_default();
    if changed || announced.iter().any(|id| !cache.contains(id)) {
        log::info!("announced Verso's Immich Crosslink participants anew");
        if let Err(error) = std::process::Command::new("update-desktop-database").arg(&folder).output() {
            log::warn!("could not bring the applications' MIME cache up to date (update-desktop-database: {error})");
        }
    }
}

/// Take both entries away (signing out, an uninstall).
pub fn remove_all(paths: &Paths) {
    if product::current().sandboxed {
        return;
    }
    let folder = applications(paths);
    let removed = ALL.iter().filter(|participant| std::fs::remove_file(folder.join(participant.id)).is_ok()).count();
    if removed > 0 {
        let _ = std::process::Command::new("update-desktop-database").arg(&folder).output();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(text: &str) -> Config {
        Config::from_toml_for(text, &VERSO).unwrap()
    }

    #[test]
    fn each_place_is_announced_while_it_can_show() {
        let off = config("");
        assert!(wanted(&GALLERY, &off) && !wanted(&DRIVE, &off), "the drive is off until switched on");
        let on = config("[mount]\nenabled = true\n");
        assert!(wanted(&GALLERY, &on) && wanted(&DRIVE, &on));
        let no_gallery = config("[mount]\nenabled = true\n[crosslink]\ngallery = false\n");
        assert!(!wanted(&GALLERY, &no_gallery) && wanted(&DRIVE, &no_gallery));
        let none = config("[mount]\nenabled = true\n[crosslink]\nenabled = false\n");
        assert!(!wanted(&GALLERY, &none) && !wanted(&DRIVE, &none), "Immich Crosslink off: neither");
    }

    #[test]
    fn an_entry_announces_its_place_and_stays_out_of_the_app_grid() {
        let text = entry_text(&DRIVE, Path::new("/home/linuxbrew/.linuxbrew/bin/verso-service"));
        assert!(text.contains("Name=Verso Drive\n") && text.contains("NoDisplay=true\n"));
        assert!(text.contains("Exec=/home/linuxbrew/.linuxbrew/bin/verso-service app %u\n"), "unquoted, as GIO hands it on: {text}");
        assert!(text.contains("MimeType=x-scheme-handler/immich-crosslink;\n") && text.contains("X-Immich-Crosslink-Version=0.2\n"));
        let gallery = entry_text(&GALLERY, Path::new("/usr/bin/verso"));
        assert!(gallery.contains("Exec=/usr/bin/verso %u\n"));
        let spaced = entry_text(&GALLERY, Path::new("/opt/my apps/verso"));
        assert!(spaced.contains("Exec=\"/opt/my apps/verso\" %u\n"), "quoted where it must be: {spaced}");
        // What the finder of participants makes of it: a participant, by its name, showing every kind.
        let found = crate::crosslink_apps::read_entry(DRIVE.id, &text).expect("a participant");
        assert_eq!((found.name.as_str(), found.shows.len()), ("Verso Drive", 5));
    }
}
