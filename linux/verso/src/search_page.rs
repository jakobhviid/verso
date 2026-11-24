//! Search, as the Mac gallery has it: words looked for in what photos show, file names, descriptions or the text in
//! photos; filters (people, place, camera, dates, media type, not in an album, archived, favorites, rating) set in a
//! sheet and shown as chips; the results' order; recent searches; and, with nothing to search for, a landing page
//! with quick filters, the recent searches and the places in the library (`verso_desktop::search`).

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use chrono::{Datelike, NaiveDate};
use gtk::{gio, glib};
use immich_api::{SuggestionKind, SuggestionQuery};
use verso_desktop::arrangement::MediaType;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::{Source, Tile};
use verso_desktop::search::{self, Filters, Mode, Order, Recent};
use verso_desktop::settings;
use verso_linux::i18n::tr;

use crate::collections::card;
use crate::grid::Grid;
use crate::pages::{self, Kind};
use crate::window::Window;

const MODES: [(Mode, &str); 4] = [(Mode::Context, "What Photos Show"), (Mode::FileName, "File Name"), (Mode::Description, "Description"), (Mode::Text, "Text in Photos")];

struct SearchPage {
    window: glib::WeakRef<Window>,
    account: String,
    entry: gtk::SearchEntry,
    modes: gtk::DropDown,
    order: Cell<Order>,
    filters: RefCell<Filters>,
    grid: Grid,
    stack: gtk::Stack,
    chips: gtk::FlowBox,
    chips_bar: gtk::Revealer,
    recent_box: gtk::FlowBox,
    recent_group: gtk::Box,
    recent_menu: gio::Menu,
    note: gtk::Label,
}

