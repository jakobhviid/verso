//! Tags, Partners and Duplicates, as the Mac gallery has them. Tags: a tree in each tag's colour, with New, Edit and
//! Delete. Partners: who shares with you (each a page of their photos, shown in your timeline or not) and whom you
//! share with, Add Partner and Remove. Duplicates: which photos of each group to keep, Immich's suggestion first;
//! keep those and trash the others, or dismiss the group; sorted as the View Options say.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::duplicate::{DuplicateGroup, DuplicateResolution};
use immich_api::partner::PartnerDirection;
use immich_api::{Tag, TagChanges, TimelineScope};
use verso_core::duplicates::{self, SortBy};
use verso_core::grid_options::GridPage;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Source;
use verso_desktop::{settings, tags, text};
use verso_linux::i18n::tr;

use crate::collections::card;
use crate::pages::{self, Kind, Spec};
use crate::window::Window;

/// A page of preferences groups that reload: a header, the groups, an empty state and a spinner.
pub(crate) struct RowsPage {
    pub page: adw::NavigationPage,
    pub header: adw::HeaderBar,
    pub content: adw::PreferencesPage,
    pub stack: gtk::Stack,
    pub empty: adw::StatusPage,
    groups: RefCell<Vec<adw::PreferencesGroup>>,
}

impl RowsPage {
    pub fn new(title: &str, empty_title: &str, icon: &str) -> Rc<RowsPage> {
        let header = adw::HeaderBar::new();
        let content = adw::PreferencesPage::new();
        let empty = adw::StatusPage::builder().title(empty_title).icon_name(icon).build();
        let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
        let stack = gtk::Stack::new();
        stack.add_named(&spinner, Some("loading"));
        stack.add_named(&content, Some("rows"));
        stack.add_named(&empty, Some("empty"));
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&stack));
        let page = adw::NavigationPage::builder().title(title).child(&toolbar).build();
        Rc::new(RowsPage { page, header, content, stack, empty, groups: RefCell::default() })
    }

    pub fn clear(&self) {
        for group in self.groups.borrow_mut().drain(..) {
            self.content.remove(&group);
        }
    }

    pub fn add(&self, group: &adw::PreferencesGroup) {
        self.content.add(group);
        self.groups.borrow_mut().push(group.clone());
    }

    pub fn remove(&self, group: &adw::PreferencesGroup) {
        self.groups.borrow_mut().retain(|known| known != group);
        self.content.remove(group);
    }

    pub fn show(&self, name: &str) {
        self.stack.set_visible_child_name(name);
    }
}

