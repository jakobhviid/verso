//! An album's page, as the Mac gallery has it: a header with its title and description (the owner edits them in
//! place), how many photos from when to when, and who it is shared with; the Album menu (edit, sharing, a public
//! link, a ZIP of it, the photos' order kept on the server, comments on or off, delete or leave); its photos in the
//! order the album keeps.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use chrono::Utc;
use immich_api::{Album, AlbumChanges, AlbumRole, AssetOrder, DownloadSource, TimelineOptions, TimelineScope};
use verso_desktop::library::Source;
use verso_desktop::{actions, text};
use verso_core::links::ImmichItem;
use verso_linux::i18n::tr;

use crate::collections::item_actions;
use crate::grid::{Grid, WeakGrid};
use crate::pages::{self, Kind, Spec};
use crate::sharing::{Audience, AudienceLook, SharePage};
use crate::window::Window;

/// What an album action does, with the album as read.
type AlbumAction = Box<dyn Fn(&Window, &Album, Option<&glib::Variant>)>;

/// The actions only an album's owner has, and the one only its members have.
const OWNER_ONLY: [&str; 6] = ["edit", "share-people", "sort-photos", "toggle-activity", "delete", "rename"];

pub fn album_page(window: &Window, id: &str, name: &str) -> adw::NavigationPage {
    let mut spec = Spec::new(if name.is_empty() { tr("Album") } else { name }, Source::Timeline(TimelineScope::Album(id.to_owned())), Kind::Album { id: id.to_owned() }).empty(tr("This Album Is Empty"), "folder-pictures-symbolic");
    let menu = gio::Menu::new();
    let editing = gio::Menu::new();
    editing.append(Some(tr("Add Photos…")), Some("page.add-photos"));
    editing.append(Some(tr("Edit Album…")), Some("page.edit"));
    editing.append(Some(tr("Share…")), Some("page.share"));
    editing.append(Some(tr("Download Album as ZIP…")), Some("page.zip"));
    menu.append_section(None, &editing);
    let order = gio::Menu::new();
    order.append(Some(tr("Oldest First")), Some("page.sort-photos::asc"));
    order.append(Some(tr("Newest First")), Some("page.sort-photos::desc"));
    let showing = gio::Menu::new();
    showing.append_submenu(Some(tr("Sort Photos")), &order);
    showing.append(Some(tr("Comments and Likes")), Some("page.toggle-activity"));
    showing.append(Some(tr("Show Comments…")), Some("page.activity"));
    menu.append_section(None, &showing);
    let links = gio::Menu::new();
    crate::crosslink::append(&links, "album", "page");
    menu.append_section(None, &links);
    let ending = gio::Menu::new();
    ending.append(Some(tr("Delete Album…")), Some("page.delete"));
    ending.append(Some(tr("Leave Album…")), Some("page.leave"));
    menu.append_section(None, &ending);
    spec.menu = Some(menu);
    spec.actions = item_actions(window, ImmichItem::Album(id.to_owned()));

    let album: Rc<RefCell<Option<Album>>> = Rc::default();
    let shown_grid: Rc<RefCell<Option<WeakGrid>>> = Rc::default();
    let header = Rc::new(AlbumHeader::new());
    spec.above = Some(header.root.clone().upcast());
    spec.buttons = vec![gtk::Button::builder().icon_name("verso-add-photos-symbolic").tooltip_text(tr("Add Photos…")).action_name("page.add-photos").build().upcast()];
    let empty_add = pages::add_photos_button();
    spec.empty_child = Some(empty_add.clone().upcast());
    // The album read again into the header, after a change in the Share dialog: its people and how far it reaches.
    let reread: Rc<dyn Fn()> = {
        let (weak_window, header, holder, id) = (window.downgrade(), header.clone(), album.clone(), id.to_owned());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let me = session.connection.user_id().map(str::to_owned);
            let (client, id, header, holder, weak_window) = (session.connection.client.clone(), id.clone(), header.clone(), holder.clone(), window.downgrade());
            crate::tasks::run(async move { client.album(&id).await.ok() }, move |read| {
                let (Some(read), Some(window)) = (read, weak_window.upgrade()) else { return };
                let owner = read.owner().map(|owner| owner.id.clone()) == me;
                header.fill(&window, &read, owner);
                holder.replace(Some(read));
            });
        })
    };
    let add = |name: &str, state: Option<glib::Variant>, run: AlbumAction| {
        let action = match &state {
            // An on/off item takes no parameter; a choice among values takes its value.
            Some(state) if state.type_() == glib::VariantTy::BOOLEAN => gio::SimpleAction::new_stateful(name, None, state),
            Some(state) => gio::SimpleAction::new_stateful(name, Some(state.type_()), state),
            None => gio::SimpleAction::new(name, None),
        };
        action.set_enabled(false);
        let (weak_window, album) = (window.downgrade(), album.clone());
        action.connect_activate(move |action, value| {
            let (Some(window), Some(album)) = (weak_window.upgrade(), album.borrow().clone()) else { return };
            if action.state().is_some() {
                if let Some(value) = value {
                    action.set_state(value);
                }
            }
            run(&window, &album, value);
        });
        action
    };
    let edit = add("edit", None, Box::new(|window, album, _| edit_album(window, album)));
    let rename = add("rename", None, Box::new(|window, album, _| edit_album(window, album)));
    // Share…: the Share dialog on Links; the + beside its people's pictures, on People.
    let changed = reread.clone();
    let share = add("share", None, Box::new(move |window, album, _| crate::sharing::share_album(window, &album.id, SharePage::Links, Some(changed.clone()))));
    // Add Photos…: chosen from the library, for its owner and those who may add.
    let (grid_holder, changed) = (shown_grid.clone(), reread.clone());
    let add_photos = add(
        "add-photos",
        None,
        Box::new(move |window, album, _| {
            let (album, weak_window, grid_holder, changed) = (album.clone(), window.downgrade(), grid_holder.clone(), changed.clone());
            crate::photo_picker::pick_photos(window, tr("Add Photos to the Album"), tr("Add"), move |ids| {
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, album, shown, grid_holder, changed) = (session.connection.client.clone(), album.clone(), window.clone(), grid_holder.clone(), changed.clone());
                let id = album.id.clone();
                crate::tasks::run(async move { actions::add_to_album(&client, id, ids).await }, move |outcome| match outcome {
                    Ok(0) => shown.toast(tr("Those photos are in the album already")),
                    Ok(added) => {
                        shown.toast(&tr("Added {items} to the album").replace("{items}", &text::items(added as u64)));
                        if let Some(grid) = grid_holder.borrow().as_ref().and_then(WeakGrid::upgrade) {
                            grid.set_source(album_source(&album));
                        }
                        changed();
                        shown.refresh_albums();
                    }
                    Err(message) => shown.toast(&message),
                });
            });
        }),
    );
    // The empty album's Add Photos shows only where adding is allowed, not greyed for those who may only look.
    add_photos.bind_property("enabled", &empty_add, "visible").sync_create().build();
    let changed = reread.clone();
    let share_people = add("share-people", None, Box::new(move |window, album, _| crate::sharing::share_album(window, &album.id, SharePage::People, Some(changed.clone()))));
    let zip = add("zip", None, Box::new(|window, album, _| download_album(window, album)));
    let grid_holder = shown_grid.clone();
    let sort = add(
        "sort-photos",
        Some("desc".to_variant()),
        Box::new(move |window, album, value| {
            let ascending = value.and_then(|value| value.get::<String>()).as_deref() == Some("asc");
            let Some(session) = window.session() else { return };
            let changes = AlbumChanges { order: Some(if ascending { AssetOrder::Asc } else { AssetOrder::Desc }), ..AlbumChanges::default() };
            let (client, id, shown, grid) = (session.connection.client.clone(), album.id.clone(), window.clone(), grid_holder.borrow().clone());
            crate::tasks::run(async move { client.update_album(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(album) => {
                    if let Some(grid) = grid.and_then(|grid| grid.upgrade()) {
                        grid.set_source(album_source(&album));
                    }
                }
                Err(message) => shown.toast(&message),
            });
        }),
    );
    let album_holder = album.clone();
    let toggle_activity = add(
        "toggle-activity",
        Some(false.to_variant()),
        Box::new(move |window, album, _| {
            let Some(session) = window.session() else { return };
            let changes = AlbumChanges { activity_enabled: Some(!album.activity_enabled), ..AlbumChanges::default() };
            let (client, id, shown, holder) = (session.connection.client.clone(), album.id.clone(), window.clone(), album_holder.clone());
            crate::tasks::run(async move { client.update_album(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(album) => {
                    shown.toast(if album.activity_enabled { tr("Comments and likes are on") } else { tr("Comments and likes are off") });
                    holder.replace(Some(album));
                }
                Err(message) => shown.toast(&message),
            });
        }),
    );
    let activity = add("activity", None, Box::new(|window, album, _| crate::activity::activity_dialog(window, &album.id, None)));
    let delete = add("delete", None, Box::new(|window, album, _| delete_album(window, album)));
    let leave = add("leave", None, Box::new(|window, album, _| leave_album(window, album)));
    let all = [add_photos, edit, rename, share, share_people, zip, sort, toggle_activity, activity, delete, leave];
    spec.actions.extend(all.iter().cloned());
    // The header read again on Refresh and after an import into the album, so its count and dates follow the photos.
    let reread_action = gio::SimpleAction::new("reread", None);
    let changed = reread.clone();
    reread_action.connect_activate(move |_, _| changed());
    spec.actions.push(reread_action);

    let (page, grid) = pages::grid_page(window, spec);
    page.set_tag(Some(&format!("album:{id}")));
    shown_grid.replace(grid.as_ref().map(Grid::downgrade));

    // The album read whole: the header, the order its photos keep, who may do what.
    let Some(session) = window.session() else { return page };
    let me = session.connection.user_id().map(str::to_owned);
    let (client, album_id, weak_page, weak_window) = (session.connection.client.clone(), id.to_owned(), page.downgrade(), window.downgrade());
    crate::tasks::run(async move { client.album(&album_id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let (Some(page), Some(window)) = (weak_page.upgrade(), weak_window.upgrade()) else { return };
        let read = match outcome {
            Ok(read) => read,
            Err(message) => return window.toast(&message),
        };
        page.set_title(&read.name);
        let owner = read.owner().map(|owner| owner.id.clone()) == me;
        let adds = owner || read.members.iter().any(|member| Some(&member.user.id) == me.as_ref() && member.role == AlbumRole::Editor);
        for action in &all {
            let name = action.name();
            let enabled = match name.as_str() {
                "leave" => !owner,
                "add-photos" => adds,
                "activity" => read.activity_enabled,
                name if OWNER_ONLY.contains(&name) => owner,
                _ => true,
            };
            action.set_enabled(enabled);
            match name.as_str() {
                "sort-photos" => action.set_state(&(if read.order == Some(AssetOrder::Asc) { "asc" } else { "desc" }).to_variant()),
                "toggle-activity" => action.set_state(&read.activity_enabled.to_variant()),
                _ => {}
            }
        }
        header.fill(&window, &read, owner);
        if read.order == Some(AssetOrder::Asc) {
            if let Some(grid) = shown_grid.borrow().as_ref().and_then(WeakGrid::upgrade) {
                grid.set_source(album_source(&read));
            }
        }
        album.replace(Some(read));
    });
    page
}

/// The album's photos in the order it keeps.
fn album_source(album: &Album) -> Source {
    let options = TimelineOptions { oldest_first: album.order == Some(AssetOrder::Asc), ..TimelineOptions::default() };
    if options == TimelineOptions::default() { Source::Timeline(TimelineScope::Album(album.id.clone())) } else { Source::Arranged(TimelineScope::Album(album.id.clone()), options) }
}

/// The header above an album's photos, across its width: its title, description and facts on the left; on the right,
/// whom it is shared with: the people (their pictures, their role on hover) and +, Share With People, for its owner;
/// under them how far it reaches, named beside its icon (Private, Shared with 2 people, Shared with a password, Shared
/// publicly), so the icons are known again on the cards, and the way into the Share dialog.
struct AlbumHeader {
    root: gtk::Box,
    title: gtk::EditableLabel,
    description: gtk::EditableLabel,
    facts: gtk::Label,
    members: gtk::Box,
    /// The album shown: its id, name and description, which an edit in place compares with and saves to.
    known: Rc<RefCell<(String, String, String)>>,
    /// Whether the edits in place are connected, once.
    edits: Cell<bool>,
}

impl AlbumHeader {
    fn new() -> AlbumHeader {
        let title = gtk::EditableLabel::builder().editable(false).css_classes(["title-1"]).build();
        let description = gtk::EditableLabel::builder().editable(false).build();
        let facts = gtk::Label::builder().xalign(0.0).css_classes(["dim-label"]).build();
        let members = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).valign(gtk::Align::Center).build();
        let words = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).hexpand(true).build();
        words.append(&title);
        words.append(&description);
        words.append(&facts);
        let root = gtk::Box::builder().spacing(18).margin_top(12).margin_bottom(6).margin_start(18).margin_end(18).build();
        root.append(&words);
        root.append(&members);
        AlbumHeader { root, title, description, facts, members, known: Rc::default(), edits: Cell::new(false) }
    }

    fn fill(&self, window: &Window, album: &Album, owner: bool) {
        self.title.set_text(&album.name);
        self.title.set_editable(owner);
        self.description.set_text(&album.description);
        self.description.set_editable(owner);
        self.description.set_visible(owner || !album.description.is_empty());
        if album.description.is_empty() && owner {
            self.description.set_text(tr("Add a description"));
            self.description.add_css_class("dim-label");
        }
        let mut facts = vec![text::items(album.asset_count)];
        match (album.start_date, album.end_date) {
            (Some(start), Some(end)) if start.date_naive() == end.date_naive() => facts.push(text::short_day(start.date_naive())),
            (Some(start), Some(end)) => facts.push(format!("{} – {}", text::short_day(start.date_naive()), text::short_day(end.date_naive()))),
            _ => {}
        }
        self.facts.set_label(&facts.join(" · "));
        while let Some(child) = self.members.first_child() {
            self.members.remove(&child);
        }
        let Some(session) = window.session() else { return };
        // The owner first, then the others, each with their picture and role.
        let people = gtk::Box::builder().spacing(6).halign(gtk::Align::End).build();
        let mut members: Vec<&immich_api::AlbumMember> = album.members.iter().collect();
        members.sort_by_key(|member| member.role != immich_api::AlbumRole::Owner);
        for member in members {
            let avatar = crate::avatars::avatar(&session.connection.client, &member.user, 32);
            let role = match member.role {
                immich_api::AlbumRole::Owner => tr("Owner"),
                immich_api::AlbumRole::Editor => tr("Can add photos"),
                _ => tr("Can view"),
            };
            avatar.set_tooltip_text(Some(&format!("{} · {role}", crate::avatars::name(&member.user))));
            people.append(&avatar);
        }
        if owner {
            let add = gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("Share With People…")).action_name("page.share-people").css_classes(["circular", "flat"]).build();
            people.append(&add);
        }
        if people.first_child().is_some() {
            self.members.append(&people);
        }
        // How far it reaches, always, private too: from its people at once, and from its links once read.
        let others = album.members.iter().filter(|member| member.role != AlbumRole::Owner).count();
        let reach = gtk::Button::builder().halign(gtk::Align::End).action_name("page.share").css_classes(["flat"]).build();
        show_reach(&reach, Audience::of_album(others, &[], Utc::now()), others);
        self.members.append(&reach);
        if album.has_shared_link {
            reach.set_visible(false);
            let (client, id, weak) = (session.connection.client.clone(), album.id.clone(), reach.downgrade());
            crate::tasks::run(async move { client.shared_links(Some(&id)).await.unwrap_or_default() }, move |links| {
                if let Some(reach) = weak.upgrade() {
                    show_reach(&reach, Audience::of_album(others, &links, Utc::now()), others);
                    reach.set_visible(true);
                }
            });
        }
        *self.known.borrow_mut() = (album.id.clone(), album.name.clone(), album.description.clone());
        if self.edits.replace(true) {
            return;
        }
        // Edits in place: Enter, or leaving the field, saves; Escape cancels. Connected once, comparing with and saving
        // to the album shown, so the header can be filled again.
        for (label, is_name) in [(&self.title, true), (&self.description, false)] {
            let (weak_window, known) = (window.downgrade(), self.known.clone());
            label.connect_editing_notify(move |label| {
                let (id, before) = {
                    let known = known.borrow();
                    (known.0.clone(), if is_name { known.1.clone() } else { known.2.clone() })
                };
                if label.is_editing() {
                    if !is_name && before.is_empty() {
                        label.set_text("");
                        label.remove_css_class("dim-label");
                    }
                    return;
                }
                let text = label.text().trim().to_owned();
                if text == before || (is_name && text.is_empty()) {
                    return;
                }
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let changes = if is_name { AlbumChanges { name: Some(text.clone()), ..AlbumChanges::default() } } else { AlbumChanges { description: Some(text.clone()), ..AlbumChanges::default() } };
                let (client, shown, known) = (session.connection.client.clone(), window.clone(), known.clone());
                crate::tasks::run(async move { client.update_album(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(_) => {
                        let mut known = known.borrow_mut();
                        if is_name {
                            known.1 = text;
                        } else {
                            known.2 = text;
                        }
                        shown.refresh_albums();
                    }
                    Err(message) => shown.toast(&message),
                });
            });
        }
    }
}