pub fn search_page(window: &Window) -> adw::NavigationPage {
    let Some(session) = window.session() else { return pages::message_page(tr("Search"), tr("Search"), "", "system-search-symbolic") };
    let account = session.connection.cache_directory().file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let entry = gtk::SearchEntry::builder().placeholder_text(tr("Search your library")).hexpand(true).build();
    let modes = gtk::DropDown::from_strings(&MODES.iter().map(|(_, title)| tr(title)).collect::<Vec<_>>());
    modes.set_tooltip_text(Some(tr("Search In")));
    let filters_button = gtk::Button::builder().label(tr("Filters")).tooltip_text(tr("Search Filters")).build();
    let order_menu = gio::Menu::new();
    for (label, target) in [(tr("Default Order"), "default"), (tr("Newest First"), "newest"), (tr("Oldest First"), "oldest")] {
        order_menu.append(Some(label), Some(&format!("search.order::{target}")));
    }
    let order_button = gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("Order")).menu_model(&order_menu).build();
    let recent_menu = gio::Menu::new();
    let recent_button = gtk::MenuButton::builder().icon_name("document-open-recent-symbolic").tooltip_text(tr("Recent Searches")).menu_model(&recent_menu).build();
    let clamp = adw::Clamp::builder().maximum_size(560).child(&entry).build();
    let header = adw::HeaderBar::builder().title_widget(&clamp).build();
    header.pack_start(&modes);
    header.pack_end(&recent_button);
    header.pack_end(&order_button);
    header.pack_end(&filters_button);

    let chips = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).column_spacing(6).row_spacing(6).max_children_per_line(30).halign(gtk::Align::Start).hexpand(true).build();
    let clear = gtk::Button::builder().label(tr("Clear Filters")).css_classes(["flat"]).valign(gtk::Align::Center).build();
    let bar = gtk::Box::builder().spacing(6).margin_top(6).margin_bottom(6).margin_start(12).margin_end(12).build();
    bar.append(&chips);
    bar.append(&clear);
    let chips_bar = gtk::Revealer::builder().child(&bar).reveal_child(false).transition_type(gtk::RevealerTransitionType::None).build();
    let note = gtk::Label::builder().css_classes(["dim-label", "caption"]).margin_top(6).margin_start(12).xalign(0.0).visible(false).build();

    let grid = Grid::new(session.connection.client.clone(), session.textures.clone(), Source::Tiles { tiles: Vec::new(), by_month: false }, tr("No Results"), "system-search-symbolic");
    let (landing, recent_box, recent_group, places_flow, quick) = landing_page();
    let stack = gtk::Stack::new();
    stack.add_named(&landing, Some("landing"));
    stack.add_named(grid.widget(), Some("results"));
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    content.append(&chips_bar);
    content.append(&note);
    content.append(&stack);
    stack.set_vexpand(true);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&content));
    let page = adw::NavigationPage::builder().title(tr("Search")).child(&toolbar).build();

    let state = Rc::new(SearchPage {
        window: window.downgrade(),
        account,
        entry: entry.clone(),
        modes: modes.clone(),
        order: Cell::new(Order::Default),
        filters: RefCell::default(),
        grid: grid.clone(),
        stack,
        chips,
        chips_bar,
        recent_box,
        recent_group,
        recent_menu,
        note,
    });

    let weak_window = window.downgrade();
    grid.on_open(move |tiles: Vec<Tile>, index| {
        if let Some(window) = weak_window.upgrade() {
            window.open_viewer(tiles, index, Kind::Plain);
        }
    });
    let weak_window = window.downgrade();
    grid.on_failed(move |message| {
        if let Some(window) = weak_window.upgrade() {
            window.toast(message);
        }
    });

    // Actions: the order, and a recent search made again.
    let group = gio::SimpleActionGroup::new();
    let order = gio::SimpleAction::new_stateful("order", Some(glib::VariantTy::STRING), &"default".to_variant());
    let weak = Rc::downgrade(&state);
    order.connect_change_state(move |action, value| {
        let (Some(state), Some(value)) = (weak.upgrade(), value) else { return };
        action.set_state(value);
        state.order.set(match value.get::<String>().as_deref() {
            Some("newest") => Order::NewestFirst,
            Some("oldest") => Order::OldestFirst,
            _ => Order::Default,
        });
        state.run(false);
    });
    group.add_action(&order);
    let again = gio::SimpleAction::new("again", Some(glib::VariantTy::STRING));
    let weak = Rc::downgrade(&state);
    again.connect_activate(move |_, value| {
        let (Some(state), Some(line)) = (weak.upgrade(), value.and_then(|value| value.get::<String>())) else { return };
        if let Some((mode, text)) = line.split_once('\t') {
            state.search_again(Mode::from_code(mode).unwrap_or_default(), text);
        }
    });
    group.add_action(&again);
    let clear_history = gio::SimpleAction::new("clear-history", None);
    let weak = Rc::downgrade(&state);
    clear_history.connect_activate(move |_, _| {
        if let Some(state) = weak.upgrade() {
            search::clear_recent(settings::shared(), &state.account);
            state.show_recent();
        }
    });
    group.add_action(&clear_history);
    page.insert_action_group("search", Some(&group));

    let weak = Rc::downgrade(&state);
    entry.connect_activate(move |_| {
        if let Some(state) = weak.upgrade() {
            state.run(true);
        }
    });
    let weak = Rc::downgrade(&state);
    modes.connect_selected_notify(move |_| {
        if let Some(state) = weak.upgrade() {
            state.run(false);
        }
    });
    let weak = Rc::downgrade(&state);
    filters_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.edit_filters();
        }
    });
    let weak = Rc::downgrade(&state);
    clear.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.filters.replace(Filters::default());
            state.run(false);
        }
    });
    for (button, set) in quick {
        let weak = Rc::downgrade(&state);
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                set(&mut state.filters.borrow_mut());
                state.run(false);
            }
        });
    }
    state.show_recent();
    state.fill_places(&places_flow);
    window.register_grid(&page, &grid);
    let held = state.clone();
    page.connect_destroy(move |_| {
        let _ = &held;
    });
    // Typing anywhere on the page searches; the field takes the focus once the page is on screen.
    entry.set_key_capture_widget(Some(&page));
    entry.connect_map(|entry| {
        let entry = entry.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(entry) = entry.upgrade() {
                entry.grab_focus();
            }
        });
    });
    page
}

type QuickFilter = (gtk::Button, fn(&mut Filters));

