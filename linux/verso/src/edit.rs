//! Editing what photos say about themselves: when they were taken, shifted or set on the clock where each was taken,
//! and where, found by name or by a click on the map.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use chrono::NaiveDateTime;
use verso_desktop::{actions, dates, map};
use verso_linux::i18n::tr;
use shumate::prelude::*;

use crate::window::Window;

/// Adjust when `ids` were taken (`dates`): shift each by an amount, earlier or later, or set them all to one date, each
/// on its own clock. `first` is the first photo's date, for the preview and as the date to start from; `done` runs once
/// Immich has them all.
pub fn adjust_dates(window: &Window, ids: Vec<String>, first: Option<NaiveDateTime>, done: impl Fn() + 'static) {
    if ids.is_empty() {
        return;
    }
    let count = ids.len();
    let dialog = adw::Dialog::builder().title(tr("Adjust Date and Time")).content_width(460).build();
    let page = adw::PreferencesPage::new();
    let modes = adw::ToggleGroup::builder().halign(gtk::Align::Center).build();
    modes.add(adw::Toggle::builder().name("shift").label(tr("Shift")).build());
    modes.add(adw::Toggle::builder().name("set").label(tr("Set To")).build());
    modes.set_active_name(Some("shift"));
    let intro = adw::PreferencesGroup::new();
    intro.add(&modes);
    page.add(&intro);

    // Shift: earlier or later, by each part.
    let shift_group = adw::PreferencesGroup::new();
    let direction = adw::ToggleGroup::builder().valign(gtk::Align::Center).build();
    direction.add(adw::Toggle::builder().name("earlier").label(tr("Earlier")).build());
    direction.add(adw::Toggle::builder().name("later").label(tr("Later")).build());
    direction.set_active_name(Some("later"));
    let direction_row = adw::ActionRow::builder().title(tr("Direction")).build();
    direction_row.add_suffix(&direction);
    shift_group.add(&direction_row);
    let part = |title: &str, upper: f64| {
        let row = adw::SpinRow::with_range(0.0, upper, 1.0);
        row.set_title(title);
        row
    };
    let years = part(tr("Years"), 500.0);
    let months = part(tr("Months"), 6000.0);
    let days = part(tr("Days"), 200_000.0);
    let hours = part(tr("Hours"), 1_000_000.0);
    let minutes = part(tr("Minutes"), 1_000_000.0);
    let seconds = part(tr("Seconds"), 1_000_000.0);
    for row in [&years, &months, &days, &hours, &minutes, &seconds] {
        shift_group.add(row);
    }
    page.add(&shift_group);

    // Set To: one date and time for them all.
    let set_group = adw::PreferencesGroup::builder().visible(false).build();
    let when = adw::EntryRow::builder().title(tr("Date and Time, as 2024-03-15 14:32")).text(first.map(|first| first.format("%Y-%m-%d %H:%M:%S").to_string()).unwrap_or_default()).build();
    set_group.add(&when);
    page.add(&set_group);

    // The first photo, before and after: the change as it will be made.
    let preview_group = adw::PreferencesGroup::new();
    let preview = adw::ActionRow::builder().title(if count == 1 { tr("The Photo") } else { tr("The First Photo") }).css_classes(["property"]).build();
    preview_group.add(&preview);
    page.add(&preview_group);

    let apply = gtk::Button::builder().label(tr("_Adjust")).use_underline(true).css_classes(["suggested-action"]).sensitive(false).build();
    let header = adw::HeaderBar::new();
    header.pack_end(&apply);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&page));
    dialog.set_child(Some(&toolbar));

    // The change as the dialog has it now, if it is one.
    let read: Rc<dyn Fn() -> Option<dates::Change>> = {
        let (modes, direction, when) = (modes.clone(), direction.clone(), when.clone());
        let parts = [years.clone(), months.clone(), days.clone(), hours.clone(), minutes.clone(), seconds.clone()];
        Rc::new(move || {
            if modes.active_name().as_deref() == Some("set") {
                return actions::parse_taken(&when.text()).map(dates::Change::Set);
            }
            let value = |row: &adw::SpinRow| row.value().max(0.0) as u32;
            let amount = dates::Amount {
                years: value(&parts[0]),
                months: value(&parts[1]),
                days: value(&parts[2]),
                hours: value(&parts[3]),
                minutes: value(&parts[4]),
                seconds: value(&parts[5]),
            };
            let shift = dates::Shift::new(amount, direction.active_name().as_deref() == Some("earlier"));
            (!shift.is_none()).then_some(dates::Change::Shift(shift))
        })
    };
    let refresh: Rc<dyn Fn()> = {
        let (read, modes, shift_group, set_group, preview, apply, intro) = (read.clone(), modes.clone(), shift_group.clone(), set_group.clone(), preview.clone(), apply.clone(), intro.clone());
        Rc::new(move || {
            let setting = modes.active_name().as_deref() == Some("set");
            intro.set_description(Some(&match (count, setting) {
                (1, _) => tr("On the clock where the photo was taken.").to_owned(),
                (_, false) => tr("Each of the {count} photos moves by the same amount, on the clock where it was taken.").replace("{count}", &count.to_string()),
                (_, true) => tr("Each of the {count} photos gets this date and time, on the clock where it was taken.").replace("{count}", &count.to_string()),
            }));
            shift_group.set_visible(!setting);
            set_group.set_visible(setting);
            let change = read();
            apply.set_sensitive(change.is_some());
            let format = |when: NaiveDateTime| when.format("%Y-%m-%d %H:%M:%S").to_string();
            preview.set_subtitle(&match (first, change) {
                (Some(first), Some(change)) => match change.applied(first) {
                    Some(after) => format!("{}  →  {}", format(first), format(after)),
                    None => tr("That date is beyond the calendar").to_owned(),
                },
                (Some(first), None) => format(first),
                (None, _) => String::new(),
            });
        })
    };
    refresh();
    let again = refresh.clone();
    modes.connect_active_name_notify(move |_| again());
    let again = refresh.clone();
    direction.connect_active_name_notify(move |_| again());
    for row in [&years, &months, &days, &hours, &minutes, &seconds] {
        let again = refresh.clone();
        row.connect_value_notify(move |_| again());
    }
    let again = refresh.clone();
    when.connect_changed(move |_| again());

    let (weak_window, weak_dialog, done) = (window.downgrade(), dialog.downgrade(), Rc::new(done));
    apply.connect_clicked(move |button| {
        let (Some(window), Some(change)) = (weak_window.upgrade(), read()) else { return };
        let Some(session) = window.session() else { return };
        button.set_sensitive(false);
        let (client, ids, shown, done, weak_dialog) = (session.connection.client.clone(), ids.clone(), window.clone(), done.clone(), weak_dialog.clone());
        crate::tasks::run(async move { dates::change_taken(&client, ids, change).await }, move |outcome| {
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.close();
            }
            match outcome.failed {
                None => shown.toast(&if outcome.changed == 1 { tr("Date changed").to_owned() } else { tr("Changed the date of {count} photos").replace("{count}", &outcome.changed.to_string()) }),
                Some((message, failed)) => shown.toast(
                    &tr("Changed {changed}; {failed} could not be changed: {message}")
                        .replace("{changed}", &outcome.changed.to_string())
                        .replace("{failed}", &failed.to_string())
                        .replace("{message}", &message),
                ),
            }
            done();
        });
    });
    dialog.present(Some(window));
}