/// A row's menu button, which a right-click on the row opens too. The menu is made when first opened: a page of
/// thousands of tags would otherwise make thousands of menus, and GTK roots each one's actions slowly.
pub(crate) fn row_menu(row: &adw::ActionRow, menu: &gio::Menu) -> gtk::MenuButton {
    let button = gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(tr("More")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    let model = menu.clone();
    button.set_create_popup_func(move |button| button.set_menu_model(Some(&model)));
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    let opened = button.downgrade();
    click.connect_pressed(move |_, _, _, _| {
        if let Some(button) = opened.upgrade() {
            button.popup();
        }
    });
    row.add_controller(click);
    row.add_suffix(&button);
    button
}

pub(crate) fn string_action(name: &str, run: impl Fn(String) + 'static) -> gio::SimpleAction {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
    action.connect_activate(move |_, value| {
        if let Some(value) = value.and_then(|value| value.get::<String>()) {
            run(value);
        }
    });
    action
}

// --- Tags ---

pub fn tags_page(window: &Window) -> adw::NavigationPage {
    let rows = RowsPage::new(tr("Tags"), tr("No Tags"), "bookmark-new-symbolic");
    rows.empty.set_description(Some(tr("Tags label photos across albums. Make one with New Tag, or from a photo's menu.")));
    rows.header.pack_start(&gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("New Tag")).action_name("tags.new").build());
    let known: Rc<RefCell<Vec<Tag>>> = Rc::default();
    let load: Rc<dyn Fn()> = {
        let (weak_window, rows, known) = (window.downgrade(), rows.clone(), known.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, rows, known, weak_window) = (session.connection.client.clone(), rows.clone(), known.clone(), window.downgrade());
            crate::tasks::run(async move { client.tags().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let Some(window) = weak_window.upgrade() else { return };
                let found = match outcome {
                    Ok(found) => found,
                    Err(message) => {
                        rows.show("empty");
                        return window.toast(&message);
                    }
                };
                rows.clear();
                rows.show(if found.is_empty() { "empty" } else { "rows" });
                let group = adw::PreferencesGroup::new();
                for (tag, depth) in tags::tree(&found) {
                    group.add(&tag_row(&window, tag, depth));
                }
                rows.add(&group);
                known.replace(found);
            });
        })
    };
    let actions = gio::SimpleActionGroup::new();
    let ask: Rc<dyn Fn(String)> = {
        let (weak_window, again) = (window.downgrade(), load.clone());
        Rc::new(move |initial: String| {
            let Some(window) = weak_window.upgrade() else { return };
            let (weak, again) = (window.downgrade(), again.clone());
            crate::dialogs::ask_text_explained(&window, tr("New Tag"), Some(tr("To put it inside another tag, write its path: Parent/Child.")), tr("Name"), &initial, tr("Create"), move |path| {
                let path = path.trim().trim_matches('/').to_owned();
                let Some(window) = weak.upgrade().filter(|_| !path.is_empty()) else { return };
                let Some(session) = window.session() else { return };
                let (client, shown, again) = (session.connection.client.clone(), window.clone(), again.clone());
                crate::tasks::run(async move { client.upsert_tags(&[path]).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(_) => again(),
                    Err(message) => shown.toast(&message),
                });
            });
        })
    };
    let new = gio::SimpleAction::new("new", None);
    let run = ask.clone();
    new.connect_activate(move |_, _| run(String::new()));
    actions.add_action(&new);
    let tags_known = known.clone();
    actions.add_action(&string_action("new-inside", move |id| {
        let parent = tags_known.borrow().iter().find(|tag| tag.id == id).map(|tag| tag.value.clone());
        if let Some(parent) = parent {
            ask(format!("{parent}/"));
        }
    }));
    let (weak_window, tags_known, again) = (window.downgrade(), known.clone(), load.clone());
    actions.add_action(&string_action("edit", move |id| {
        let tag = tags_known.borrow().iter().find(|tag| tag.id == id).cloned();
        if let (Some(window), Some(tag)) = (weak_window.upgrade(), tag) {
            edit_tag(&window, &tag, again.clone());
        }
    }));
    let (weak_window, tags_known, again) = (window.downgrade(), known.clone(), load.clone());
    actions.add_action(&string_action("delete", move |id| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(tag) = tags_known.borrow().iter().find(|tag| tag.id == id).cloned() else { return };
        let (weak, again) = (window.downgrade(), again.clone());
        let heading = tr("Delete “{tag}” and the Tags Inside It?").replace("{tag}", &tag.value);
        crate::dialogs::confirm(&window, &heading, tr("The photos stay; only the tag leaves them."), tr("Delete Tag"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, again) = (session.connection.client.clone(), tag.id.clone(), window.clone(), again.clone());
            crate::tasks::run(async move { client.delete_tag(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => again(),
                Err(message) => shown.toast(&message),
            });
        });
    }));
    rows.page.insert_action_group("tags", Some(&actions));
    load();
    rows.page.clone()
}