/// The landing page: a heading, quick filters, the recent searches, the places.
fn landing_page() -> (gtk::ScrolledWindow, gtk::FlowBox, gtk::Box, gtk::FlowBox, Vec<QuickFilter>) {
    let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(18).margin_top(24).margin_bottom(24).margin_start(24).margin_end(24).build();
    column.append(&gtk::Label::builder().label(tr("Search Your Photos")).css_classes(["title-1"]).build());
    column.append(&gtk::Label::builder().label(tr("Look for what photos show, such as “a dog on a beach” (it needs machine learning on the server), or for file names, descriptions and the text in photos. Filters narrow any search, or search on their own.")).wrap(true).justify(gtk::Justification::Center).css_classes(["dim-label"]).build());
    let quick_row = gtk::Box::builder().spacing(12).halign(gtk::Align::Center).build();
    let quick: Vec<QuickFilter> = vec![
        (gtk::Button::builder().label(tr("Favorites")).css_classes(["pill"]).build(), |filters: &mut Filters| filters.favorites = true),
        (gtk::Button::builder().label(tr("Photos")).css_classes(["pill"]).build(), |filters: &mut Filters| filters.media_type = MediaType::Photos),
        (gtk::Button::builder().label(tr("Videos")).css_classes(["pill"]).build(), |filters: &mut Filters| filters.media_type = MediaType::Videos),
    ];
    for (button, _) in &quick {
        quick_row.append(button);
    }
    column.append(&quick_row);
    let recent_group = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).build();
    let recent_heading = gtk::Box::builder().spacing(6).build();
    recent_heading.append(&gtk::Label::builder().label(tr("Recent Searches")).xalign(0.0).hexpand(true).css_classes(["heading"]).build());
    recent_heading.append(&gtk::Button::builder().label(tr("Clear History")).action_name("search.clear-history").css_classes(["flat"]).build());
    recent_group.append(&recent_heading);
    let recent_box = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).column_spacing(6).row_spacing(6).max_children_per_line(6).build();
    recent_group.append(&recent_box);
    column.append(&recent_group);
    let places_heading = gtk::Label::builder().label(tr("Places in Your Library")).xalign(0.0).css_classes(["heading"]).build();
    column.append(&places_heading);
    let places_flow = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).activate_on_single_click(true).homogeneous(true).row_spacing(12).column_spacing(12).max_children_per_line(6).build();
    column.append(&places_flow);
    let clamp = adw::Clamp::builder().maximum_size(900).child(&column).build();
    (gtk::ScrolledWindow::builder().child(&clamp).hscrollbar_policy(gtk::PolicyType::Never).build(), recent_box, recent_group, places_flow, quick)
}

impl SearchPage {
    fn mode(&self) -> Mode {
        MODES.get(self.modes.selected() as usize).map_or(Mode::Context, |(mode, _)| *mode)
    }

    /// Search with what is set now; `remember` keeps the words among the recent searches.
    fn run(self: &Rc<Self>, remember: bool) {
        let text = self.entry.text().trim().to_owned();
        let filters = self.filters.borrow().clone();
        self.show_chips(&filters);
        let order = self.order.get();
        self.note.set_visible(order != Order::Default && self.mode() == Mode::Context && !text.is_empty());
        self.note.set_label(tr("Sorted by date: the best 250 matches."));
        match search::source(self.mode(), &text, &filters, order) {
            Some(source) => {
                if remember && !text.is_empty() {
                    search::remember(settings::shared(), &self.account, Recent { mode: self.mode(), text });
                    self.show_recent();
                }
                self.stack.set_visible_child_name("results");
                self.grid.set_source(source);
            }
            None => self.stack.set_visible_child_name("landing"),
        }
    }

    fn search_again(self: &Rc<Self>, mode: Mode, text: &str) {
        if let Some(index) = MODES.iter().position(|(known, _)| *known == mode) {
            self.modes.set_selected(index as u32);
        }
        self.entry.set_text(text);
        self.run(true);
    }

