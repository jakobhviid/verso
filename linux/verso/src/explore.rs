//! The pages for finding photos: search, places, memories, tags and the server's folders; sharing (shared links,
//! partners); and the utilities (duplicates, large files).

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::search::AssetQuery;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Source;
use verso_desktop::arrangement::GridPage;
use verso_desktop::{places, settings};
use verso_core::links::ImmichItem;
use verso_linux::i18n::tr;

use crate::collections::{add_card, card_page, item_actions};
use crate::pages::{self, Kind, Spec};
use crate::window::Window;

// --- Search ---



// --- Places ---

pub fn places_page(window: &Window) -> adw::NavigationPage {
    let cards = card_page(tr("Places"), tr("No Places"), "mark-location-symbolic");
    cards.page.add_css_class("verso-card-page");
    cards.header.pack_start(&crate::cards::zoom_buttons());
    // Cities, or countries, each opening its cities (the Mac gallery's and Immich's grouping), remembered.
    let modes = adw::ToggleGroup::new();
    modes.add(adw::Toggle::builder().name("None").label(tr("Cities")).build());
    modes.add(adw::Toggle::builder().name("Country").label(tr("Countries")).build());
    let by_country = settings::shared().get("places.groupBy").as_deref() == Some("Country");
    modes.set_active_name(Some(if by_country { "Country" } else { "None" }));
    cards.header.set_title_widget(Some(&modes));
    let Some(session) = window.session() else { return cards.page };
    let client = session.connection.client.clone();
    let places: Rc<RefCell<Vec<places::Place>>> = Rc::default();
    let render = {
        let (weak_window, flow, stack, places, weak_modes) = (window.downgrade(), cards.flow.clone(), cards.stack.clone(), places.clone(), modes.downgrade());
        Rc::new(move || {
            let (Some(window), Some(modes)) = (weak_window.upgrade(), weak_modes.upgrade()) else { return };
            while let Some(child) = flow.first_child() {
                flow.remove(&child);
            }
            let places = places.borrow();
            stack.set_visible_child_name(if places.is_empty() { "empty" } else { "cards" });
            // Countries as cards; cities, often many, as square tiles, as People's faces.
            let by_country = modes.active_name().as_deref() == Some("Country");
            if by_country {
                flow.set_max_children_per_line(5);
                flow.remove_css_class("verso-faces");
                flow.add_css_class("verso-cards");
                for country in places::countries(&places) {
                    add_country_card(&window, &flow, country);
                }
            } else {
                city_flow(&flow);
                for place in places.iter() {
                    add_city_card(&window, &flow, place, true);
                }
            }
        })
    };
    let again = render.clone();
    modes.connect_active_name_notify(move |modes| {
        settings::shared().set("places.groupBy", Some(modes.active_name().as_deref().unwrap_or("None")));
        again();
    });
    let (weak_window, read) = (window.downgrade(), places.clone());
    crate::tasks::run(async move { client.city_assets().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let Some(window) = weak_window.upgrade() else { return };
        match outcome {
            Ok(assets) => {
                let mut found: Vec<places::Place> = assets
                    .iter()
                    .filter_map(|details| {
                        let exif = details.exif.as_ref()?;
                        let city = exif.city.clone().filter(|city| !city.is_empty())?;
                        Some(places::Place { city, country: exif.country.clone().unwrap_or_default(), photo_id: details.id.clone() })
                    })
                    .collect();
                found.sort_by_key(|place| place.city.to_lowercase());
                read.replace(found);
                render();
            }
            Err(message) => window.load_failed(&message),
        }
    });
    cards.page
}

/// A flow of cities: square tiles, as many on a line as fit, as People's faces.
fn city_flow(flow: &gtk::FlowBox) {
    flow.set_max_children_per_line(20);
    flow.remove_css_class("verso-cards");
    flow.add_css_class("verso-faces");
}