/// The header's way into the Share dialog: how far the album reaches, its icon and name, what it means on hover.
fn show_reach(button: &gtk::Button, reach: Audience, others: usize) {
    button.set_child(Some(&adw::ButtonContent::builder().icon_name(reach.icon()).label(reach.label(others)).build()));
    button.set_tooltip_text(Some(reach.meaning()));
}

/// Edit Album: its name and description in one dialog.
fn edit_album(window: &Window, album: &Album) {
    let name = adw::EntryRow::builder().title(tr("Name")).text(&album.name).build();
    let description = adw::EntryRow::builder().title(tr("Description")).text(&album.description).build();
    let group = adw::PreferencesGroup::new();
    group.add(&name);
    group.add(&description);
    let dialog = adw::AlertDialog::new(Some(tr("Edit Album")), None);
    dialog.set_extra_child(Some(&group));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("save", tr("Save"))]);
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("save"));
    let (weak_window, id) = (window.downgrade(), album.id.clone());
    dialog.connect_response(Some("save"), move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let new_name = name.text().trim().to_owned();
        if new_name.is_empty() {
            return;
        }
        let changes = AlbumChanges { name: Some(new_name.clone()), description: Some(description.text().trim().to_owned()), ..AlbumChanges::default() };
        let (client, id, shown) = (session.connection.client.clone(), id.clone(), window.clone());
        crate::tasks::run(async move { client.update_album(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(album) => {
                shown.toast(tr("Album changed"));
                shown.refresh_albums();
                shown.open_album_again(&album.id, &album.name);
            }
            Err(message) => shown.toast(&message),
        });
    });
    dialog.present(Some(window));
}

