//! The account in Preferences, as the Mac gallery's Settings: the profile (picture and name) and storage used, Change
//! Password, and a Features page with the account's preferences in Immich (`account_preferences`), each saved as it
//! changes.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::AccountChanges;
use verso_desktop::account_preferences::{self, Control, GIBIBYTE};
use verso_desktop::text;
use verso_linux::i18n::tr;
use serde_json::Value;

use crate::window::Window;

/// The profile: the picture (Choose Picture, Remove), the name, and the storage used.
pub fn profile_group(window: &Window) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(tr("Profile")).build();
    let Some(session) = window.session() else { return group };
    let Some(account) = session.connection.account.clone() else { return group };
    let avatar = adw::Avatar::new(64, Some(&account.name), true);
    let choose = gtk::Button::builder().label(tr("Choose Picture…")).valign(gtk::Align::Center).build();
    let remove = gtk::Button::builder().label(tr("Remove")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    let picture_row = adw::ActionRow::builder().title(tr("Picture")).build();
    picture_row.add_prefix(&avatar);
    picture_row.add_suffix(&choose);
    picture_row.add_suffix(&remove);
    group.add(&picture_row);
    let name = adw::EntryRow::builder().title(tr("Name")).text(&account.name).show_apply_button(true).build();
    group.add(&name);
    let storage = adw::ActionRow::builder().title(tr("Storage")).css_classes(["property"]).build();
    group.add(&storage);
    // The picture and the storage, read now.
    let client = session.connection.client.clone();
    let (user_id, weak_avatar, weak_storage, weak_remove) = (account.id.clone(), avatar.downgrade(), storage.downgrade(), remove.downgrade());
    crate::tasks::run(
        async move {
            let me = client.me().await.ok();
            let picture = client.profile_image(&user_id).await.ok().map(|media| media.bytes.to_vec());
            (me, picture)
        },
        move |(me, picture)| {
            if let (Some(avatar), Some(bytes)) = (weak_avatar.upgrade(), picture.as_ref()) {
                if let Ok(texture) = gdk::Texture::from_bytes(&glib::Bytes::from(bytes)) {
                    avatar.set_custom_image(Some(&texture));
                }
            }
            if let Some(remove) = weak_remove.upgrade() {
                remove.set_visible(picture.is_some());
            }
            if let (Some(storage), Some(me)) = (weak_storage.upgrade(), me) {
                let used = me.quota_usage_in_bytes.map(text::size);
                let subtitle = match (used, me.quota_size_in_bytes.filter(|quota| *quota > 0)) {
                    (Some(used), Some(quota)) => tr("{used} of {quota}").replace("{used}", &used).replace("{quota}", &text::size(quota)),
                    (Some(used), None) => tr("{used} used").replace("{used}", &used),
                    (None, _) => tr("Not known").to_owned(),
                };
                storage.set_subtitle(&subtitle);
            }
        },
    );
    let weak_window = window.downgrade();
    name.connect_apply(move |row| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let chosen = row.text().trim().to_owned();
        if chosen.is_empty() {
            return;
        }
        let changes = AccountChanges { name: Some(chosen), ..AccountChanges::default() };
        let (client, shown) = (session.connection.client.clone(), window.clone());
        crate::tasks::run(async move { client.update_me(&changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(_) => {
                shown.toast(tr("Name saved"));
                shown.fill_account_footer();
            }
            Err(message) => shown.toast(&message),
        });
    });
    let (weak_window, weak_avatar, weak_remove) = (window.downgrade(), avatar.downgrade(), remove.downgrade());
    choose.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(tr("Pictures")));
        filter.add_mime_type("image/jpeg");
        filter.add_mime_type("image/png");
        filter.add_mime_type("image/webp");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder().title(tr("Choose a Profile Picture")).filters(&filters).build();
        let (weak_window, weak_avatar, weak_remove) = (window.downgrade(), weak_avatar.clone(), weak_remove.clone());
        dialog.open(Some(&window), gio::Cancellable::NONE, move |chosen| {
            let Some(path) = chosen.ok().and_then(|file| file.path()) else { return };
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| "picture".to_owned());
            let mime = match path.extension().map(|extension| extension.to_string_lossy().to_lowercase()).as_deref() {
                Some("png") => "image/png",
                Some("webp") => "image/webp",
                _ => "image/jpeg",
            };
            let (client, shown, weak_avatar, weak_remove) = (session.connection.client.clone(), window.clone(), weak_avatar.clone(), weak_remove.clone());
            crate::tasks::run(
                async move {
                    let bytes = tokio::fs::read(&path).await.map_err(|error| error.to_string())?;
                    client.set_profile_image(bytes.clone().into(), &name, mime).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    Ok::<_, String>(bytes)
                },
                move |outcome| match outcome {
                    Ok(bytes) => {
                        if let (Some(avatar), Ok(texture)) = (weak_avatar.upgrade(), gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes))) {
                            avatar.set_custom_image(Some(&texture));
                        }
                        if let Some(remove) = weak_remove.upgrade() {
                            remove.set_visible(true);
                        }
                        shown.toast(tr("Picture changed"));
                        shown.fill_account_footer();
                    }
                    Err(message) => shown.toast(&message),
                },
            );
        });
    });
    let (weak_window, weak_avatar) = (window.downgrade(), avatar.downgrade());
    remove.connect_clicked(move |button| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, shown, weak_avatar, weak_button) = (session.connection.client.clone(), window.clone(), weak_avatar.clone(), button.downgrade());
        crate::tasks::run(async move { client.delete_profile_image().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(()) => {
                if let Some(avatar) = weak_avatar.upgrade() {
                    avatar.set_custom_image(gdk::Paintable::NONE);
                }
                if let Some(button) = weak_button.upgrade() {
                    button.set_visible(false);
                }
                shown.fill_account_footer();
            }
            Err(message) => shown.toast(&message),
        });
    });
    group
}