/// A city as a square tile: its photo, its name on it, and its country under the name where cities of several
/// countries show (`with_country`); it opens the city's photos.
fn add_city_card(window: &Window, flow: &gtk::FlowBox, place: &places::Place, with_country: bool) {
    let Some(session) = window.session() else { return };
    let picture = crate::cards::picture(&session.textures, ImageKind::Thumbnail, &place.photo_id);
    let (tile, _) = crate::cards::square_tile(&picture, &place.city, with_country.then_some(place.country.as_str()));
    let (weak_window, city, country) = (window.downgrade(), place.city.clone(), place.country.clone());
    add_card(flow, &tile, &format!("{} {}", place.city, place.country), move || {
        if let Some(window) = weak_window.upgrade() {
            window.push_page(&place_page(&window, Some(city.clone()), Some(country.clone()).filter(|country| !country.is_empty())));
        }
    });
}

/// How many cities a country's card names on hover, the last place given to how many more there are.
const HOVER_CITIES: usize = 12;

/// A country as a card: three of its places' photos, each labelled with its city; its name, how many places and the
/// years its photos span on the photos (the years read as the card first shows); its first places by name on hover.
fn add_country_card(window: &Window, flow: &gtk::FlowBox, country: places::Country) {
    let Some(session) = window.session() else { return };
    let name = country.name.clone().unwrap_or_else(|| tr("Unknown Country").to_owned());
    let shown = crate::cards::Card::new(&name, true);
    shown.set_photos(&session.textures, &country.places.iter().take(3).map(|place| crate::cards::Shown::labelled(&place.photo_id, &place.city)).collect::<Vec<_>>());
    let count = country.places.len();
    let places = if count == 1 { tr("1 place").to_owned() } else { tr("{count} places").replace("{count}", &count.to_string()) };
    // Its first cities on hover, and how many more: all of them are a click away.
    let mut cities: Vec<String> = country.places.iter().take(if count > HOVER_CITIES { HOVER_CITIES - 1 } else { count }).map(|place| place.city.clone()).collect();
    if count > HOVER_CITIES {
        cities.push(tr("{count} more").replace("{count}", &(count - cities.len()).to_string()));
    }
    shown.root.set_tooltip_text(Some(&crate::cards::and_list(&cities)));
    let line = shown.line(&places);
    if let Some(named) = country.name.clone() {
        // Its first and its last photo, once the card shows.
        let (client, asked) = (session.connection.client.clone(), std::cell::Cell::new(false));
        let line = line.downgrade();
        shown.root.connect_map(move |_| {
            if asked.replace(true) {
                return;
            }
            let query = AssetQuery { country: Some(named.clone()), visibility: Some(immich_api::Visibility::Timeline), ..AssetQuery::default() };
            let oldest = AssetQuery { oldest_first: true, ..query.clone() };
            let (client, line, places) = (client.clone(), line.clone(), places.clone());
            crate::tasks::run(
                async move {
                    let first = client.search_assets(&oldest, 1, None).await.ok()?.assets.into_iter().next()?;
                    let last = client.search_assets(&query, 1, None).await.ok()?.assets.into_iter().next()?;
                    Some((chrono::Datelike::year(&first.local_date_time), chrono::Datelike::year(&last.local_date_time)))
                },
                move |span| {
                    if let (Some((first, last)), Some(line)) = (span, line.upgrade()) {
                        crate::cards::say(&line, &crate::cards::joined(&[places, crate::cards::years(first, last)]));
                    }
                },
            );
        });
    }
    let card = shown.root.clone();
    let (weak_window, title) = (window.downgrade(), name.clone());
    add_card(flow, &card, &name, move || {
        let Some(window) = weak_window.upgrade() else { return };
        let cities = card_page(&title, tr("No Places"), "mark-location-symbolic");
        cities.page.add_css_class("verso-card-page");
        cities.header.pack_start(&crate::cards::zoom_buttons());
        cities.stack.set_visible_child_name("cards");
        city_flow(&cities.flow);
        for place in &country.places {
            add_city_card(&window, &cities.flow, place, false);
        }
        window.push_page(&cities.page);
    });
}