fn tag_row(window: &Window, tag: &Tag, depth: usize) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(glib::markup_escape_text(&tag.name)).activatable(true).build();
    // Deeper tags step in, as the Mac gallery's outline does; a row puts each prefix before the last.
    row.add_prefix(&color_dot(tag.color.as_deref().and_then(tags::color)));
    if depth > 0 {
        row.add_prefix(&gtk::Box::builder().width_request(depth as i32 * 20).build());
    }
    let menu = gio::Menu::new();
    menu.append(Some(tr("New Tag Inside…")), Some(&format!("tags.new-inside::{}", tag.id)));
    menu.append(Some(tr("Edit Tag…")), Some(&format!("tags.edit::{}", tag.id)));
    menu.append(Some(tr("Delete Tag…")), Some(&format!("tags.delete::{}", tag.id)));
    row_menu(&row, &menu);
    row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    let (weak_window, id, value) = (window.downgrade(), tag.id.clone(), tag.value.clone());
    row.connect_activated(move |_| {
        if let Some(window) = weak_window.upgrade() {
            let spec = Spec::new(&value, Source::Timeline(TimelineScope::Tag(id.clone())), Kind::Plain).arranged(GridPage::Tag);
            window.push_page(&pages::grid_page(&window, spec).0);
        }
    });
    row
}

/// A tag's colour as a dot; a ring without one.
fn color_dot(color: Option<(f32, f32, f32)>) -> gtk::DrawingArea {
    let dot = gtk::DrawingArea::builder().content_width(12).content_height(12).valign(gtk::Align::Center).build();
    dot.set_draw_func(move |area, cairo, width, height| {
        let radius = f64::from(width.min(height)) / 2.0;
        let (x, y) = (f64::from(width) / 2.0, f64::from(height) / 2.0);
        match color {
            Some((red, green, blue)) => {
                cairo.set_source_rgb(f64::from(red), f64::from(green), f64::from(blue));
                cairo.arc(x, y, radius, 0.0, std::f64::consts::TAU);
                let _ = cairo.fill();
            }
            None => {
                let ink = area.color();
                cairo.set_source_rgba(f64::from(ink.red()), f64::from(ink.green()), f64::from(ink.blue()), 0.45);
                cairo.set_line_width(1.5);
                cairo.arc(x, y, radius - 0.75, 0.0, std::f64::consts::TAU);
                let _ = cairo.stroke();
            }
        }
    });
    dot
}

/// Edit Tag: its name (a slash would move it, so none) and its colour, or none.
fn edit_tag(window: &Window, tag: &Tag, reload: Rc<dyn Fn()>) {
    let name = adw::EntryRow::builder().title(tr("Name")).text(&tag.name).build();
    let chosen = tag.color.as_deref().and_then(tags::color);
    let (red, green, blue) = chosen.unwrap_or((0.21, 0.52, 0.89));
    let color = gtk::ColorDialogButton::builder().dialog(&gtk::ColorDialog::builder().with_alpha(false).build()).rgba(&gtk::gdk::RGBA::new(red, green, blue, 1.0)).valign(gtk::Align::Center).build();
    let has_color = gtk::Switch::builder().active(chosen.is_some()).valign(gtk::Align::Center).build();
    has_color.bind_property("active", &color, "sensitive").sync_create().build();
    let color_row = adw::ActionRow::builder().title(tr("Colour")).activatable_widget(&has_color).build();
    color_row.add_suffix(&color);
    color_row.add_suffix(&has_color);
    let group = adw::PreferencesGroup::new();
    group.add(&name);
    group.add(&color_row);
    let dialog = adw::AlertDialog::new(Some(tr("Edit Tag")), None);
    dialog.set_extra_child(Some(&group));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("save", tr("Save"))]);
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("save"));
    let weak_dialog = dialog.downgrade();
    name.connect_changed(move |name| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.set_response_enabled("save", tags::valid_name(&name.text()));
        }
    });
    let (weak_window, shown) = (window.downgrade(), tag.clone());
    dialog.connect_response(Some("save"), move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let new_name = name.text().trim().to_owned();
        let picked = color.rgba();
        let channel = |value: f32| (value * 255.0).round() as u8;
        let hex = format!("#{:02x}{:02x}{:02x}", channel(picked.red()), channel(picked.green()), channel(picked.blue()));
        let new_color = has_color.is_active().then_some(hex);
        let changes = TagChanges {
            name: (new_name != shown.name).then_some(new_name),
            color: (new_color.as_deref().map(str::to_lowercase) != shown.color.as_deref().map(str::to_lowercase)).then_some(new_color),
        };
        if changes == TagChanges::default() {
            return;
        }
        let (client, id, toasts, again) = (session.connection.client.clone(), shown.id.clone(), window.clone(), reload.clone());
        crate::tasks::run(async move { client.update_tag(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(_) => again(),
            Err(message) => toasts.toast(&message),
        });
    });
    dialog.present(Some(window));
}