    fn show_chips(self: &Rc<Self>, filters: &Filters) {
        while let Some(child) = self.chips.first_child() {
            self.chips.remove(&child);
        }
        for (chip, label) in filters.chips(|text| tr(text).to_owned()) {
            let content = gtk::Box::builder().spacing(4).build();
            content.append(&gtk::Label::new(Some(&label)));
            content.append(&gtk::Image::from_icon_name("window-close-symbolic"));
            let button = gtk::Button::builder().child(&content).css_classes(["pill", "small"]).tooltip_text(tr("Remove the Filter")).build();
            let weak = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(state) = weak.upgrade() {
                    state.filters.borrow_mut().remove(chip);
                    state.run(false);
                }
            });
            self.chips.append(&button);
        }
        self.chips_bar.set_reveal_child(!filters.is_empty());
    }

    fn show_recent(self: &Rc<Self>) {
        let recent = search::recent(settings::shared(), &self.account);
        self.recent_menu.remove_all();
        while let Some(child) = self.recent_box.first_child() {
            self.recent_box.remove(&child);
        }
        let searches = gio::Menu::new();
        for known in recent.iter() {
            let target = format!("{}\t{}", known.mode.code(), known.text);
            let item = gio::MenuItem::new(Some(&known.text), None);
            item.set_action_and_target_value(Some("search.again"), Some(&target.to_variant()));
            searches.append_item(&item);
        }
        self.recent_menu.append_section(None, &searches);
        let clearing = gio::Menu::new();
        clearing.append(Some(tr("Clear History")), Some("search.clear-history"));
        self.recent_menu.append_section(None, &clearing);
        for known in recent.iter().take(6) {
            let button = gtk::Button::builder().label(&known.text).css_classes(["pill"]).build();
            let (weak, mode, text) = (Rc::downgrade(self), known.mode, known.text.clone());
            button.connect_clicked(move |_| {
                if let Some(state) = weak.upgrade() {
                    state.search_again(mode, &text);
                }
            });
            self.recent_box.append(&button);
        }
        self.recent_group.set_visible(!recent.is_empty());
    }

    /// Up to twelve cities of the library; one sets the City filter.
    fn fill_places(self: &Rc<Self>, flow: &gtk::FlowBox) {
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let client = session.connection.client.clone();
        let (weak, weak_flow, textures) = (Rc::downgrade(self), flow.downgrade(), session.textures.clone());
        crate::tasks::run(async move { client.city_assets().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            let (Some(state), Some(flow), Ok(assets)) = (weak.upgrade(), weak_flow.upgrade(), outcome) else { return };
            for details in assets.iter().take(12) {
                let Some(exif) = details.exif.as_ref() else { continue };
                let Some(city) = exif.city.clone().filter(|city| !city.is_empty()) else { continue };
                let country = exif.country.clone().unwrap_or_default();
                let card = card(&textures, ImageKind::Thumbnail, Some(&details.id), &city, &country, 120);
                let (weak, city, country) = (Rc::downgrade(&state), city.clone(), country.clone());
                crate::collections::add_card(&flow, &card, &city.clone(), move || {
                    if let Some(state) = weak.upgrade() {
                        {
                            let mut filters = state.filters.borrow_mut();
                            filters.country = Some(country.clone()).filter(|country| !country.is_empty());
                            filters.state = None;
                            filters.city = Some(city.clone());
                        }
                        state.run(false);
                    }
                });
            }
        });
    }

    /// The filter sheet: changes apply when Search is pressed.
    fn edit_filters(self: &Rc<Self>) {
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let draft = Rc::new(RefCell::new(self.filters.borrow().clone()));
        let page = adw::PreferencesPage::new();

        // People: faces to pick, narrowed by name. A library can name hundreds: the first twelve show, in Immich's
        // order (favorites, then those in the most photos), with any already picked, and Show All unfolds the rest;
        // a name typed finds anyone. Only the faces shown are made, so their pictures are read as they show.
        let people_group = adw::PreferencesGroup::builder().title(tr("People")).build();
        let people_filter = gtk::SearchEntry::builder().placeholder_text(tr("Filter people by name")).build();
        let people = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).max_children_per_line(8).column_spacing(6).row_spacing(6).build();
        let more = gtk::Button::builder().css_classes(["flat"]).halign(gtk::Align::Center).margin_top(6).visible(false).build();
        people_group.add(&people_filter);
        people_group.add(&people);
        people_group.add(&more);
        page.add(&people_group);
        let everyone: Rc<RefCell<Vec<immich_api::Person>>> = Rc::default();
        let unfolded = Rc::new(Cell::new(false));
        let show_people: Rc<dyn Fn()> = {
            let (weak_people, weak_more, weak_filter) = (people.downgrade(), more.downgrade(), people_filter.downgrade());
            let (everyone, unfolded, chosen, textures) = (everyone.clone(), unfolded.clone(), draft.clone(), session.textures.clone());
            Rc::new(move || {
                let (Some(people), Some(more), Some(filter)) = (weak_people.upgrade(), weak_more.upgrade(), weak_filter.upgrade()) else { return };
                people.remove_all();
                let everyone = everyone.borrow();
                let wanted = filter.text().to_lowercase();
                let picked = |id: &str| chosen.borrow().people.iter().any(|(known, _)| known == id);
                for person in people_shown(&everyone, &wanted, unfolded.get(), picked) {
                    people.append(&person_toggle(person, &chosen, &textures));
                }
                more.set_visible(wanted.is_empty() && everyone.len() > FIRST_PEOPLE);
                more.set_label(&if unfolded.get() { tr("Show Fewer").to_owned() } else { tr("Show All {count} People").replace("{count}", &everyone.len().to_string()) });
            })
        };
        let again = show_people.clone();
        people_filter.connect_search_changed(move |_| again());
        let (again, flip) = (show_people.clone(), unfolded.clone());
        more.connect_clicked(move |_| {
            flip.set(!flip.get());
            again();
        });
        let client = session.connection.client.clone();
        crate::tasks::run(async move { client.people().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            let Ok(found) = outcome else { return };
            everyone.replace(found.into_iter().filter(|person| !person.name.is_empty() && !person.is_hidden).collect());
            show_people();
        });

        // Place and camera: each list narrowed by the one above it.
        let place = adw::PreferencesGroup::builder().title(tr("Location")).build();
        let camera = adw::PreferencesGroup::builder().title(tr("Camera")).build();
        let rows: Vec<(adw::ComboRow, SuggestionKind)> = vec![
            (combo(tr("Country")), SuggestionKind::Country),
            (combo(tr("State")), SuggestionKind::State),
            (combo(tr("City")), SuggestionKind::City),
            (combo(tr("Make")), SuggestionKind::CameraMake),
            (combo(tr("Model")), SuggestionKind::CameraModel),
            (combo(tr("Lens")), SuggestionKind::LensModel),
        ];
        for (index, (row, _)) in rows.iter().enumerate() {
            if index < 3 { place.add(row) } else { camera.add(row) }
        }
        page.add(&place);
        page.add(&camera);
        let rows = Rc::new(rows);
        let filling = Rc::new(Cell::new(false));
        for index in 0..rows.len() {
            self.fill_suggestions(&rows, index, &draft, &filling);
            let (all, chosen, filling, weak) = (rows.clone(), draft.clone(), filling.clone(), Rc::downgrade(self));
            rows[index].0.connect_selected_notify(move |row| {
                if filling.get() {
                    return;
                }
                let value = combo_value(row);
                {
                    let mut draft = chosen.borrow_mut();
                    match all[index].1 {
                        SuggestionKind::Country => {
                            draft.country = value;
                            draft.state = None;
                            draft.city = None;
                        }
                        SuggestionKind::State => {
                            draft.state = value;
                            draft.city = None;
                        }
                        SuggestionKind::City => draft.city = value,
                        SuggestionKind::CameraMake => {
                            draft.make = value;
                            draft.model = None;
                            draft.lens = None;
                        }
                        SuggestionKind::CameraModel => {
                            draft.model = value;
                            draft.lens = None;
                        }
                        _ => draft.lens = value,
                    }
                }
                // Those below it list again, within the new choice.
                let Some(state) = weak.upgrade() else { return };
                let below: &[usize] = match index {
                    0 => &[1, 2],
                    1 => &[2],
                    3 => &[4, 5],
                    4 => &[5],
                    _ => &[],
                };
                for lower in below {
                    state.fill_suggestions(&all, *lower, &chosen, &filling);
                }
            });
        }

        // Dates.
        let dates = adw::PreferencesGroup::builder().title(tr("Date Taken")).build();
        dates.add(&date_row(tr("After"), draft.clone(), |filters| &mut filters.taken_after));
        dates.add(&date_row(tr("Before"), draft.clone(), |filters| &mut filters.taken_before));
        page.add(&dates);

        // What to show.
        let display = adw::PreferencesGroup::builder().title(tr("Display")).build();
        let media = adw::ComboRow::builder().title(tr("Media Type")).model(&gtk::StringList::new(&[tr("All"), tr("Photos"), tr("Videos")])).build();
        media.set_selected(MediaType::ALL.iter().position(|kind| *kind == draft.borrow().media_type).unwrap_or(0) as u32);
        let chosen = draft.clone();
        media.connect_selected_notify(move |row| chosen.borrow_mut().media_type = MediaType::ALL.get(row.selected() as usize).copied().unwrap_or_default());
        display.add(&media);
        let switch = |title: &str, value: bool, set: fn(&mut Filters, bool)| {
            let row = adw::SwitchRow::builder().title(title).active(value).build();
            let chosen = draft.clone();
            row.connect_active_notify(move |row| set(&mut chosen.borrow_mut(), row.is_active()));
            row
        };
        let current = draft.borrow().clone();
        display.add(&switch(tr("Not in an Album"), current.not_in_album, |filters, on| filters.not_in_album = on));
        display.add(&switch(tr("Archived"), current.archived, |filters, on| filters.archived = on));
        display.add(&switch(tr("Favorites"), current.favorites, |filters, on| filters.favorites = on));
        let stars: Vec<String> = std::iter::once(tr("Any").to_owned()).chain((1..=5).map(|count| tr("{count} Stars").replace("{count}", &count.to_string()))).collect();
        let rating = adw::ComboRow::builder().title(tr("Rating")).model(&gtk::StringList::new(&stars.iter().map(String::as_str).collect::<Vec<_>>())).build();
        rating.set_selected(u32::from(current.rating.unwrap_or(0)));
        let chosen = draft.clone();
        rating.connect_selected_notify(move |row| chosen.borrow_mut().rating = Some(row.selected() as u8).filter(|stars| *stars > 0));
        display.add(&rating);
        page.add(&display);

        let reset = adw::ButtonRow::builder().title(tr("Reset Filters")).build();
        let reset_group = adw::PreferencesGroup::new();
        reset_group.add(&reset);
        page.add(&reset_group);

        let cancel = gtk::Button::with_label(tr("Cancel"));
        let apply = gtk::Button::builder().label(tr("Search")).css_classes(["suggested-action"]).build();
        let header = adw::HeaderBar::builder().show_start_title_buttons(false).show_end_title_buttons(false).build();
        header.pack_start(&cancel);
        header.pack_end(&apply);
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&page));
        let dialog = adw::Dialog::builder().title(tr("Search Filters")).content_width(560).content_height(720).child(&toolbar).build();
        let weak_dialog = dialog.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.close();
            }
        });
        let (weak_dialog, weak, chosen) = (dialog.downgrade(), Rc::downgrade(self), draft.clone());
        reset.connect_activated(move |_| {
            chosen.replace(Filters::default());
            if let (Some(dialog), Some(state)) = (weak_dialog.upgrade(), weak.upgrade()) {
                dialog.close();
                state.filters.replace(Filters::default());
                state.edit_filters();
            }
        });
        let (weak_dialog, weak) = (dialog.downgrade(), Rc::downgrade(self));
        apply.connect_clicked(move |_| {
            let (Some(dialog), Some(state)) = (weak_dialog.upgrade(), weak.upgrade()) else { return };
            let chosen = draft.borrow().clone();
            if let (Some(after), Some(before)) = (chosen.taken_after, chosen.taken_before) {
                if after > before {
                    if let Some(window) = state.window.upgrade() {
                        window.toast(tr("“After” is later than “Before”"));
                    }
                    return;
                }
            }
            state.filters.replace(chosen);
            dialog.close();
            state.run(false);
        });
        dialog.present(Some(&window));
    }

    /// List the values a row offers, within those chosen above it, and show its own choice.
    fn fill_suggestions(&self, rows: &Rc<Vec<(adw::ComboRow, SuggestionKind)>>, index: usize, draft: &Rc<RefCell<Filters>>, filling: &Rc<Cell<bool>>) {
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let filters = draft.borrow().clone();
        let kind = rows[index].1.clone();
        let query = SuggestionQuery { kind: kind.clone(), country: filters.country.clone(), state: filters.state.clone(), camera_make: filters.make.clone(), camera_model: filters.model.clone() };
        let chosen = match kind {
            SuggestionKind::Country => filters.country,
            SuggestionKind::State => filters.state,
            SuggestionKind::City => filters.city,
            SuggestionKind::CameraMake => filters.make,
            SuggestionKind::CameraModel => filters.model,
            _ => filters.lens,
        };
        let (client, weak_row, filling) = (session.connection.client.clone(), rows[index].0.downgrade(), filling.clone());
        crate::tasks::run(async move { client.suggestions(&query).await.unwrap_or_default() }, move |mut values| {
            let Some(row) = weak_row.upgrade() else { return };
            values.retain(|value| !value.is_empty());
            values.sort_by_key(|value| value.to_lowercase());
            let mut shown: Vec<String> = vec![tr("Any").to_owned()];
            shown.extend(values);
            if let Some(chosen) = chosen.as_ref().filter(|chosen| !shown.contains(chosen)) {
                shown.push(chosen.clone());
            }
            filling.set(true);
            row.set_model(Some(&gtk::StringList::new(&shown.iter().map(String::as_str).collect::<Vec<_>>())));
            row.set_selected(chosen.and_then(|chosen| shown.iter().position(|value| *value == chosen)).unwrap_or(0) as u32);
            filling.set(false);
        });
    }
}

