//! People and a person's page, as the Mac gallery has them. People: all, favorites or the hidden ones (a switch in the
//! header, remembered), hidden ones shown with the rest when asked (`verso_core::people`, which filters for the Mac and
//! the iPhone too), each face a rounded square with the name on it (round is for accounts, `avatars`), sized with the
//! cards (`cards::zoom`), and a menu on each face (rename, favorite, hide, merge, links). A person's page: a header
//! with the face, the name (edited in place), a favorite heart (a star means a rating), how many photos, and the
//! birthday with the age; the Person menu.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use chrono::{Datelike, NaiveDate};
use gtk::{gio, glib};
use immich_api::{Person, PersonChanges, TimelineScope};
use verso_desktop::arrangement::GridPage;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Source;
use verso_desktop::settings;
use verso_core::links::ImmichItem;
use verso_core::people::{Arrangement, Show};
use verso_linux::i18n::tr;

use crate::collections::{card_page, item_actions, SquareFrame};
use crate::grid::{Grid, WeakGrid};
use crate::pages::{self, Kind, Spec};
use crate::window::Window;

pub fn people_page(window: &Window) -> adw::NavigationPage {
    let cards = card_page(tr("People"), tr("No People"), "system-users-symbolic");
    // Faces at the cards' zoom, as many on a line as fit.
    cards.page.add_css_class("verso-card-page");
    cards.header.pack_start(&crate::cards::zoom_buttons());
    cards.flow.set_max_children_per_line(20);
    cards.flow.add_css_class("verso-faces");
    let shows = adw::ToggleGroup::new();
    for (show, label) in [(Show::All, tr("All People")), (Show::Favorites, tr("Favorites")), (Show::Hidden, tr("Hidden People"))] {
        shows.add(adw::Toggle::builder().name(show.code()).label(label).build());
    }
    shows.set_active_name(Some(settings::shared().get("people.show").as_deref().unwrap_or(Show::All.code())));
    cards.header.set_title_widget(Some(&shows));
    let include_hidden = gio::SimpleAction::new_stateful("include-hidden", None, &(settings::shared().get("people.includeHidden").as_deref() == Some("true")).to_variant());
    let options = gio::Menu::new();
    options.append(Some(tr("Include Hidden People")), Some("people.include-hidden"));
    cards.header.pack_end(&gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("View Options")).menu_model(&options).build());

    let people: Rc<RefCell<Vec<Person>>> = Rc::default();
    let render: Rc<dyn Fn()> = {
        let (weak_window, flow, stack, empty, people, weak_shows) = (window.downgrade(), cards.flow.clone(), cards.stack.clone(), cards.empty.clone(), people.clone(), shows.downgrade());
        let include = include_hidden.clone();
        Rc::new(move || {
            let (Some(window), Some(shows)) = (weak_window.upgrade(), weak_shows.upgrade()) else { return };
            let Some(session) = window.session() else { return };
            while let Some(child) = flow.first_child() {
                flow.remove(&child);
            }
            let arrangement = Arrangement {
                show: shows.active_name().and_then(|name| Show::from_code(&name)).unwrap_or_default(),
                include_hidden: include.state().and_then(|state| state.get::<bool>()).unwrap_or(false),
            };
            let mut shown: Vec<Person> = people.borrow().iter().filter(|person| arrangement.includes(person.is_favorite, person.is_hidden)).cloned().collect();
            // Favorites first, then named people as Immich lists them, then the unnamed.
            shown.sort_by_key(|person| (!person.is_favorite, person.name.is_empty()));
            empty.set_title(if people.borrow().is_empty() { tr("No People") } else { tr("No Matching People") });
            stack.set_visible_child_name(if shown.is_empty() { "empty" } else { "cards" });
            for person in shown.into_iter().take(1000) {
                let card = face_tile(&session.textures, &person);
                attach_menu(&card, &person);
                let (weak_window, id, name) = (window.downgrade(), person.id.clone(), person.name.clone());
                crate::collections::add_card(&flow, &card, &person.name, move || {
                    if let Some(window) = weak_window.upgrade() {
                        window.open_person(&id, &name);
                    }
                });
            }
        })
    };
    let again = render.clone();
    shows.connect_active_name_notify(move |shows| {
        settings::shared().set("people.show", shows.active_name().as_deref().filter(|name| *name != Show::All.code()));
        again();
    });
    let again = render.clone();
    include_hidden.connect_activate(move |action, _| {
        let on = !action.state().and_then(|state| state.get::<bool>()).unwrap_or(false);
        action.set_state(&on.to_variant());
        settings::shared().set("people.includeHidden", on.then_some("true"));
        again();
    });

    // The faces' menu: each item names its person.
    let group = gio::SimpleActionGroup::new();
    group.add_action(&include_hidden);
    let reload: Rc<dyn Fn()> = {
        let (weak_window, people, render) = (window.downgrade(), people.clone(), render.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, people, render) = (session.connection.client.clone(), people.clone(), render.clone());
            let shown = window.clone();
            crate::tasks::run(async move { client.people().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(found) => {
                    people.replace(found);
                    render();
                }
                Err(message) => shown.toast(&message),
            });
        })
    };
    for name in ["rename", "favorite", "unfavorite", "hide", "unhide", "merge", "open-in-immich", "copy-link"] {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let (weak_window, people, reload) = (window.downgrade(), people.clone(), reload.clone());
        action.connect_activate(move |action, value| {
            let (Some(window), Some(id)) = (weak_window.upgrade(), value.and_then(|value| value.get::<String>())) else { return };
            let Some(person) = people.borrow().iter().find(|person| person.id == id).cloned() else { return };
            let reload = reload.clone();
            match action.name().as_str() {
                "rename" => rename_person(&window, &person, move || reload()),
                "favorite" | "unfavorite" => change_person(&window, &person.id, PersonChanges { is_favorite: Some(action.name() == "favorite"), ..PersonChanges::default() }, move || reload()),
                "hide" | "unhide" => change_person(&window, &person.id, PersonChanges { is_hidden: Some(action.name() == "hide"), ..PersonChanges::default() }, move || reload()),
                "merge" => crate::collections::merge_person(&window, person.id.clone(), person.name.clone()),
                "open-in-immich" => window.open_item_in_immich(ImmichItem::Person(person.id.clone())),
                _ => window.copy_item_link(ImmichItem::Person(person.id.clone())),
            }
        });
        group.add_action(&action);
    }
    cards.page.insert_action_group("people", Some(&group));
    reload();
    cards.page
}

