//! A photo's details, as the Mac gallery's inspector has them: when and where it was taken (both editable), its file
//! and camera, its description and rating (edited in place), the people in it as faces, a map of where it was taken,
//! its albums and tags. The viewer shows them below the photo, and the photo pages beside the grid for the photo
//! selected (`InfoPanel`).

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::asset_info::AssetDetails;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::{actions, text};
use shumate::prelude::*;
use verso_linux::i18n::tr;

use crate::window::Window;

/// The info pane for a photo read whole; `reload` runs after an edit, to read it again.
pub fn info_page(window: &Window, details: &AssetDetails, albums: &[immich_api::Album], reload: Rc<dyn Fn()>) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();
    for group in info_groups(window, details, albums, false, reload) {
        page.add(&group);
    }
    page
}

/// The details as groups, for a page of their own or, `below_photo`, below the photo in the viewer, where the people
/// and the place come first, as the Mac gallery has them there (after Photos).
pub fn info_groups(window: &Window, details: &AssetDetails, albums: &[immich_api::Album], below_photo: bool, reload: Rc<dyn Fn()>) -> Vec<adw::PreferencesGroup> {
    let mut page: Vec<adw::PreferencesGroup> = Vec::new();
    let mut first: Vec<adw::PreferencesGroup> = Vec::new();
    let about = adw::PreferencesGroup::new();
    let row = |title: &str, value: &str| {
        let row = adw::ActionRow::builder().title(title).subtitle(glib::markup_escape_text(value)).css_classes(["property"]).build();
        row.set_subtitle_selectable(true);
        row
    };
    let when = details.local_date_time.unwrap_or_else(|| details.file_created_at.naive_utc());
    let zone = details.exif.as_ref().and_then(|exif| exif.time_zone.clone()).unwrap_or_default();
    let taken_row = row(tr("Taken"), format!("{} {}", text::taken(when), zone).trim());
    let edit_taken = gtk::Button::builder().icon_name("document-edit-symbolic").tooltip_text(tr("Change the Date")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    let (weak_window, shown_details, again) = (window.downgrade(), details.clone(), reload.clone());
    edit_taken.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let again = again.clone();
        let first = shown_details.local_date_time.or_else(|| Some(shown_details.file_created_at.naive_utc()));
        crate::edit::adjust_dates(&window, vec![shown_details.id.clone()], first, move || again());
    });
    taken_row.add_suffix(&edit_taken);
    about.add(&taken_row);
    about.add(&row(tr("File"), &details.original_file_name));
    let mut size = Vec::new();
    if let (Some(width), Some(height)) = (details.width, details.height) {
        size.push(format!("{width} × {height}"));
    }
    if let Some(bytes) = details.exif.as_ref().and_then(|exif| exif.file_size) {
        size.push(text::size(bytes));
    }
    if let Some(duration) = details.duration_ms.filter(|duration| *duration > 0) {
        size.push(text::duration(duration));
    }
    if !size.is_empty() {
        about.add(&row(tr("Size"), &size.join(" · ")));
    }
    if let Some(exif) = &details.exif {
        let camera = [exif.make.as_deref(), exif.model.as_deref()].into_iter().flatten().collect::<Vec<_>>().join(" ");
        if !camera.is_empty() {
            about.add(&row(tr("Camera"), &camera));
        }
        if let Some(lens) = exif.lens_model.as_deref().filter(|lens| !lens.is_empty()) {
            about.add(&row(tr("Lens"), lens));
        }
        let mut exposure = Vec::new();
        if let Some(f_number) = exif.f_number {
            exposure.push(format!("ƒ/{f_number:.1}"));
        }
        if let Some(time) = exif.exposure_time.as_deref() {
            exposure.push(format!("{time} s"));
        }
        if let Some(focal) = exif.focal_length {
            exposure.push(format!("{focal:.0} mm"));
        }
        if let Some(iso) = exif.iso {
            exposure.push(format!("ISO {iso}"));
        }
        if !exposure.is_empty() {
            about.add(&row(tr("Exposure"), &exposure.join(" · ")));
        }
        let place = [exif.city.as_deref(), exif.state.as_deref(), exif.country.as_deref()].into_iter().flatten().collect::<Vec<_>>().join(", ");
        let edit_place = gtk::Button::builder().icon_name("document-edit-symbolic").tooltip_text(tr("Set the Place")).valign(gtk::Align::Center).css_classes(["flat"]).build();
        let (weak_window, id, start, again) = (window.downgrade(), details.id.clone(), exif.latitude.zip(exif.longitude), reload.clone());
        edit_place.connect_clicked(move |_| {
            let Some(window) = weak_window.upgrade() else { return };
            let again = again.clone();
            crate::edit::edit_place(&window, vec![id.clone()], start, move || again());
        });
        if let (Some(latitude), Some(longitude)) = (exif.latitude, exif.longitude) {
            let place_row = row(tr("Location"), if place.is_empty() { tr("On the map") } else { &place });
            let map = gtk::Button::builder().icon_name("mark-location-symbolic").tooltip_text(tr("Show on a Map")).valign(gtk::Align::Center).css_classes(["flat"]).build();
            let weak_window = window.downgrade();
            map.connect_clicked(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    gtk::UriLauncher::new(&format!("geo:{latitude},{longitude}")).launch(Some(&window), gio::Cancellable::NONE, |_| {});
                }
            });
            place_row.add_suffix(&map);
            place_row.add_suffix(&edit_place);
            about.add(&place_row);
        } else {
            let place_row = row(tr("Location"), if place.is_empty() { tr("None") } else { &place });
            place_row.add_suffix(&edit_place);
            about.add(&place_row);
        }
    }
    page.push(about);

    // Description and rating, edited in place.
    let edits = adw::PreferencesGroup::new();
    let description = adw::EntryRow::builder().title(tr("Description")).show_apply_button(true).text(details.exif.as_ref().and_then(|exif| exif.description.clone()).unwrap_or_default()).build();
    let (weak_window, id) = (window.downgrade(), details.id.clone());
    description.connect_apply(move |entry| {
        let Some(session) = weak_window.upgrade().and_then(|window| window.session()) else { return };
        let (client, id, text) = (session.connection.client.clone(), id.clone(), entry.text().trim().to_owned());
        let weak_window = weak_window.clone();
        crate::tasks::run(async move { actions::set_description(&client, id, text).await }, move |outcome| {
            if let (Some(window), Err(message)) = (weak_window.upgrade(), outcome) {
                window.toast(&message);
            }
        });
    });
    edits.add(&description);
    let rating_row = adw::ActionRow::builder().title(tr("Rating")).build();
    let stars = gtk::Box::builder().spacing(0).valign(gtk::Align::Center).build();
    let current = rating_of(details);
    let buttons: Rc<RefCell<Vec<gtk::Button>>> = Rc::default();
    for star in 1..=5i8 {
        let button = gtk::Button::builder().icon_name(if current.is_some_and(|rating| rating >= star) { "starred-symbolic" } else { "non-starred-symbolic" }).css_classes(["flat", "circular"]).tooltip_text(tr("{count} Stars").replace("{count}", &star.to_string())).build();
        let (weak_window, id, all) = (window.downgrade(), details.id.clone(), buttons.clone());
        button.connect_clicked(move |_| {
            let Some(session) = weak_window.upgrade().and_then(|window| window.session()) else { return };
            let lit = all.borrow().iter().filter(|button| button.icon_name().as_deref() == Some("starred-symbolic")).count() as i8;
            // Clicking the highest lit star again clears the rating.
            let rating = if lit == star { None } else { Some(star) };
            for (index, button) in all.borrow().iter().enumerate() {
                button.set_icon_name(if rating.is_some_and(|rating| rating > index as i8) { "starred-symbolic" } else { "non-starred-symbolic" });
            }
            let (client, id) = (session.connection.client.clone(), id.clone());
            let weak_window = weak_window.clone();
            crate::tasks::run(async move { actions::set_rating(&client, id, rating).await }, move |outcome| {
                if let (Some(window), Err(message)) = (weak_window.upgrade(), outcome) {
                    window.toast(&message);
                }
            });
        });
        stars.append(&button);
        buttons.borrow_mut().push(button);
    }
    rating_row.add_suffix(&stars);
    edits.add(&rating_row);
    page.push(edits);

    // Where it was taken, on a map.
    if let Some((latitude, longitude)) = details.exif.as_ref().and_then(|exif| exif.latitude.zip(exif.longitude)) {
        if let Some(map) = place_map(latitude, longitude) {
            let group = adw::PreferencesGroup::builder().title(tr("Place")).build();
            group.add(&map);
            if below_photo {
                first.push(group);
            } else {
                page.push(group);
            }
        }
    }

    // People as faces, albums and tags, each opening its page.
    let named: Vec<&immich_api::Person> = details.people.iter().filter(|person| !person.name.is_empty() && !person.is_hidden).collect();
    if let (false, Some(session)) = (named.is_empty(), window.session()) {
        let people = adw::PreferencesGroup::builder().title(tr("People")).build();
        let faces = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).activate_on_single_click(true).homogeneous(true).max_children_per_line(8).row_spacing(12).column_spacing(12).build();
        for person in named {
            let face = crate::collections::card(&session.textures, ImageKind::Person, Some(&person.id), &person.name, "", 72);
            let child = gtk::FlowBoxChild::builder().child(&face).tooltip_text(&person.name).build();
            faces.append(&child);
            let (weak_window, id, name, weak_child) = (window.downgrade(), person.id.clone(), person.name.clone(), child.downgrade());
            faces.connect_child_activated(move |_, activated| {
                if weak_child.upgrade().as_ref() != Some(activated) {
                    return;
                }
                if let Some(window) = weak_window.upgrade() {
                    window.close_viewer();
                    window.open_person(&id, &name);
                }
            });
        }
        people.add(&faces);
        if below_photo {
            first.insert(0, people);
        } else {
            page.push(people);
        }
    }
    if !albums.is_empty() {
        let group = adw::PreferencesGroup::builder().title(tr("Albums")).build();
        for album in albums {
            let row = adw::ActionRow::builder().title(glib::markup_escape_text(&album.name)).subtitle(text::items(album.asset_count)).activatable(true).build();
            row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
            let (weak_window, id, name) = (window.downgrade(), album.id.clone(), album.name.clone());
            row.connect_activated(move |_| {
                if let Some(window) = weak_window.upgrade() {
                    window.close_viewer();
                    window.open_album(&id, &name);
                }
            });
            group.add(&row);
        }
        page.push(group);
    }
    if !details.tags.is_empty() {
        let group = adw::PreferencesGroup::builder().title(tr("Tags")).build();
        for tag in &details.tags {
            group.add(&adw::ActionRow::builder().title(glib::markup_escape_text(&tag.value)).build());
        }
        page.push(group);
    }
    first.extend(page);
    first
}