/// The photos of a city (in a country), or of a whole country.
pub fn place_page(window: &Window, city: Option<String>, country: Option<String>) -> adw::NavigationPage {
    let title = city.clone().or_else(|| country.clone()).unwrap_or_default();
    let query = AssetQuery { city: city.clone(), country: country.clone(), visibility: Some(immich_api::Visibility::Timeline), ..AssetQuery::default() };
    let mut spec = Spec::new(&title, Source::Search(Box::new(query)), Kind::Plain);
    let item = match (city, country) {
        (Some(city), country) => Some(ImmichItem::City { country, city }),
        (None, Some(country)) => Some(ImmichItem::Country(country)),
        _ => None,
    };
    if let Some(item) = item {
        let menu = gio::Menu::new();
        crate::crosslink::append(&menu, item.kind().as_str(), "page");
        spec.menu = Some(menu);
        spec.actions = item_actions(window, item);
    }
    pages::grid_page(window, spec).0
}

// --- Memories ---

// --- Lists: tags, folders, shared links, partners ---

/// A page with a list of rows, filled once its answer comes.
struct ListPage {
    page: adw::NavigationPage,
    group: adw::PreferencesGroup,
    stack: gtk::Stack,
    empty: adw::StatusPage,
}

fn list_page(title: &str, empty_title: &str, empty_icon: &str) -> ListPage {
    let group = adw::PreferencesGroup::new();
    let preferences = adw::PreferencesPage::new();
    preferences.add(&group);
    let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
    let empty = adw::StatusPage::builder().title(empty_title).icon_name(empty_icon).build();
    let stack = gtk::Stack::new();
    stack.add_named(&spinner, Some("loading"));
    stack.add_named(&preferences, Some("list"));
    stack.add_named(&empty, Some("empty"));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&stack));
    ListPage { page: adw::NavigationPage::builder().title(title).child(&toolbar).build(), group, stack, empty }
}

fn link_row(title: &str, subtitle: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(glib::markup_escape_text(title)).subtitle(glib::markup_escape_text(subtitle)).activatable(true).build();
    row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    row
}

pub fn folders_page(window: &Window) -> adw::NavigationPage {
    let list = list_page(tr("Folders"), tr("No Folders"), "folder-symbolic");
    list.empty.set_description(Some(tr("The folders on the server that hold your originals, as Immich's folder view shows them.")));
    let Some(session) = window.session() else { return list.page };
    let client = session.connection.client.clone();
    let (weak_window, group, stack) = (window.downgrade(), list.group.clone(), list.stack.clone());
    crate::tasks::run(async move { client.folder_paths().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let Some(window) = weak_window.upgrade() else { return };
        match outcome {
            Ok(paths) => {
                stack.set_visible_child_name(if paths.is_empty() { "empty" } else { "list" });
                fill_folders(&window, &group, Rc::new(paths), "");
            }
            Err(message) => {
                stack.set_visible_child_name("empty");
                window.toast(&message);
            }
        }
    });
    list.page
}

/// The most rows a folder level shows; a server can have tens of thousands of folders.
const FOLDER_ROWS: usize = 400;

