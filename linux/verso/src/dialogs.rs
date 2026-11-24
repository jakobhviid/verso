//! The questions the gallery asks: confirming a change, a name, an album to add to, a PIN code.

use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use verso_linux::i18n::tr;

/// Ask before a change; `then` runs only on yes.
pub fn confirm(parent: &impl IsA<gtk::Widget>, heading: &str, body: &str, yes: &str, destructive: bool, then: impl Fn() + 'static) {
    let dialog = adw::AlertDialog::new(Some(heading), Some(body));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("yes", yes)]);
    dialog.set_response_appearance("yes", if destructive { adw::ResponseAppearance::Destructive } else { adw::ResponseAppearance::Suggested });
    dialog.set_default_response(Some(if destructive { "cancel" } else { "yes" }));
    dialog.set_close_response("cancel");
    dialog.connect_response(Some("yes"), move |_, _| then());
    dialog.present(Some(parent));
}

/// Ask for a line of text, such as a name. `then` gets it trimmed, and is not called for an empty one.
pub fn ask_text(parent: &impl IsA<gtk::Widget>, heading: &str, label: &str, initial: &str, yes: &str, then: impl Fn(String) + 'static) {
    ask_text_explained(parent, heading, None, label, initial, yes, then);
}

/// [`ask_text`] with a line saying what to write.
pub fn ask_text_explained(parent: &impl IsA<gtk::Widget>, heading: &str, body: Option<&str>, label: &str, initial: &str, yes: &str, then: impl Fn(String) + 'static) {
    let dialog = adw::AlertDialog::new(Some(heading), body);
    let entry = adw::EntryRow::builder().title(label).text(initial).activates_default(true).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
    list.append(&entry);
    dialog.set_extra_child(Some(&list));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("yes", yes)]);
    dialog.set_response_appearance("yes", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("yes"));
    dialog.set_close_response("cancel");
    let weak_entry = entry.downgrade();
    dialog.connect_response(Some("yes"), move |_, _| {
        if let Some(entry) = weak_entry.upgrade() {
            let text = entry.text().trim().to_owned();
            if !text.is_empty() {
                then(text);
            }
        }
    });
    dialog.present(Some(parent));
    entry.grab_focus();
}

/// Where photos go: an album already there, or a new one by name.
pub enum AlbumChoice {
    Existing { id: String, name: String },
    New(String),
}

/// Pick an album to add photos to, from `albums` (id and name, most recent first), with a search and New Album.
pub fn choose_album(parent: &impl IsA<gtk::Widget>, albums: Vec<(String, String)>, then: impl Fn(AlbumChoice) + 'static) {
    let then = Rc::new(then);
    let dialog = adw::Dialog::builder().title(tr("Add to Album")).content_width(380).content_height(520).build();
    let search = gtk::SearchEntry::builder().placeholder_text(tr("Search albums")).hexpand(true).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).valign(gtk::Align::Start).build();
    let new_row = adw::ButtonRow::builder().title(tr("New Album…")).start_icon_name("list-add-symbolic").build();
    list.append(&new_row);
    for (id, name) in &albums {
        let row = adw::ActionRow::builder().title(glib::markup_escape_text(name)).activatable(true).build();
        row.set_widget_name(id);
        list.append(&row);
    }
    // Names as they are, not as markup: a title reads back escaped ("Tom &amp; Jerry").
    let names: std::collections::HashMap<String, String> = albums.iter().cloned().collect();
    let query = search.clone();
    list.set_filter_func(move |row| {
        let wanted = query.text().to_lowercase();
        match row.downcast_ref::<adw::ActionRow>() {
            Some(row) => wanted.is_empty() || row.title().to_lowercase().contains(&wanted),
            None => true,
        }
    });
    let filtered = list.clone();
    search.connect_search_changed(move |_| filtered.invalidate_filter());
    let (weak_dialog, chosen) = (dialog.downgrade(), then.clone());
    list.connect_row_activated(move |_, row| {
        let Some(row) = row.downcast_ref::<adw::ActionRow>() else { return };
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
        let id = row.widget_name().to_string();
        let name = names.get(&id).cloned().unwrap_or_default();
        chosen(AlbumChoice::Existing { id, name });
    });
    let (weak_dialog, parent_widget) = (dialog.downgrade(), parent.clone().upcast::<gtk::Widget>());
    new_row.connect_activated(move |_| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
        let then = then.clone();
        ask_text(&parent_widget, tr("New Album"), tr("Name"), "", tr("Create"), move |name| then(AlbumChoice::New(name)));
    });
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
    content.append(&search);
    content.append(&gtk::ScrolledWindow::builder().child(&list).vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).build());
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&content));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(parent));
    search.grab_focus();
}

/// Pick one of `items` (id and name), with a search; `then` gets the id and name chosen.
pub fn choose_item(parent: &impl IsA<gtk::Widget>, title: &str, placeholder: &str, items: Vec<(String, String)>, then: impl Fn(String, String) + 'static) {
    choose_item_explained(parent, title, None, placeholder, items, then);
}