// --- Partners ---

pub fn partners_page(window: &Window) -> adw::NavigationPage {
    let rows = RowsPage::new(tr("Partners"), tr("No Partners"), "avatar-default-symbolic");
    rows.header.pack_start(&gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("Add Partner…")).action_name("partners.add").build());
    let load: Rc<dyn Fn()> = {
        let (weak_window, rows) = (window.downgrade(), rows.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, rows, weak_window) = (session.connection.client.clone(), rows.clone(), window.downgrade());
            crate::tasks::run(
                async move {
                    let with_me = client.partners(&PartnerDirection::SharedWith).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    let by_me = client.partners(&PartnerDirection::SharedBy).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    Ok::<_, String>((with_me, by_me))
                },
                move |outcome| {
                    let Some(window) = weak_window.upgrade() else { return };
                    let (with_me, by_me) = match outcome {
                        Ok(found) => found,
                        Err(message) => {
                            rows.show("empty");
                            return window.toast(&message);
                        }
                    };
                    rows.clear();
                    rows.show("rows");
                    rows.add(&adw::PreferencesGroup::builder().description(tr("Partner sharing gives another user your whole library and its details, places included. Sharing is one-way.")).build());
                    let shared_with = adw::PreferencesGroup::builder().title(tr("Shared with Me")).build();
                    shared_with.set_description(Some(if with_me.is_empty() { tr("No partners are sharing with you.") } else { tr("The switch shows a partner's photos in your Library too.") }));
                    for partner in &with_me {
                        shared_with.add(&shared_with_row(&window, partner));
                    }
                    rows.add(&shared_with);
                    let shared_by = adw::PreferencesGroup::builder().title(tr("Sharing My Library With")).build();
                    if by_me.is_empty() {
                        shared_by.set_description(Some(tr("You are not sharing your library with anyone.")));
                    }
                    for partner in &by_me {
                        let row = adw::ActionRow::builder().title(glib::markup_escape_text(&partner.name)).subtitle(glib::markup_escape_text(&partner.email)).build();
                        row.add_prefix(&adw::Avatar::new(32, Some(&partner.name), true));
                        row.add_suffix(&gtk::Button::builder().label(tr("Remove…")).valign(gtk::Align::Center).css_classes(["flat"]).action_name("partners.remove").action_target(&partner.id.to_variant()).build());
                        shared_by.add(&row);
                    }
                    rows.add(&shared_by);
                },
            );
        })
    };
    let actions = gio::SimpleActionGroup::new();
    let add = gio::SimpleAction::new("add", None);
    let (weak_window, again) = (window.downgrade(), load.clone());
    add.connect_activate(move |_, _| {
        if let Some(window) = weak_window.upgrade() {
            add_partner(&window, again.clone());
        }
    });
    actions.add_action(&add);
    let (weak_window, again) = (window.downgrade(), load.clone());
    actions.add_action(&string_action("remove", move |id| {
        let Some(window) = weak_window.upgrade() else { return };
        let (weak, again) = (window.downgrade(), again.clone());
        crate::dialogs::confirm(&window, tr("Stop Sharing Your Library?"), tr("They no longer see your photos. Nothing is deleted."), tr("Remove Partner"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, again) = (session.connection.client.clone(), id.clone(), window.clone(), again.clone());
            crate::tasks::run(async move { client.remove_partner(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => again(),
                Err(message) => shown.toast(&message),
            });
        });
    }));
    rows.page.insert_action_group("partners", Some(&actions));
    load();
    rows.page.clone()
}