/// The album as ZIP files (Immich splits a big one), saved where the user picks.
fn download_album(window: &Window, album: &Album) {
    let Some(session) = window.session() else { return };
    let dialog = gtk::FileDialog::builder().title(tr("Download Album as ZIP")).accept_label(tr("Download")).initial_name(format!("{}.zip", album.name)).build();
    let (client, shown, id) = (session.connection.client.clone(), window.clone(), album.id.clone());
    dialog.save(Some(window), gio::Cancellable::NONE, move |chosen| {
        let Some(path) = chosen.ok().and_then(|file| file.path()) else { return };
        shown.toast(tr("Downloading…"));
        let (client, id, shown) = (client.clone(), id.clone(), shown.clone());
        crate::tasks::run(
            async move {
                let plan = client.download_plan(&DownloadSource::Album(id), None).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let mut total = 0;
                let several = plan.archives.len() > 1;
                for (index, archive) in plan.archives.iter().enumerate() {
                    let target = if several {
                        let stem = path.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
                        path.with_file_name(format!("{stem} {}.zip", index + 1))
                    } else {
                        path.clone()
                    };
                    total += client.download_archive(&archive.asset_ids, false, &target).await.map_err(|error| verso_desktop::errors::said(&error))?;
                }
                Ok::<_, String>(total)
            },
            move |outcome| {
                shown.toast(&match outcome {
                    Ok(bytes) => tr("Downloaded {size}").replace("{size}", &text::size(bytes)),
                    Err(message) => message,
                });
            },
        );
    });
}