/// Choose a place, by name or on the map, then set it for `ids`; `done` runs once Immich has it.
pub fn edit_place(window: &Window, ids: Vec<String>, start: Option<(f64, f64)>, done: impl Fn() + 'static) {
    let dialog = adw::Dialog::builder().title(tr("Set the Place")).content_width(560).content_height(620).build();
    let search = gtk::SearchEntry::builder().placeholder_text(tr("Search for a place")).hexpand(true).build();
    let results = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).visible(false).build();
    let simple = shumate::SimpleMap::builder().vexpand(true).height_request(320).build();
    let registry = shumate::MapSourceRegistry::with_defaults();
    if let Some(source) = registry.by_id(shumate::MAP_SOURCE_OSM_MAPNIK) {
        simple.set_map_source(Some(&source));
    }
    let chosen: Rc<Cell<Option<(f64, f64)>>> = Rc::new(Cell::new(start));
    let pin = shumate::Marker::new();
    pin.set_child(Some(&gtk::Image::builder().icon_name("mark-location-symbolic").pixel_size(32).css_classes(["accent"]).build()));
    let set_button = gtk::Button::builder().label(tr("_Set")).use_underline(true).css_classes(["suggested-action"]).sensitive(start.is_some()).build();
    let caption = gtk::Label::builder().xalign(0.0).css_classes(["dim-label", "caption"]).label(tr("Search for a place, or click on the map.")).build();
    if let (Some(map_widget), Some(viewport)) = (simple.map(), simple.viewport()) {
        let layer = shumate::MarkerLayer::new(&viewport);
        map_widget.add_layer(&layer);
        layer.add_marker(&pin);
        pin.set_visible(start.is_some());
        let (latitude, longitude) = start.unwrap_or((30.0, 10.0));
        viewport.set_zoom_level(if start.is_some() { 12.0 } else { 2.0 });
        map_widget.center_on(latitude, longitude);
        pin.set_location(latitude, longitude);
        // A click sets the place where it lands.
        let click = gtk::GestureClick::new();
        let (weak_map, weak_viewport, weak_pin, place, weak_set) = (map_widget.downgrade(), viewport.downgrade(), pin.downgrade(), chosen.clone(), set_button.downgrade());
        click.connect_released(move |gesture, presses, x, y| {
            let (Some(map_widget), Some(viewport), Some(pin), Some(set)) = (weak_map.upgrade(), weak_viewport.upgrade(), weak_pin.upgrade(), weak_set.upgrade()) else { return };
            if presses > 1 || gesture.current_button() != gtk::gdk::BUTTON_PRIMARY {
                return;
            }
            let (dx, dy) = (x - f64::from(map_widget.width()) / 2.0, y - f64::from(map_widget.height()) / 2.0);
            let (latitude, longitude) = map::location_at(viewport.latitude(), viewport.longitude(), viewport.zoom_level(), dx, dy);
            pin.set_location(latitude, longitude);
            pin.set_visible(true);
            place.set(Some((latitude, longitude)));
            set.set_sensitive(true);
        });
        map_widget.add_controller(click);
    }
    // Places by name, from Immich's own list.
    let found: Rc<RefCell<Vec<immich_api::PlaceMatch>>> = Rc::default();
    let (weak_window, weak_results, places) = (window.downgrade(), results.downgrade(), found.clone());
    search.connect_activate(move |entry| {
        let (Some(window), Some(results)) = (weak_window.upgrade(), weak_results.upgrade()) else { return };
        let Some(session) = window.session() else { return };
        let (client, name) = (session.connection.client.clone(), entry.text().trim().to_owned());
        if name.is_empty() {
            return;
        }
        let (weak_results, places) = (results.downgrade(), places.clone());
        crate::tasks::run(async move { client.search_places(&name).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            let Some(results) = weak_results.upgrade() else { return };
            results.remove_all();
            let matches = outcome.unwrap_or_default();
            results.set_visible(!matches.is_empty());
            for place in matches.iter().take(6) {
                let detail = [place.district.as_deref(), place.region.as_deref()].into_iter().flatten().collect::<Vec<_>>().join(", ");
                results.append(&adw::ActionRow::builder().title(glib::markup_escape_text(&place.name)).subtitle(glib::markup_escape_text(&detail)).activatable(true).build());
            }
            places.replace(matches);
        });
    });
    let (weak_map, weak_pin, place, weak_set) = (simple.downgrade(), pin.downgrade(), chosen.clone(), set_button.downgrade());
    results.connect_row_activated(move |_, row| {
        let Some(found) = found.borrow().get(row.index() as usize).cloned() else { return };
        let (Some(simple), Some(pin), Some(set)) = (weak_map.upgrade(), weak_pin.upgrade(), weak_set.upgrade()) else { return };
        if let (Some(map_widget), Some(viewport)) = (simple.map(), simple.viewport()) {
            viewport.set_zoom_level(12.0);
            map_widget.center_on(found.latitude, found.longitude);
        }
        pin.set_location(found.latitude, found.longitude);
        pin.set_visible(true);
        place.set(Some((found.latitude, found.longitude)));
        set.set_sensitive(true);
    });
    let done = Rc::new(done);
    let (weak_window, weak_dialog) = (window.downgrade(), dialog.downgrade());
    set_button.connect_clicked(move |_| {
        let (Some(window), Some((latitude, longitude))) = (weak_window.upgrade(), chosen.get()) else { return };
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
        let Some(session) = window.session() else { return };
        let (client, ids, shown, done) = (session.connection.client.clone(), ids.clone(), window.clone(), done.clone());
        crate::tasks::run(async move { actions::set_place(&client, ids, latitude, longitude).await }, move |outcome| match outcome {
            Ok(()) => {
                shown.toast(tr("Place changed"));
                done();
            }
            Err(message) => shown.toast(&message),
        });
    });
    let header = adw::HeaderBar::builder().show_end_title_buttons(false).show_start_title_buttons(false).build();
    let cancel = gtk::Button::builder().label(tr("_Cancel")).use_underline(true).build();
    let weak_dialog = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
    });
    header.pack_start(&cancel);
    header.pack_end(&set_button);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
    content.append(&search);
    content.append(&results);
    content.append(&simple);
    content.append(&caption);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&content));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(window));
    search.grab_focus();
}
