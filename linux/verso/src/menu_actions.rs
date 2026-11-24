//! The photo menu's actions beyond the selection bar's, as the Mac gallery's context menu has them: Show in All
//! Photos, Copy Immich Link, New Album with Selection, a public link, the date, turning and cropping, tags, and a ZIP.

use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use verso_desktop::{actions, text};
use verso_linux::i18n::tr;

use crate::grid::Grid;
use crate::pages::Kind;
use crate::window::Window;

/// Run one of this module's actions on the selection; whether `action` was one of them.
pub fn act(window: &Window, grid: &Grid, kind: &Kind, action: &str, ids: &[String]) -> bool {
    match action {
        "open" => grid.open_selected(),
        "show-in-library" => {
            if let Some(tile) = grid.selected_tiles().into_iter().next() {
                window.show_in_library(&tile);
            }
        }
        "copy-link" => window.copy_link(&ids[0], kind.within()),
        "new-album" => new_album(window, ids.to_vec()),
        "share-link" => crate::links_page::link_editor(window, crate::links_page::LinkTarget::Assets(ids.to_vec()), None),
        "add-to-link" => crate::links_page::add_to_link(window, ids.to_vec()),
        "date" => adjust_dates(window, grid, ids.to_vec()),
        "rotate-left" => rotate(window, grid, ids.to_vec(), -1),
        "rotate-right" => rotate(window, grid, ids.to_vec(), 1),
        "crop" => crop(window, &ids[0]),
        "add-tag" => tag(window, ids.to_vec(), true),
        "remove-tag" => tag(window, ids.to_vec(), false),
        "zip" => zip(window, ids.to_vec()),
        _ => return false,
    }
    true
}

/// The pictures of turned or cropped photos, read again once Immich has made them anew.
fn forget_pictures(window: &Window, ids: &[String]) {
    if let Some(session) = window.session() {
        for id in ids {
            session.textures.forget(id);
        }
        session.textures.cache().forget_pictures(ids);
    }
}

fn new_album(window: &Window, ids: Vec<String>) {
    let weak = window.downgrade();
    crate::dialogs::ask_text(window, tr("New Album with Selection"), tr("Name"), "", tr("Create"), move |name| {
        let Some(window) = weak.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, ids, shown) = (session.connection.client.clone(), ids.clone(), window.clone());
        crate::tasks::run(async move { actions::create_album(&client, name, ids).await }, move |outcome| match outcome {
            Ok(album) => {
                shown.toast(&tr("Made the album “{name}”").replace("{name}", &album.name));
                shown.refresh_albums();
            }
            Err(message) => shown.toast(&message),
        });
    });
}

/// Shift or set when the photos selected were taken, then read the grid again.
fn adjust_dates(window: &Window, grid: &Grid, ids: Vec<String>) {
    // The first photo the grid shows of them, for the dialog's preview.
    let first = grid.selected_tiles().into_iter().find(|tile| tile.id == ids[0]).map(|tile| tile.taken);
    let weak_grid = grid.downgrade();
    crate::edit::adjust_dates(window, ids, first, move || {
        // A new date may move photos to other months: read the grid again once Immich has written them.
        let weak_grid = weak_grid.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(2500), move || {
            if let Some(grid) = weak_grid.upgrade() {
                grid.reload();
            }
        });
    });
}

/// Turn the photos selected, one after another, then show them turned.
fn rotate(window: &Window, grid: &Grid, ids: Vec<String>, quarter_turns: i32) {
    let Some(session) = window.session() else { return };
    let (client, turning, shown, weak_grid) = (session.connection.client.clone(), ids.clone(), window.clone(), grid.downgrade());
    crate::tasks::run(
        async move {
            for id in turning {
                actions::rotate(&client, id, quarter_turns).await?;
            }
            Ok::<_, String>(())
        },
        move |outcome| {
            if let Err(message) = outcome {
                shown.toast(&message);
            }
            let (weak_window, weak_grid) = (shown.downgrade(), weak_grid.clone());
            glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
                let Some(window) = weak_window.upgrade() else { return };
                forget_pictures(&window, &ids);
                if let Some(grid) = weak_grid.upgrade() {
                    for id in &ids {
                        grid.turned(id, quarter_turns);
                    }
                }
            });
        },
    );
}

fn crop(window: &Window, id: &str) {
    let (weak, cropped) = (window.downgrade(), id.to_owned());
    crate::crop::crop_dialog(window, id, move || {
        let (weak, cropped) = (weak.clone(), cropped.clone());
        glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
            let Some(window) = weak.upgrade() else { return };
            forget_pictures(&window, std::slice::from_ref(&cropped));
            window.reload_grids();
        });
    });
}

/// Add a tag to the photos, or take one away, chosen from the account's tags.
fn tag(window: &Window, ids: Vec<String>, adding: bool) {
    let Some(session) = window.session() else { return };
    let (client, shown) = (session.connection.client.clone(), window.clone());
    crate::tasks::run(async move { client.tags().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let tags = match outcome {
            Ok(tags) => tags,
            Err(message) => return shown.toast(&message),
        };
        if tags.is_empty() {
            return shown.toast(tr("No tags yet: make one on the Tags page"));
        }
        let mut choices: Vec<(String, String)> = tags.iter().map(|tag| (tag.id.clone(), tag.value.clone())).collect();
        choices.sort_by_key(|(_, name)| name.to_lowercase());
        let weak = shown.downgrade();
        let title = if adding { tr("Add Tag") } else { tr("Remove Tag") };
        crate::dialogs::choose_item(&shown, title, tr("Search tags"), choices, move |tag_id, tag_name| {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, ids, shown) = (session.connection.client.clone(), ids.clone(), window.clone());
            let count = ids.len() as u64;
            crate::tasks::run(
                async move {
                    if adding { client.tag_assets(&tag_id, &ids).await } else { client.untag_assets(&tag_id, &ids).await }.map(|_| ()).map_err(|error| verso_desktop::errors::said(&error))
                },
                move |outcome| {
                    shown.toast(&match outcome {
                        Ok(()) if adding => tr("Tagged {items} “{tag}”").replace("{items}", &text::items(count)).replace("{tag}", &tag_name),
                        Ok(()) => tr("Took “{tag}” off {items}").replace("{items}", &text::items(count)).replace("{tag}", &tag_name),
                        Err(message) => message,
                    });
                },
            );
        });
    });
}

/// Download the originals as one ZIP file, saved where the user picks.
fn zip(window: &Window, ids: Vec<String>) {
    let Some(session) = window.session() else { return };
    let dialog = gtk::FileDialog::builder().title(tr("Download as ZIP")).accept_label(tr("Download")).initial_name("Immich.zip").build();
    let (client, shown) = (session.connection.client.clone(), Rc::new(window.clone()));
    dialog.save(Some(window), gio::Cancellable::NONE, move |chosen| {
        let Some(path) = chosen.ok().and_then(|file| file.path()) else { return };
        shown.toast(tr("Downloading…"));
        let (client, ids, shown) = (client.clone(), ids.clone(), shown.clone());
        crate::tasks::run(async move { client.download_archive(&ids, false, &path).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            shown.toast(&match outcome {
                Ok(bytes) => tr("Downloaded {size}").replace("{size}", &text::size(bytes)),
                Err(message) => message,
            });
        });
    });
}