fn delete_album(window: &Window, album: &Album) {
    let (weak_window, id) = (window.downgrade(), album.id.clone());
    crate::dialogs::confirm(window, tr("Delete the Album?"), tr("The album goes; its photos and videos stay in your library."), tr("Delete Album"), true, move || {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, id, shown) = (session.connection.client.clone(), id.clone(), window.clone());
        crate::tasks::run(async move { actions::delete_album(&client, id).await }, move |outcome| match outcome {
            Ok(()) => {
                shown.toast(tr("Album deleted"));
                shown.refresh_albums();
                shown.select_section("albums");
            }
            Err(message) => shown.toast(&message),
        });
    });
}

/// A member leaves an album shared with them.
fn leave_album(window: &Window, album: &Album) {
    let (weak_window, id) = (window.downgrade(), album.id.clone());
    crate::dialogs::confirm(window, tr("Leave the Album?"), tr("It is no longer shared with you; its owner keeps it."), tr("Leave Album"), true, move || {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let Some(me) = session.connection.user_id().map(str::to_owned) else { return };
        let (client, id, shown) = (session.connection.client.clone(), id.clone(), window.clone());
        crate::tasks::run(async move { client.remove_album_member(&id, &me).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(()) => {
                shown.toast(tr("You left the album"));
                shown.refresh_albums();
                shown.select_section("albums");
            }
            Err(message) => shown.toast(&message),
        });
    });
}