/// One level of folders: its photos, when it has any, then the folders in it, each opening the next level.
fn fill_folders(window: &Window, group: &adw::PreferencesGroup, paths: Rc<Vec<String>>, parent: &str) {
    if !parent.is_empty() && paths.iter().any(|path| path == parent) {
        let row = link_row(tr("Photos in This Folder"), parent);
        row.add_prefix(&gtk::Image::from_icon_name("image-x-generic-symbolic"));
        let (weak_window, path) = (window.downgrade(), parent.to_owned());
        row.connect_activated(move |_| {
            if let Some(window) = weak_window.upgrade() {
                let name = path.rsplit('/').next().unwrap_or(&path).to_owned();
                let spec = Spec::new(&name, Source::Folder(path.clone()), Kind::Plain);
                window.push_page(&pages::grid_page(&window, spec).0);
            }
        });
        group.add(&row);
    }
    let folders = verso_desktop::library::folders_under(&paths, parent);
    if folders.len() > FOLDER_ROWS {
        group.set_description(Some(&tr("The first {count} of {total} folders").replace("{count}", &FOLDER_ROWS.to_string()).replace("{total}", &folders.len().to_string())));
    }
    for folder in folders.into_iter().take(FOLDER_ROWS) {
        let detail = match folder.folders_inside {
            0 => String::new(),
            1 => tr("1 folder").to_owned(),
            count => tr("{count} folders").replace("{count}", &count.to_string()),
        };
        let row = link_row(&folder.name, &detail);
        row.add_prefix(&gtk::Image::from_icon_name("folder-symbolic"));
        let (weak_window, paths) = (window.downgrade(), paths.clone());
        row.connect_activated(move |_| {
            let Some(window) = weak_window.upgrade() else { return };
            if folder.folders_inside == 0 {
                // Only photos inside: open them at once.
                let spec = Spec::new(&folder.name, Source::Folder(folder.path.clone()), Kind::Plain);
                window.push_page(&pages::grid_page(&window, spec).0);
                return;
            }
            let list = list_page(&folder.name, tr("No Folders"), "folder-symbolic");
            list.stack.set_visible_child_name("list");
            fill_folders(&window, &list.group, paths.clone(), &folder.path);
            window.push_page(&list.page);
        });
        group.add(&row);
    }
}

// --- Utilities ---

pub fn large_files_page(window: &Window) -> adw::NavigationPage {
    pages::grid_page(window, Spec::new(tr("Large Files"), Source::LargeFiles { favorites_only: false, kind: None }, Kind::Plain).arranged(GridPage::LargeFiles).empty(tr("No Large Files"), "drive-harddisk-symbolic")).0
}

/// Assign Location: the photos without a location, each with its place on it, as the Mac gallery's page; or every
/// photo, to see which have one. Assign Location sets the selection's place.
pub fn assign_location_page(window: &Window) -> adw::NavigationPage {
    let all = settings::shared().get("grid.geolocation.location").as_deref() == Some("all");
    let mut spec = Spec::new(tr("Assign Location"), Source::WithoutLocation { all }, Kind::Plain).empty(tr("All Items Have a Location"), "mark-location-symbolic");
    let location = gio::Menu::new();
    location.append(Some(tr("Without Location")), Some("page.location::missing"));
    location.append(Some(tr("All Items")), Some("page.location::all"));
    let menu = gio::Menu::new();
    menu.append_section(Some(tr("Location")), &location);
    spec.menu = Some(menu);
    let action = gio::SimpleAction::new_stateful("location", Some(glib::VariantTy::STRING), &(if all { "all" } else { "missing" }).to_variant());
    let shown_grid: Rc<RefCell<Option<crate::grid::WeakGrid>>> = Rc::default();
    let holder = shown_grid.clone();
    action.connect_change_state(move |action, value| {
        let Some(value) = value else { return };
        action.set_state(value);
        let all = value.get::<String>().as_deref() == Some("all");
        settings::shared().set("grid.geolocation.location", all.then_some("all"));
        if let Some(grid) = holder.borrow().as_ref().and_then(crate::grid::WeakGrid::upgrade) {
            grid.set_empty_title(if all { tr("No Photos") } else { tr("All Items Have a Location") });
            grid.set_source(Source::WithoutLocation { all });
        }
    });
    spec.actions.push(action);
    spec.buttons.push(gtk::Button::builder().label(tr("Assign Location…")).action_name("selection.place").tooltip_text(tr("Set the place of the photos selected")).build().upcast());
    let (page, grid) = pages::grid_page(window, spec);
    if let Some(grid) = &grid {
        grid.show_place_badges();
    }
    shown_grid.replace(grid.as_ref().map(crate::grid::Grid::downgrade));
    page
}