/// A person as their face, a rounded square as albums and places are (an account you share with is round, as a thing
/// apart): their name on a fade at its foot, a heart for a favorite, faded when hidden; at the cards' zoom.
fn face_tile(textures: &Rc<crate::textures::Textures>, person: &Person) -> gtk::Box {
    let picture = crate::cards::picture(textures, ImageKind::Person, &person.id);
    let name = if person.name.is_empty() { tr("Unnamed") } else { &person.name };
    let (tile, area) = crate::cards::square_tile(&picture, name, None);
    if person.is_favorite {
        let star = crate::cards::chip(Some("verso-heart-symbolic"), None, tr("Favorite"));
        star.set_halign(gtk::Align::End);
        star.set_valign(gtk::Align::Start);
        star.set_margin_top(6);
        star.set_margin_end(6);
        area.add_overlay(&star);
    }
    if person.is_hidden {
        tile.add_css_class("hidden");
        tile.set_tooltip_text(Some(tr("Hidden")));
    }
    tile
}

/// A face's menu, on a right click.
fn attach_menu(card: &gtk::Box, person: &Person) {
    let menu = gio::Menu::new();
    let item = |menu: &gio::Menu, label: &str, action: &str| {
        let entry = gio::MenuItem::new(Some(label), None);
        entry.set_action_and_target_value(Some(&format!("people.{action}")), Some(&person.id.to_variant()));
        menu.append_item(&entry);
    };
    let changing = gio::Menu::new();
    item(&changing, tr("Rename…"), "rename");
    item(&changing, if person.is_favorite { tr("Remove from Favorites") } else { tr("Favorite") }, if person.is_favorite { "unfavorite" } else { "favorite" });
    item(&changing, if person.is_hidden { tr("Show in People") } else { tr("Hide from People") }, if person.is_hidden { "unhide" } else { "hide" });
    item(&changing, tr("Merge With Another Person…"), "merge");
    menu.append_section(None, &changing);
    let links = gio::Menu::new();
    item(&links, tr("Open in Immich"), "open-in-immich");
    item(&links, tr("Copy Immich Link"), "copy-link");
    menu.append_section(None, &links);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_parent(card);
    popover.set_has_arrow(false);
    let click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    let weak = popover.downgrade();
    click.connect_pressed(move |_, _, x, y| {
        if let Some(popover) = weak.upgrade() {
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        }
    });
    card.add_controller(click);
}