fn combo(title: &str) -> adw::ComboRow {
    adw::ComboRow::builder().title(title).model(&gtk::StringList::new(&[tr("Any")])).enable_search(true).build()
}

/// The row's choice, `None` for Any (the first).
fn combo_value(row: &adw::ComboRow) -> Option<String> {
    if row.selected() == 0 {
        return None;
    }
    row.selected_item().and_downcast::<gtk::StringObject>().map(|item| item.string().to_string())
}

/// A date chosen on a calendar, or Any.
/// How many people the filters show before Show All.
const FIRST_PEOPLE: usize = 12;

/// The people the filters show: those whose name has `wanted` in it; else all of them, `unfolded`; else the first
/// twelve and any picked.
fn people_shown<'a>(everyone: &'a [immich_api::Person], wanted: &str, unfolded: bool, picked: impl Fn(&str) -> bool) -> Vec<&'a immich_api::Person> {
    if !wanted.is_empty() {
        return everyone.iter().filter(|person| person.name.to_lowercase().contains(wanted)).collect();
    }
    everyone.iter().enumerate().filter(|(index, person)| unfolded || *index < FIRST_PEOPLE || picked(&person.id)).map(|(_, person)| person).collect()
}

/// A person to pick in the filters: their face and name, pressed while picked.
fn person_toggle(person: &immich_api::Person, chosen: &Rc<RefCell<Filters>>, textures: &Rc<crate::textures::Textures>) -> gtk::FlowBoxChild {
    let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
    let frame = crate::collections::SquareFrame::new(48, &picture);
    frame.add_css_class("gallery-face");
    let weak_picture = picture.downgrade();
    textures.get(ImageKind::Person, &person.id, None, move |texture| {
        if let (Some(picture), Some(texture)) = (weak_picture.upgrade(), texture) {
            picture.set_paintable(Some(&texture));
        }
    });
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).build();
    content.append(&frame);
    content.append(&gtk::Label::builder().label(&person.name).ellipsize(gtk::pango::EllipsizeMode::End).max_width_chars(10).css_classes(["caption"]).build());
    let toggle = gtk::ToggleButton::builder().child(&content).css_classes(["flat"]).active(chosen.borrow().people.iter().any(|(id, _)| *id == person.id)).build();
    let (chosen, id, name) = (chosen.clone(), person.id.clone(), person.name.clone());
    toggle.connect_toggled(move |toggle| {
        let mut draft = chosen.borrow_mut();
        draft.people.retain(|(known, _)| *known != id);
        if toggle.is_active() {
            draft.people.push((id.clone(), name.clone()));
        }
    });
    gtk::FlowBoxChild::builder().child(&toggle).name(&person.name).build()
}