/// Change Password, for an account that has one (single sign-on alone has none).
pub fn password_group(window: &Window) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(tr("Password")).visible(false).build();
    let change = adw::ButtonRow::builder().title(tr("Change Password…")).build();
    group.add(&change);
    let Some(session) = window.session() else { return group };
    let (client, weak_group) = (session.connection.client.clone(), group.downgrade());
    crate::tasks::run(async move { client.auth_status().await.map(|status| status.password).unwrap_or(false) }, move |has_password| {
        if let Some(group) = weak_group.upgrade() {
            group.set_visible(has_password);
        }
    });
    let weak_window = window.downgrade();
    change.connect_activated(move |_| {
        if let Some(window) = weak_window.upgrade() {
            change_password(&window);
        }
    });
    group
}

fn change_password(window: &Window) {
    let current = adw::PasswordEntryRow::builder().title(tr("Current Password")).build();
    let new = adw::PasswordEntryRow::builder().title(tr("New Password")).build();
    let confirm = adw::PasswordEntryRow::builder().title(tr("Confirm New Password")).activates_default(true).build();
    let others = adw::SwitchRow::builder().title(tr("Sign Out Other Devices")).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
    for row in [current.upcast_ref::<gtk::Widget>(), new.upcast_ref(), confirm.upcast_ref(), others.upcast_ref()] {
        list.append(row);
    }
    let dialog = adw::AlertDialog::new(Some(tr("Change Password")), Some(tr("Use at least 8 characters.")));
    dialog.set_extra_child(Some(&list));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("change", tr("Change Password"))]);
    dialog.set_response_appearance("change", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("change"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("change", false);
    let check = {
        let (weak_dialog, current, new, confirm) = (dialog.downgrade(), current.downgrade(), new.downgrade(), confirm.downgrade());
        move || {
            let (Some(dialog), Some(current), Some(new), Some(confirm)) = (weak_dialog.upgrade(), current.upgrade(), new.upgrade(), confirm.upgrade()) else { return };
            dialog.set_response_enabled("change", !current.text().is_empty() && new.text().chars().count() >= 8 && new.text() == confirm.text());
        }
    };
    for row in [&current, &new, &confirm] {
        let check = check.clone();
        row.connect_changed(move |_| check());
    }
    let weak_window = window.downgrade();
    dialog.connect_response(Some("change"), move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (old, chosen, sign_out) = (current.text().to_string(), new.text().to_string(), others.is_active());
        let (client, shown) = (session.connection.client.clone(), window.clone());
        crate::tasks::run(async move { client.change_password(&old, &chosen, sign_out).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(_) => shown.toast(tr("Password changed")),
            Err(message) => shown.toast(&message),
        });
    });
    dialog.present(Some(window));
}