/// A partner sharing with you: their photos on a page of their own, and whether your Library shows them too.
fn shared_with_row(window: &Window, partner: &immich_api::partner::Partner) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(glib::markup_escape_text(&partner.name)).subtitle(glib::markup_escape_text(&partner.email)).activatable(true).build();
    row.add_prefix(&adw::Avatar::new(32, Some(&partner.name), true));
    let in_timeline = gtk::Switch::builder().active(partner.in_timeline.unwrap_or(false)).valign(gtk::Align::Center).tooltip_text(tr("Show in Timeline")).build();
    row.add_suffix(&in_timeline);
    row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    let (weak_window, id) = (window.downgrade(), partner.id.clone());
    in_timeline.connect_active_notify(move |switch| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, id, on, shown) = (session.connection.client.clone(), id.clone(), switch.is_active(), window.clone());
        crate::tasks::run(async move { client.set_partner_in_timeline(&id, on).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
            Ok(_) => shown.reload_grids(),
            Err(message) => shown.toast(&message),
        });
    });
    let (weak_window, id, name) = (window.downgrade(), partner.id.clone(), partner.name.clone());
    row.connect_activated(move |_| {
        if let Some(window) = weak_window.upgrade() {
            let spec = Spec::new(&name, Source::Timeline(TimelineScope::Partner(id.clone())), Kind::Partner).empty(tr("No Partner Photos"), "avatar-default-symbolic");
            window.push_page(&pages::grid_page(&window, spec).0);
        }
    });
    row
}

/// Add Partner: the server's other users, but those you share with already, to share your library with.
fn add_partner(window: &Window, reload: Rc<dyn Fn()>) {
    let Some(session) = window.session() else { return };
    let me = session.connection.user_id().map(str::to_owned);
    let (client, shown) = (session.connection.client.clone(), window.clone());
    crate::tasks::run(
        async move {
            let users = client.users().await.map_err(|error| verso_desktop::errors::said(&error))?;
            let partners = client.partners(&PartnerDirection::SharedBy).await.map_err(|error| verso_desktop::errors::said(&error))?;
            Ok::<_, String>((users, partners))
        },
        move |outcome| {
            let (users, partners) = match outcome {
                Ok(found) => found,
                Err(message) => return shown.toast(&message),
            };
            let choices: Vec<(String, String)> = users
                .into_iter()
                .filter(|user| Some(&user.id) != me.as_ref() && !partners.iter().any(|partner| partner.id == user.id))
                .map(|user| (user.id, format!("{} ({})", user.name, user.email)))
                .collect();
            if choices.is_empty() {
                return shown.toast(tr("Everyone on this server sees your library already"));
            }
            let weak = shown.downgrade();
            let body = tr("They can see and download your photos and their details.");
            crate::dialogs::choose_item_explained(&shown, tr("Share Your Library"), Some(body), tr("Search people"), choices, move |id, _| {
                let Some(window) = weak.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, shown, again) = (session.connection.client.clone(), window.clone(), reload.clone());
                crate::tasks::run(async move { client.add_partner(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(_) => again(),
                    Err(message) => shown.toast(&message),
                });
            });
        },
    );
}

// --- Duplicates ---

/// The most groups the page shows at once; the next show as these are resolved.
const DUPLICATE_GROUPS: usize = 100;

/// What the Duplicates page holds: the server's groups and, per group, the photos chosen to keep.
#[derive(Default)]
struct Found {
    groups: Vec<DuplicateGroup>,
    keep: HashMap<String, Vec<String>>,
}