/// [`choose_item`], with a line on what choosing does.
pub fn choose_item_explained(parent: &impl IsA<gtk::Widget>, title: &str, body: Option<&str>, placeholder: &str, items: Vec<(String, String)>, then: impl Fn(String, String) + 'static) {
    let dialog = adw::Dialog::builder().title(title).content_width(380).content_height(520).build();
    let search = gtk::SearchEntry::builder().placeholder_text(placeholder).hexpand(true).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).valign(gtk::Align::Start).build();
    for (id, name) in &items {
        let row = adw::ActionRow::builder().title(glib::markup_escape_text(name)).activatable(true).build();
        row.set_widget_name(id);
        list.append(&row);
    }
    let names: std::collections::HashMap<String, String> = items.iter().cloned().collect();
    let query = search.clone();
    list.set_filter_func(move |row| {
        let wanted = query.text().to_lowercase();
        row.downcast_ref::<adw::ActionRow>().is_none_or(|row| wanted.is_empty() || row.title().to_lowercase().contains(&wanted))
    });
    let filtered = list.clone();
    search.connect_search_changed(move |_| filtered.invalidate_filter());
    let weak_dialog = dialog.downgrade();
    list.connect_row_activated(move |_, row| {
        let Some(row) = row.downcast_ref::<adw::ActionRow>() else { return };
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
        let id = row.widget_name().to_string();
        let name = names.get(&id).cloned().unwrap_or_default();
        then(id, name);
    });
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
    if let Some(body) = body {
        content.append(&gtk::Label::builder().label(body).wrap(true).xalign(0.0).css_classes(["dim-label"]).build());
    }
    content.append(&search);
    content.append(&gtk::ScrolledWindow::builder().child(&list).vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).build());
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&content));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(parent));
    search.grab_focus();
}

/// Ask for the Locked Folder's PIN code.
pub fn ask_pin(parent: &impl IsA<gtk::Widget>, then: impl Fn(String) + 'static) {
    let dialog = adw::AlertDialog::new(Some(tr("Unlock the Locked Folder")), Some(tr("Enter your PIN code.")));
    let entry = adw::PasswordEntryRow::builder().title(tr("PIN Code")).activates_default(true).input_purpose(gtk::InputPurpose::Pin).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
    list.append(&entry);
    dialog.set_extra_child(Some(&list));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("unlock", tr("Unlock"))]);
    dialog.set_response_appearance("unlock", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("unlock"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("unlock", false);
    let weak_dialog = dialog.downgrade();
    entry.connect_changed(move |entry| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.set_response_enabled("unlock", valid_pin(&entry.text()));
        }
    });
    let weak_entry = entry.downgrade();
    dialog.connect_response(Some("unlock"), move |_, _| {
        if let Some(entry) = weak_entry.upgrade() {
            then(entry.text().to_string());
        }
    });
    dialog.present(Some(parent));
    entry.grab_focus();
}

/// A PIN code as Immich takes one: six digits.
pub fn valid_pin(text: &str) -> bool {
    text.len() == 6 && text.chars().all(|character| character.is_ascii_digit())
}

/// Set Up Locked Folder: a new six-digit PIN code, typed twice.
pub fn ask_new_pin(parent: &impl IsA<gtk::Widget>, then: impl Fn(String) + 'static) {
    let dialog = adw::AlertDialog::new(Some(tr("Set Up Locked Folder")), Some(tr("Choose a six-digit PIN code. It unlocks the Locked Folder here and in Immich's other apps.")));
    let entry = adw::PasswordEntryRow::builder().title(tr("Six-Digit PIN")).input_purpose(gtk::InputPurpose::Pin).build();
    let confirmation = adw::PasswordEntryRow::builder().title(tr("Confirm PIN")).activates_default(true).input_purpose(gtk::InputPurpose::Pin).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
    list.append(&entry);
    list.append(&confirmation);
    dialog.set_extra_child(Some(&list));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("set", tr("Set PIN and Unlock"))]);
    dialog.set_response_appearance("set", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("set"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("set", false);
    let check = {
        let (weak_dialog, weak_entry, weak_confirmation) = (dialog.downgrade(), entry.downgrade(), confirmation.downgrade());
        move || {
            let (Some(dialog), Some(entry), Some(confirmation)) = (weak_dialog.upgrade(), weak_entry.upgrade(), weak_confirmation.upgrade()) else { return };
            dialog.set_response_enabled("set", valid_pin(&entry.text()) && entry.text() == confirmation.text());
        }
    };
    let checked = check.clone();
    entry.connect_changed(move |_| checked());
    confirmation.connect_changed(move |_| check());
    let weak_entry = entry.downgrade();
    dialog.connect_response(Some("set"), move |_, _| {
        if let Some(entry) = weak_entry.upgrade() {
            then(entry.text().to_string());
        }
    });
    dialog.present(Some(parent));
    entry.grab_focus();
}