/// Features: the account's preferences in Immich, saved as each changes.
pub fn features_page(window: &Window) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder().title(tr("Features")).icon_name("application-x-addon-symbolic").name("features").build();
    let note = adw::PreferencesGroup::builder().description(tr("Your account's settings in Immich, for every app that uses it.")).build();
    page.add(&note);
    let Some(session) = window.session() else { return page };
    let client = session.connection.client.clone();
    let (weak_window, weak_page) = (window.downgrade(), page.downgrade());
    crate::tasks::run(async move { client.preferences().await.map(|preferences| preferences.raw).map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let (Some(window), Some(page)) = (weak_window.upgrade(), weak_page.upgrade()) else { return };
        let raw = match outcome {
            Ok(raw) => raw,
            Err(message) => return window.toast(&message),
        };
        for (group, rows) in account_preferences::shown(&raw) {
            let shown = adw::PreferencesGroup::builder().title(tr(group.title)).build();
            for row in rows {
                if let Some(widget) = preference_row(&window, row, account_preferences::value(&raw, row.path)) {
                    shown.add(&widget);
                }
            }
            page.add(&shown);
        }
    });
    page
}

/// Save one preference, a moment after its last change, so a spin sends its final number only.
fn save_later(window: &Window, path: &'static [&'static str], value: Value, pending: &Rc<RefCell<Option<glib::SourceId>>>) {
    if let Some(waiting) = pending.borrow_mut().take() {
        waiting.remove();
    }
    let (weak_window, holder) = (window.downgrade(), pending.clone());
    let id = glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
        holder.replace(None);
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, shown, patch) = (session.connection.client.clone(), window.clone(), account_preferences::patch(path, value));
        crate::tasks::run(async move { client.update_preferences(&patch).await.map(|_| ()).map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            if let Err(message) = outcome {
                shown.toast(&tr("The setting could not be saved: {error}").replace("{error}", &message));
            }
        });
    });
    pending.replace(Some(id));
}

fn preference_row(window: &Window, row: &'static account_preferences::Row, value: Option<&Value>) -> Option<gtk::Widget> {
    let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::default();
    let weak_window = window.downgrade();
    let widget: gtk::Widget = match row.control {
        Control::Switch => {
            let switch = adw::SwitchRow::builder().title(tr(row.title)).active(value?.as_bool()?).build();
            switch.connect_active_notify(move |switch| {
                if let Some(window) = weak_window.upgrade() {
                    save_later(&window, row.path, Value::Bool(switch.is_active()), &pending);
                }
            });
            switch.upcast()
        }
        Control::Number { min, max } => {
            let current = value?.as_u64()? as f64;
            let spin = adw::SpinRow::with_range(f64::from(min), f64::from(max), 1.0);
            spin.set_title(tr(row.title));
            spin.set_value(current);
            spin.connect_value_notify(move |spin| {
                if let Some(window) = weak_window.upgrade() {
                    save_later(&window, row.path, Value::from(spin.value() as u64), &pending);
                }
            });
            spin.upcast()
        }
        Control::GibiBytes => {
            let current = value?.as_u64()? as f64 / GIBIBYTE as f64;
            let spin = adw::SpinRow::with_range(1.0, 1024.0, 1.0);
            spin.set_title(tr(row.title));
            spin.set_value(current.round());
            spin.connect_value_notify(move |spin| {
                if let Some(window) = weak_window.upgrade() {
                    save_later(&window, row.path, Value::from(spin.value() as u64 * GIBIBYTE), &pending);
                }
            });
            spin.upcast()
        }
        Control::Choice(choices) => {
            let current = value?.as_str()?;
            let labels: Vec<&str> = choices.iter().map(|(_, label)| tr(label)).collect();
            let combo = adw::ComboRow::builder().title(tr(row.title)).model(&gtk::StringList::new(&labels)).build();
            combo.set_selected(choices.iter().position(|(code, _)| *code == current).unwrap_or(0) as u32);
            combo.connect_selected_notify(move |combo| {
                let Some((code, _)) = choices.get(combo.selected() as usize) else { return };
                if let Some(window) = weak_window.upgrade() {
                    save_later(&window, row.path, Value::from(*code), &pending);
                }
            });
            combo.upcast()
        }
    };
    Some(widget)
}