fn date_row(title: &str, draft: Rc<RefCell<Filters>>, field: fn(&mut Filters) -> &mut Option<NaiveDate>) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(title).build();
    let shown = |date: Option<NaiveDate>| date.map_or_else(|| tr("Any").to_owned(), |date| date.format("%Y-%m-%d").to_string());
    let button = gtk::MenuButton::builder().label(shown(*field(&mut draft.borrow_mut()))).valign(gtk::Align::Center).build();
    let calendar = gtk::Calendar::new();
    if let Some(date) = *field(&mut draft.borrow_mut()) {
        if let Ok(date) = glib::DateTime::from_local(date.year(), date.month() as i32, date.day() as i32, 0, 0, 0.0) {
            calendar.select_day(&date);
        }
    }
    let clear = gtk::Button::builder().label(tr("Any Date")).css_classes(["flat"]).build();
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).build();
    content.append(&calendar);
    content.append(&clear);
    let popover = gtk::Popover::builder().child(&content).build();
    button.set_popover(Some(&popover));
    let (chosen, weak_button) = (draft.clone(), button.downgrade());
    calendar.connect_day_selected(move |calendar| {
        let date = calendar.date();
        let picked = NaiveDate::from_ymd_opt(date.year(), date.month() as u32, date.day_of_month() as u32);
        *field(&mut chosen.borrow_mut()) = picked;
        if let Some(button) = weak_button.upgrade() {
            button.set_label(&shown(picked));
        }
    });
    let (weak_button, weak_popover) = (button.downgrade(), popover.downgrade());
    clear.connect_clicked(move |_| {
        *field(&mut draft.borrow_mut()) = None;
        if let Some(button) = weak_button.upgrade() {
            button.set_label(tr("Any"));
        }
        if let Some(popover) = weak_popover.upgrade() {
            popover.popdown();
        }
    });
    row.add_suffix(&button);
    row
}