/// Change a person, then run `done`.
fn change_person(window: &Window, id: &str, changes: PersonChanges, done: impl Fn() + 'static) {
    let Some(session) = window.session() else { return };
    let (client, id, shown) = (session.connection.client.clone(), id.to_owned(), window.clone());
    crate::tasks::run(async move { client.update_person(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
        Ok(_) => done(),
        Err(message) => shown.toast(&message),
    });
}

fn rename_person(window: &Window, person: &Person, done: impl Fn() + 'static) {
    let (weak, id) = (window.downgrade(), person.id.clone());
    let done = Rc::new(done);
    crate::dialogs::ask_text(window, tr("Rename"), tr("Name"), &person.name, tr("Rename"), move |name| {
        let Some(window) = weak.upgrade() else { return };
        let done = done.clone();
        change_person(&window, &id, PersonChanges { name: Some(name), ..PersonChanges::default() }, move || done());
    });
}

/// Edit Name and Birthday: both in one dialog; the birthday can be taken away.
fn edit_person(window: &Window, person: &Person, done: impl Fn() + 'static) {
    let name = adw::EntryRow::builder().title(tr("Name")).text(&person.name).build();
    let has_birthday = adw::SwitchRow::builder().title(tr("Birthday")).active(person.birth_date.is_some()).build();
    let calendar = gtk::Calendar::builder().visible(person.birth_date.is_some()).build();
    if let Some(date) = person.birth_date {
        if let Ok(date) = glib::DateTime::from_local(date.year(), date.month() as i32, date.day() as i32, 0, 0, 0.0) {
            calendar.select_day(&date);
        }
    }
    has_birthday.bind_property("active", &calendar, "visible").sync_create().build();
    let group = adw::PreferencesGroup::new();
    group.add(&name);
    group.add(&has_birthday);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).build();
    content.append(&group);
    content.append(&calendar);
    let dialog = adw::AlertDialog::new(Some(tr("Edit Name and Birthday")), None);
    dialog.set_extra_child(Some(&content));
    dialog.add_responses(&[("cancel", tr("Cancel")), ("save", tr("Save"))]);
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    let (weak_window, id, done) = (window.downgrade(), person.id.clone(), Rc::new(done));
    dialog.connect_response(Some("save"), move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let day = calendar.date();
        let birthday = has_birthday.is_active().then(|| NaiveDate::from_ymd_opt(day.year(), day.month() as u32, day.day_of_month() as u32)).flatten();
        let changes = PersonChanges { name: Some(name.text().trim().to_owned()), birth_date: Some(birthday), ..PersonChanges::default() };
        let done = done.clone();
        change_person(&window, &id, changes, move || done());
    });
    dialog.present(Some(window));
}

/// What a person action does, with the person as read and a way to read the header again.
type PersonAction = Box<dyn Fn(&Window, &Person, Rc<dyn Fn()>)>;