pub fn duplicates_page(window: &Window) -> adw::NavigationPage {
    let rows = RowsPage::new(tr("Duplicates"), tr("No Duplicates"), "edit-copy-symbolic");
    rows.empty.set_description(Some(tr("Immich finds look-alike photos with machine learning; groups show here once it has.")));
    let sort = gio::Menu::new();
    for choice in SortBy::ALL {
        let label = match choice {
            SortBy::Default => tr("Default Order"),
            SortBy::ItemCount => tr("Most Items"),
            SortBy::TotalSize => tr("Largest Size"),
        };
        sort.append(Some(label), Some(&format!("duplicates.sort::{}", choice.code())));
    }
    let options = gio::Menu::new();
    options.append_section(Some(tr("Sort By")), &sort);
    rows.header.pack_end(&gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("View Options")).menu_model(&options).build());
    rows.header.pack_end(&gtk::Button::builder().icon_name("view-refresh-symbolic").tooltip_text(tr("Reload")).action_name("duplicates.reload").build());
    let found: Rc<RefCell<Found>> = Rc::default();
    let render: Rc<dyn Fn()> = {
        let (weak_window, rows, found) = (window.downgrade(), rows.clone(), found.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            rows.clear();
            let total = found.borrow().groups.len();
            rows.show(if total == 0 { "empty" } else { "rows" });
            let shown = verso_desktop::duplicates::load(settings::shared()).sorted(&found.borrow().groups);
            rows.content.set_description(&if total > DUPLICATE_GROUPS {
                tr("The first {count} of {total} groups").replace("{count}", &DUPLICATE_GROUPS.to_string()).replace("{total}", &total.to_string())
            } else {
                tr("{count} groups").replace("{count}", &total.to_string())
            });
            for group in shown.into_iter().take(DUPLICATE_GROUPS) {
                rows.add(&duplicate_group(&window, &session.textures, &rows, &found, group));
            }
        })
    };
    let load: Rc<dyn Fn()> = {
        let (weak_window, rows, found, render) = (window.downgrade(), rows.clone(), found.clone(), render.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, rows, found, render, shown) = (session.connection.client.clone(), rows.clone(), found.clone(), render.clone(), window.clone());
            crate::tasks::run(async move { client.duplicates().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(groups) => {
                    {
                        let mut found = found.borrow_mut();
                        let mut keep = std::mem::take(&mut found.keep);
                        // A reload keeps the choices made, for the groups still there.
                        found.keep = groups.iter().map(|group| (group.duplicate_id.clone(), keep.remove(&group.duplicate_id).unwrap_or_else(|| duplicates::suggested_keep(group)))).collect();
                        found.groups = groups;
                    }
                    render();
                }
                Err(message) => {
                    rows.show("empty");
                    shown.toast(&message);
                }
            });
        })
    };
    let actions = gio::SimpleActionGroup::new();
    let chosen = verso_desktop::duplicates::load(settings::shared());
    let sort_action = gio::SimpleAction::new_stateful("sort", Some(glib::VariantTy::STRING), &chosen.code().to_variant());
    let again = render.clone();
    sort_action.connect_change_state(move |action, value| {
        let Some(sort) = value.and_then(|value| value.get::<String>()).and_then(|code| SortBy::from_code(&code)) else { return };
        action.set_state(&sort.code().to_variant());
        verso_desktop::duplicates::save(sort, settings::shared());
        again();
    });
    actions.add_action(&sort_action);
    let reload = gio::SimpleAction::new("reload", None);
    let again = load.clone();
    reload.connect_activate(move |_, _| again());
    actions.add_action(&reload);
    rows.page.insert_action_group("duplicates", Some(&actions));
    load();
    rows.page.clone()
}