/// A small map of where a photo was taken, with a pin.
fn place_map(latitude: f64, longitude: f64) -> Option<gtk::Widget> {
    let simple = shumate::SimpleMap::new();
    if let Some(source) = shumate::MapSourceRegistry::with_defaults().by_id(shumate::MAP_SOURCE_OSM_MAPNIK) {
        simple.set_map_source(Some(&source));
    }
    let (map, viewport) = (simple.map()?, simple.viewport()?);
    viewport.set_zoom_level(12.0);
    map.center_on(latitude, longitude);
    let pins = shumate::MarkerLayer::new(&viewport);
    let pin = shumate::Marker::new();
    pin.set_child(Some(&gtk::Image::builder().icon_name("mark-location-symbolic").pixel_size(32).css_classes(["accent"]).build()));
    pin.set_location(latitude, longitude);
    pins.add_marker(&pin);
    map.add_layer(&pins);
    simple.set_show_zoom_buttons(false);
    // A picture of the place: it takes no scrolling or dragging, so the page scrolls past it (the Location row's map
    // button opens a full map).
    simple.set_can_target(false);
    let frame = gtk::Frame::builder().child(&simple).height_request(220).css_classes(["gallery-place-map"]).build();
    Some(frame.upcast())
}

fn rating_of(details: &AssetDetails) -> Option<i8> {
    details.exif.as_ref().and_then(|exif| exif.rating).filter(|rating| (1..=5).contains(rating))
}