pub fn person_page(window: &Window, id: &str, name: &str) -> adw::NavigationPage {
    let title = if name.is_empty() { tr("Unnamed") } else { name };
    let mut spec = Spec::new(title, Source::Timeline(TimelineScope::Person(id.to_owned())), Kind::Person { id: id.to_owned() }).arranged(GridPage::Person);
    let menu = gio::Menu::new();
    let changing = gio::Menu::new();
    changing.append(Some(tr("Edit Name and Birthday…")), Some("page.edit"));
    changing.append(Some(tr("Use as Face Photo")), Some("page.face-photo"));
    changing.append(Some(tr("Favorite")), Some("page.favorite"));
    changing.append(Some(tr("Hide from People")), Some("page.hide"));
    changing.append(Some(tr("Merge With Another Person…")), Some("page.merge"));
    menu.append_section(None, &changing);
    let links = gio::Menu::new();
    crate::crosslink::append(&links, "person", "page");
    menu.append_section(None, &links);
    spec.menu = Some(menu);
    spec.actions = item_actions(window, ImmichItem::Person(id.to_owned()));
    let header = PersonHeader::new(window);
    spec.above = Some(header.root.clone().upcast());
    let person: Rc<RefCell<Option<Person>>> = Rc::default();
    let shown_grid: Rc<RefCell<Option<WeakGrid>>> = Rc::default();
    let header = Rc::new(header);
    let refresh: Rc<dyn Fn()> = {
        let (weak_window, id, person, header) = (window.downgrade(), id.to_owned(), person.clone(), header.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, person, header, weak_window) = (session.connection.client.clone(), id.clone(), person.clone(), header.clone(), window.downgrade());
            crate::tasks::run(
                async move {
                    let read = client.person(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    let count = client.person_statistics(&id).await.unwrap_or_default();
                    Ok::<_, String>((read, count))
                },
                move |outcome| {
                    let Some(window) = weak_window.upgrade() else { return };
                    match outcome {
                        Ok((read, count)) => {
                            header.fill(&window, &read, count);
                            person.replace(Some(read));
                        }
                        Err(message) => window.toast(&message),
                    }
                },
            );
        })
    };
    let add = |name: &str, run: PersonAction| {
        let action = gio::SimpleAction::new(name, None);
        let (weak_window, person, refresh) = (window.downgrade(), person.clone(), refresh.clone());
        action.connect_activate(move |_, _| {
            let (Some(window), Some(person)) = (weak_window.upgrade(), person.borrow().clone()) else { return };
            run(&window, &person, refresh.clone());
        });
        action
    };
    spec.actions.push(add("edit", Box::new(|window, person, refresh| edit_person(window, person, move || refresh()))));
    spec.actions.push(add("favorite", Box::new(|window, person, refresh| change_person(window, &person.id, PersonChanges { is_favorite: Some(!person.is_favorite), ..PersonChanges::default() }, move || refresh()))));
    spec.actions.push(add("hide", Box::new(|window, person, refresh| change_person(window, &person.id, PersonChanges { is_hidden: Some(!person.is_hidden), ..PersonChanges::default() }, move || refresh()))));
    spec.actions.push(add("merge", Box::new(|window, person, _| crate::collections::merge_person(window, person.id.clone(), person.name.clone()))));
    let grid_holder = shown_grid.clone();
    spec.actions.push(add(
        "face-photo",
        Box::new(move |window, person, refresh| {
            let selected = grid_holder.borrow().as_ref().and_then(WeakGrid::upgrade).map(|grid| grid.selected_ids()).unwrap_or_default();
            let [photo] = selected.as_slice() else { return window.toast(tr("Select the one photo to use as the face")) };
            let changes = PersonChanges { feature_face_asset_id: Some(photo.clone()), ..PersonChanges::default() };
            let shown = window.clone();
            let id = person.id.clone();
            change_person(window, &person.id, changes, move || {
                if let Some(session) = shown.session() {
                    session.textures.forget(&id);
                    session.textures.cache().forget_pictures(std::slice::from_ref(&id));
                }
                shown.toast(tr("The face photo changed"));
                refresh();
            });
        }),
    ));
    let (page, grid) = pages::grid_page(window, spec);
    shown_grid.replace(grid.as_ref().map(Grid::downgrade));
    refresh();
    page
}