/// A group of look-alike photos, each with Keep (Immich's suggestion set first): Keep Selected, Trash Others (after
/// asking), or Dismiss Group (all stay, and the group leaves).
fn duplicate_group(window: &Window, textures: &Rc<crate::textures::Textures>, rows: &Rc<RowsPage>, found: &Rc<RefCell<Found>>, group: DuplicateGroup) -> adw::PreferencesGroup {
    let id = group.duplicate_id.clone();
    let widget = adw::PreferencesGroup::builder().title(tr("{count} Similar Items").replace("{count}", &group.assets.len().to_string())).build();
    let keep_selected = gtk::Button::builder().label(tr("Keep Selected, Trash Others…")).valign(gtk::Align::Center).build();
    let dismiss = gtk::Button::builder().label(tr("Dismiss Group…")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    let buttons = gtk::Box::builder().spacing(6).build();
    buttons.append(&dismiss);
    buttons.append(&keep_selected);
    widget.set_header_suffix(Some(&buttons));
    let all = group.assets.len();
    let update: Rc<dyn Fn()> = {
        let (button, found, id) = (keep_selected.downgrade(), found.clone(), id.clone());
        Rc::new(move || {
            let kept = found.borrow().keep.get(&id).map_or(0, Vec::len);
            if let Some(button) = button.upgrade() {
                button.set_sensitive(kept > 0 && kept < all);
            }
        })
    };
    update();
    let pictures = gtk::Box::builder().spacing(16).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
    for asset in &group.assets {
        let size = asset.exif.as_ref().and_then(|exif| exif.file_size).map_or_else(|| tr("Size Unavailable").to_owned(), text::size);
        let card = card(textures, ImageKind::Thumbnail, Some(&asset.id), &asset.original_file_name, &size, 180);
        let kept = found.borrow().keep.get(&id).is_some_and(|keep| keep.contains(&asset.id));
        let keep = gtk::CheckButton::builder().label(tr("Keep")).active(kept).build();
        let (found, group_id, asset_id, update) = (found.clone(), id.clone(), asset.id.clone(), update.clone());
        keep.connect_toggled(move |keep| {
            {
                let mut found = found.borrow_mut();
                let chosen = found.keep.entry(group_id.clone()).or_default();
                chosen.retain(|known| *known != asset_id);
                if keep.is_active() {
                    chosen.push(asset_id.clone());
                }
            }
            update();
        });
        card.append(&keep);
        pictures.append(&card);
    }
    let frame = gtk::ScrolledWindow::builder().child(&pictures).vscrollbar_policy(gtk::PolicyType::Never).propagate_natural_height(true).css_classes(["card"]).build();
    widget.add(&frame);
    // Resolved or dismissed: the group leaves, the grids read again, and an emptied page says so.
    let gone: Rc<dyn Fn()> = {
        let (weak_window, rows, found, weak_group, id) = (window.downgrade(), rows.clone(), found.clone(), widget.downgrade(), id.clone());
        Rc::new(move || {
            let left = {
                let mut found = found.borrow_mut();
                found.groups.retain(|group| group.duplicate_id != id);
                found.keep.remove(&id);
                found.groups.len()
            };
            if let Some(group) = weak_group.upgrade() {
                rows.remove(&group);
            }
            if left == 0 {
                rows.show("empty");
            }
            if let Some(window) = weak_window.upgrade() {
                window.reload_grids();
                window.refresh_albums();
            }
        })
    };
    let (weak_window, found_for_keep, done) = (window.downgrade(), found.clone(), gone.clone());
    keep_selected.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let keep = found_for_keep.borrow().keep.get(&group.duplicate_id).cloned().unwrap_or_default();
        let trash: Vec<String> = group.assets.iter().map(|asset| asset.id.clone()).filter(|id| !keep.contains(id)).collect();
        if keep.is_empty() || trash.is_empty() {
            return;
        }
        let resolution = DuplicateResolution { duplicate_id: group.duplicate_id.clone(), keep_asset_ids: keep, trash_asset_ids: trash };
        let (weak, done) = (window.downgrade(), done.clone());
        crate::dialogs::confirm(&window, tr("Move the Others to Recently Deleted?"), tr("The photos chosen stay in your library. The others go to Recently Deleted, where they can be restored until the trash is emptied."), tr("Trash Others"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, resolution, shown, done) = (session.connection.client.clone(), resolution.clone(), window.clone(), done.clone());
            crate::tasks::run(async move { client.resolve_duplicates(&[resolution]).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(results) if results.iter().all(|result| result.success) => done(),
                Ok(results) => shown.toast(&tr("{count} could not be changed").replace("{count}", &results.iter().filter(|result| !result.success).count().to_string())),
                Err(message) => shown.toast(&message),
            });
        });
    });
    let weak_window = window.downgrade();
    dismiss.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let (weak, id, done) = (window.downgrade(), id.clone(), gone.clone());
        crate::dialogs::confirm(&window, tr("Dismiss This Group?"), tr("All its photos stay in your library, and Immich no longer suggests them as duplicates."), tr("Dismiss Group"), false, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, done) = (session.connection.client.clone(), id.clone(), window.clone(), done.clone());
            crate::tasks::run(async move { client.dismiss_duplicate_group(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => done(),
                Err(message) => shown.toast(&message),
            });
        });
    });
    widget
}