/// The details of the photo selected on a photo page, in a panel beside the grid: "No Selection", "3 Selected", or
/// the one photo's details, read when it is chosen.
pub struct InfoPanel {
    window: glib::WeakRef<Window>,
    stack: gtk::Stack,
    status: adw::StatusPage,
    holder: gtk::ScrolledWindow,
    shown: RefCell<Option<String>>,
}

impl InfoPanel {
    pub fn new(window: &Window) -> Rc<InfoPanel> {
        let status = adw::StatusPage::builder().icon_name("image-x-generic-symbolic").title(tr("No Selection")).css_classes(["compact"]).build();
        let holder = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
        let stack = gtk::Stack::builder().width_request(280).build();
        stack.add_named(&status, Some("status"));
        stack.add_named(&holder, Some("details"));
        Rc::new(InfoPanel { window: window.downgrade(), stack, status, holder, shown: RefCell::default() })
    }

    pub fn widget(&self) -> &gtk::Stack {
        &self.stack
    }

    /// Show the selection: nothing, several, or one photo's details.
    pub fn show(self: &Rc<Self>, ids: &[String]) {
        match ids {
            [] => self.status_page(tr("No Selection"), ""),
            [id] => {
                if self.shown.borrow().as_deref() != Some(id.as_str()) {
                    self.load(id.clone());
                }
            }
            many => self.status_page(&tr("{count} Selected").replace("{count}", &many.len().to_string()), tr("Select one photo to see its details.")),
        }
    }