/// The header above a person's photos.
struct PersonHeader {
    root: gtk::Box,
    /// The person shown: id and name, for the name edited in place.
    shown: Rc<RefCell<Option<(String, String)>>>,
    face: gtk::Picture,
    name: gtk::EditableLabel,
    star: gtk::Button,
    facts: gtk::Label,
    birthday: gtk::Button,
}

impl PersonHeader {
    fn new(window: &Window) -> PersonHeader {
        let face = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let frame = SquareFrame::new(72, &face);
        frame.add_css_class("gallery-face");
        frame.set_valign(gtk::Align::Center);
        let name = gtk::EditableLabel::builder().css_classes(["title-1"]).build();
        let star = gtk::Button::builder().icon_name("verso-heart-outline-symbolic").css_classes(["flat", "circular"]).valign(gtk::Align::Center).action_name("page.favorite").tooltip_text(tr("Favorite")).build();
        let title = gtk::Box::builder().spacing(6).build();
        title.append(&name);
        title.append(&star);
        let facts = gtk::Label::builder().xalign(0.0).css_classes(["dim-label"]).build();
        let birthday = gtk::Button::builder().css_classes(["flat"]).halign(gtk::Align::Start).action_name("page.edit").build();
        let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).valign(gtk::Align::Center).build();
        column.append(&title);
        column.append(&facts);
        column.append(&birthday);
        let root = gtk::Box::builder().spacing(18).margin_top(12).margin_bottom(6).margin_start(18).margin_end(18).build();
        root.append(&frame);
        root.append(&column);
        // The name edits in place: Enter or leaving the field saves it.
        let shown: Rc<RefCell<Option<(String, String)>>> = Rc::default();
        let (weak_window, person) = (window.downgrade(), shown.clone());
        name.connect_editing_notify(move |label| {
            if label.is_editing() {
                return;
            }
            let Some((id, before)) = person.borrow().clone() else { return };
            let text = label.text().trim().to_owned();
            if text == before || text.is_empty() || text == tr("Add a Name") {
                return;
            }
            if let Some(window) = weak_window.upgrade() {
                change_person(&window, &id, PersonChanges { name: Some(text), ..PersonChanges::default() }, || {});
            }
        });
        PersonHeader { root, shown, face, name, star, facts, birthday }
    }

    fn fill(&self, window: &Window, person: &Person, count: u64) {
        if let Some(session) = window.session() {
            let weak = self.face.downgrade();
            session.textures.get(ImageKind::Person, &person.id, None, move |texture| {
                if let (Some(face), Some(texture)) = (weak.upgrade(), texture) {
                    face.set_paintable(Some(&texture));
                }
            });
        }
        self.name.set_text(if person.name.is_empty() { tr("Add a Name") } else { &person.name });
        self.star.set_icon_name(if person.is_favorite { "verso-heart-symbolic" } else { "verso-heart-outline-symbolic" });
        self.facts.set_label(&if count == 1 { tr("1 photo or video").to_owned() } else { tr("{count} photos and videos").replace("{count}", &count.to_string()) });
        self.birthday.set_label(&match person.birth_date {
            Some(born) => {
                let today = chrono::Local::now().date_naive();
                let age = today.year() - born.year() - i32::from((today.month(), today.day()) < (born.month(), born.day()));
                tr("Born {date} ({age})").replace("{date}", &verso_desktop::text::short_day(born)).replace("{age}", &age.to_string())
            }
            None => tr("Add Birthday").to_owned(),
        });
        self.shown.replace(Some((person.id.clone(), person.name.clone())));
    }
}