#[cfg(test)]
mod people_tests {
    use super::*;

    fn people(count: usize) -> Vec<immich_api::Person> {
        (1..=count)
            .map(|number| serde_json::from_value(serde_json::json!({"id": format!("p{number}"), "name": format!("Person {number}"), "isHidden": false, "isFavorite": false, "thumbnailPath": ""})).unwrap())
            .collect()
    }

    #[test]
    fn twelve_show_with_the_picked_and_show_all_shows_everyone() {
        let everyone = people(20);
        let names = |shown: Vec<&immich_api::Person>| shown.iter().map(|person| person.id.clone()).collect::<Vec<_>>();
        let folded = names(people_shown(&everyone, "", false, |_| false));
        assert_eq!(folded.len(), 12);
        assert_eq!(folded.last().map(String::as_str), Some("p12"));
        // One picked beyond the twelve stays in sight.
        let with_picked = names(people_shown(&everyone, "", false, |id| id == "p17"));
        assert_eq!((with_picked.len(), with_picked.last().map(String::as_str)), (13, Some("p17")));
        assert_eq!(people_shown(&everyone, "", true, |_| false).len(), 20);
        // A name typed finds anyone, folded or not.
        assert_eq!(names(people_shown(&everyone, "person 19", false, |_| false)), ["p19"]);
    }
}