    fn status_page(&self, title: &str, description: &str) {
        self.shown.replace(None);
        self.status.set_title(title);
        self.status.set_description(Some(description).filter(|text| !text.is_empty()));
        self.stack.set_visible_child_name("status");
    }

    fn load(self: &Rc<Self>, id: String) {
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        self.shown.replace(Some(id.clone()));
        let client = session.connection.client.clone();
        let weak = Rc::downgrade(self);
        let asked = id.clone();
        crate::tasks::run(
            async move {
                let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let filter = immich_api::AlbumFilter { containing_asset: Some(id.clone()), ..immich_api::AlbumFilter::default() };
                let albums = client.albums_where(&filter).await.unwrap_or_default();
                Ok::<_, String>((details, albums))
            },
            move |outcome| {
                let Some(panel) = weak.upgrade() else { return };
                // Only while that photo is still the one selected.
                if panel.shown.borrow().as_deref() != Some(asked.as_str()) {
                    return;
                }
                let Some(window) = panel.window.upgrade() else { return };
                match outcome {
                    Ok((details, albums)) => {
                        // After an edit, Immich writes the new date or place a moment after it answers: read again
                        // then, and the grids too, where a new date moves the photo.
                        let again = Rc::downgrade(&panel);
                        let reload: Rc<dyn Fn()> = Rc::new(move || {
                            let again = again.clone();
                            glib::timeout_add_local_once(std::time::Duration::from_millis(2500), move || {
                                let Some(panel) = again.upgrade() else { return };
                                let Some(id) = panel.shown.replace(None) else { return };
                                panel.load(id);
                                if let Some(window) = panel.window.upgrade() {
                                    window.reload_grids();
                                }
                            });
                        });
                        panel.holder.set_child(Some(&info_page(&window, &details, &albums, reload)));
                        panel.stack.set_visible_child_name("details");
                    }
                    Err(message) => panel.status_page(tr("Couldn't Load Info"), &message),
                }
            },
        );
    }
}
