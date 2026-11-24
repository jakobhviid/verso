//! The map: every photo with a place, gathered into clusters that follow the zoom (`verso_core::map`, as on the Mac and
//! the iPhone), each a pin: a thumbnail in a rounded square, as places are, with its count, and a tail whose tip is on
//! the spot; a click opens its photos. OpenStreetMap's tiles through libshumate, GNOME Maps' map widget.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;
use immich_api::{MapMarker, MapQuery};
use verso_core::map::Cluster;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Source;
use verso_desktop::map;
use verso_desktop::text;
use verso_linux::i18n::tr;
use shumate::prelude::*;

use crate::collections::SquareFrame;
use crate::pages::{self, Kind, Spec};
use crate::window::Window;

const MARKER_SIZE: i32 = 52;
/// A pin's tail under its photo: how wide at the photo, and how far down to its tip.
const TAIL: (i32, i32) = (16, 9);

struct State {
    window: glib::WeakRef<Window>,
    map: shumate::SimpleMap,
    layer: shumate::MarkerLayer,
    markers: RefCell<Vec<MapMarker>>,
    /// Bumps with each move, so only the last of a quick run of moves gathers the clusters again.
    moved: Cell<u64>,
}

pub fn map_page(window: &Window) -> adw::NavigationPage {
    let simple = shumate::SimpleMap::new();
    let registry = shumate::MapSourceRegistry::with_defaults();
    if let Some(source) = registry.by_id(shumate::MAP_SOURCE_OSM_MAPNIK) {
        simple.set_map_source(Some(&source));
    }
    let (Some(map_widget), Some(viewport)) = (simple.map(), simple.viewport()) else {
        return pages::message_page(tr("Map"), tr("The Map Cannot Be Shown"), "", "find-location-symbolic");
    };
    let layer = shumate::MarkerLayer::new(&viewport);
    map_widget.add_layer(&layer);
    let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
    let overlay = gtk::Overlay::builder().child(&simple).build();
    overlay.add_overlay(&spinner);
    // When and what, as in the Mac gallery: the date ranges side by side in the header, as Library's Years, Months
    // and All Photos, and the map's filters with a custom range (not remembered).
    let ranges = adw::ToggleGroup::builder().tooltip_text(tr("Date Range")).build();
    for (label, _) in RANGES {
        ranges.add(adw::Toggle::builder().label(tr(label)).build());
    }
    ranges.set_active(0);
    let header = adw::HeaderBar::builder().title_widget(&ranges).build();
    let favorites = adw::SwitchRow::builder().title(tr("Favorites Only")).build();
    let archived = adw::SwitchRow::builder().title(tr("Include Archived")).build();
    let partners = adw::SwitchRow::builder().title(tr("Include Partners")).active(true).build();
    let custom_range = adw::SwitchRow::builder().title(tr("Custom Range")).build();
    let from = date_button();
    let through = date_button();
    let custom = adw::PreferencesGroup::builder().visible(false).build();
    let row = |title: &str, button: &gtk::MenuButton| {
        let row = adw::ActionRow::builder().title(title).build();
        row.add_suffix(button);
        row
    };
    custom.add(&row(tr("From"), &from.0));
    custom.add(&row(tr("Through"), &through.0));
    let shown = adw::PreferencesGroup::new();
    shown.add(&favorites);
    shown.add(&archived);
    shown.add(&partners);
    shown.add(&custom_range);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(6).margin_bottom(6).width_request(300).build();
    content.append(&shown);
    content.append(&custom);
    let filters_button = gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("Map Filters")).popover(&gtk::Popover::builder().child(&content).build()).build();
    header.pack_end(&filters_button);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&overlay));
    let page = adw::NavigationPage::builder().title(tr("Map")).child(&toolbar).build();
    let state = Rc::new(State { window: window.downgrade(), map: simple.clone(), layer, markers: RefCell::default(), moved: Cell::new(0) });
    for property in ["zoom-level", "latitude", "longitude"] {
        let weak = Rc::downgrade(&state);
        viewport.connect_notify_local(Some(property), move |_, _| {
            if let Some(state) = weak.upgrade() {
                state.moved_soon();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    map_widget.connect_notify_local(Some("width"), move |_, _| {
        if let Some(state) = weak.upgrade() {
            state.moved_soon();
        }
    });
    // The page owns the map's state; its callbacks hold it weakly.
    let owned = state.clone();
    page.connect_destroy(move |_| {
        let _ = &owned;
    });
    let Some(session) = window.session() else { return page };
    // Read the markers for the choices made; the first read fits the map to them.
    let first = Rc::new(Cell::new(true));
    let load: Rc<dyn Fn()> = {
        let (weak, weak_spinner, client) = (Rc::downgrade(&state), spinner.downgrade(), session.connection.client.clone());
        let (ranges, favorites, archived, partners, custom_range, from_date, through_date) =
            (ranges.downgrade(), favorites.downgrade(), archived.downgrade(), partners.downgrade(), custom_range.downgrade(), from.1.clone(), through.1.clone());
        Rc::new(move || {
            let (Some(ranges), Some(favorites), Some(archived), Some(partners), Some(custom_range)) =
                (ranges.upgrade(), favorites.upgrade(), archived.upgrade(), partners.upgrade(), custom_range.upgrade())
            else {
                return;
            };
            let now = chrono::Utc::now();
            let range = if custom_range.is_active() { Some(Range::Custom) } else { RANGES.get(ranges.active() as usize).map(|(_, range)| *range) };
            let (after, before) = match range {
                Some(Range::Since(hours)) => (Some(now - chrono::Duration::hours(hours)), None),
                Some(Range::Custom) => {
                    let start = |date: chrono::NaiveDate| chrono::TimeZone::from_utc_datetime(&chrono::Utc, &date.and_hms_opt(0, 0, 0).unwrap_or_default());
                    (from_date.get().map(start), through_date.get().and_then(|date| date.succ_opt()).map(start))
                }
                _ => (None, None),
            };
            let query = MapQuery {
                archived: (!archived.is_active()).then_some(false),
                favorite: favorites.is_active().then_some(true),
                created_after: after,
                created_before: before,
                with_partners: partners.is_active(),
                ..MapQuery::default()
            };
            if let Some(spinner) = weak_spinner.upgrade() {
                spinner.set_visible(true);
            }
            let (client, weak, weak_spinner, first) = (client.clone(), weak.clone(), weak_spinner.clone(), first.clone());
            crate::tasks::run(async move { client.map_markers(&query).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                if let Some(spinner) = weak_spinner.upgrade() {
                    spinner.set_visible(false);
                }
                let Some(state) = weak.upgrade() else { return };
                match outcome {
                    Ok(markers) => {
                        let extent = map::extent(&markers);
                        state.markers.replace(markers);
                        if first.replace(false) {
                            if let Some((latitude, longitude, _, longitude_span)) = extent {
                                state.fit(latitude, longitude, longitude_span);
                            }
                        }
                        state.gather();
                    }
                    Err(message) => {
                        if let Some(window) = state.window.upgrade() {
                            window.toast(&message);
                        }
                    }
                }
            });
        })
    };
    // A range in the header ends a custom one; a custom range leaves none of them chosen, and ending it chooses All.
    let (again, weak_custom) = (load.clone(), custom_range.downgrade());
    ranges.connect_active_notify(move |ranges| {
        if ranges.active() == gtk::INVALID_LIST_POSITION {
            return;
        }
        match weak_custom.upgrade().filter(|custom_range| custom_range.is_active()) {
            Some(custom_range) => custom_range.set_active(false),
            None => again(),
        }
    });
    let (again, weak_ranges, weak_dates) = (load.clone(), ranges.downgrade(), custom.downgrade());
    custom_range.connect_active_notify(move |custom_range| {
        let on = custom_range.is_active();
        if let Some(dates) = weak_dates.upgrade() {
            dates.set_visible(on);
        }
        let Some(ranges) = weak_ranges.upgrade() else { return };
        if on {
            ranges.set_active(gtk::INVALID_LIST_POSITION);
            again();
        } else if ranges.active() == gtk::INVALID_LIST_POSITION {
            ranges.set_active(0);
        } else {
            again();
        }
    });
    for switch in [&favorites, &archived, &partners] {
        let again = load.clone();
        switch.connect_active_notify(move |_| again());
    }
    for (_, _, changed) in [&from, &through] {
        let again = load.clone();
        changed.replace(Some(Box::new(move || again())));
    }
    load();
    page
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Range {
    All,
    /// The last so many hours.
    Since(i64),
    Custom,
}

/// The ranges in the header, short enough to sit side by side; a custom range is in the filters.
const RANGES: [(&str, Range); 6] = [
    ("All", Range::All),
    ("3 Years", Range::Since(3 * 365 * 24)),
    ("1 Year", Range::Since(365 * 24)),
    ("30 Days", Range::Since(30 * 24)),
    ("7 Days", Range::Since(7 * 24)),
    ("24 Hours", Range::Since(24)),
];

/// What runs when a date button's date changes.
type Changed = Rc<RefCell<Option<Box<dyn Fn()>>>>;

/// A button showing a date (or Any) that opens a calendar; its date, and what to run when it changes.
fn date_button() -> (gtk::MenuButton, Rc<Cell<Option<chrono::NaiveDate>>>, Changed) {
    let date: Rc<Cell<Option<chrono::NaiveDate>>> = Rc::default();
    let changed: Changed = Rc::default();
    let button = gtk::MenuButton::builder().label(tr("Any")).valign(gtk::Align::Center).build();
    let calendar = gtk::Calendar::new();
    let clear = gtk::Button::builder().label(tr("Any Date")).css_classes(["flat"]).build();
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).build();
    content.append(&calendar);
    content.append(&clear);
    button.set_popover(Some(&gtk::Popover::builder().child(&content).build()));
    let (chosen, run, weak_button) = (date.clone(), changed.clone(), button.downgrade());
    calendar.connect_day_selected(move |calendar| {
        let day = calendar.date();
        let picked = chrono::NaiveDate::from_ymd_opt(day.year(), day.month() as u32, day.day_of_month() as u32);
        chosen.set(picked);
        if let (Some(button), Some(picked)) = (weak_button.upgrade(), picked) {
            button.set_label(&picked.format("%Y-%m-%d").to_string());
        }
        if let Some(run) = run.borrow().as_ref() {
            run();
        }
    });
    let (chosen, run, weak_button) = (date.clone(), changed.clone(), button.downgrade());
    clear.connect_clicked(move |_| {
        chosen.set(None);
        if let Some(button) = weak_button.upgrade() {
            button.set_label(tr("Any"));
            if let Some(popover) = button.popover() {
                popover.popdown();
            }
        }
        if let Some(run) = run.borrow().as_ref() {
            run();
        }
    });
    (button, date, changed)
}

impl State {
    fn moved_soon(self: &Rc<Self>) {
        let moved = self.moved.get() + 1;
        self.moved.set(moved);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(150), move || {
            if let Some(state) = weak.upgrade() {
                if state.moved.get() == moved {
                    state.gather();
                }
            }
        });
    }

    /// Centre on the photos, at the zoom that shows `longitude_span` degrees across the map.
    fn fit(&self, latitude: f64, longitude: f64, longitude_span: f64) {
        let (Some(map), Some(viewport)) = (self.map.map(), self.map.viewport()) else { return };
        let width = f64::from(map.width().max(600));
        let zoom = (360.0 * width / (256.0 * longitude_span.max(0.001))).log2().clamp(2.0, 16.0);
        viewport.set_zoom_level(zoom);
        map.center_on(latitude, longitude);
    }

    /// The clusters for what is on screen now.
    fn gather(self: &Rc<Self>) {
        let (Some(map), Some(viewport)) = (self.map.map(), self.map.viewport()) else { return };
        let (width, height) = (f64::from(map.width()), f64::from(map.height()));
        if width < 1.0 || height < 1.0 {
            return;
        }
        let (latitude_span, longitude_span) = map::view_spans(viewport.latitude(), viewport.zoom_level(), width, height);
        let clusters = verso_core::map::clusters(&self.markers.borrow(), viewport.latitude(), viewport.longitude(), latitude_span, longitude_span);
        self.layer.remove_all();
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        for cluster in clusters.into_iter().take(400) {
            self.layer.add_marker(&self.marker(&session.textures, cluster));
        }
    }

    fn marker(self: &Rc<Self>, textures: &Rc<crate::textures::Textures>, cluster: Cluster) -> shumate::Marker {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let frame = SquareFrame::new(MARKER_SIZE, &picture);
        frame.add_css_class("gallery-map-marker");
        let (weak_picture, watched) = (picture.downgrade(), picture.downgrade());
        let wanted = move || match watched.upgrade() {
            Some(picture) if picture.is_mapped() => crate::textures::Wanted::Now,
            Some(_) => crate::textures::Wanted::Later,
            None => crate::textures::Wanted::No,
        };
        textures.get_while(ImageKind::Thumbnail, &cluster.id, None, wanted, move |texture| {
            if let (Some(picture), Some(texture)) = (weak_picture.upgrade(), texture) {
                picture.set_paintable(Some(&texture));
            }
        });
        let overlay = gtk::Overlay::builder().child(&frame).build();
        if cluster.assets.len() > 1 {
            let count = gtk::Label::builder().label(cluster.assets.len().to_string()).halign(gtk::Align::End).valign(gtk::Align::Start).css_classes(["gallery-map-count", "numeric"]).build();
            overlay.add_overlay(&count);
        }
        overlay.set_tooltip_text(Some(&text::items(cluster.assets.len() as u64)));
        let click = gtk::GestureClick::new();
        let (weak, ids) = (Rc::downgrade(self), cluster.assets.clone());
        click.connect_released(move |_, _, _, _| {
            let Some(state) = weak.upgrade() else { return };
            let Some(window) = state.window.upgrade() else { return };
            let title = text::items(ids.len() as u64);
            let spec = Spec::new(&title, Source::Ids(ids.clone()), Kind::Plain);
            window.push_page(&pages::grid_page(&window, spec).0);
        });
        overlay.add_controller(click);
        let pin = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        pin.append(&overlay);
        pin.append(&tail());
        // Standing on its foot, the tail's tip, rather than centred on the spot.
        let marker = shumate::Marker::builder().valign(gtk::Align::End).build();
        marker.set_child(Some(&pin));
        marker.set_location(cluster.latitude, cluster.longitude);
        marker
    }
}

/// A pin's tail: a white triangle in its photo's border colour, pointing down from the photo to the spot, on a faint
/// shadow as the photo's.
fn tail() -> gtk::DrawingArea {
    let tail = gtk::DrawingArea::builder().content_width(TAIL.0).content_height(TAIL.1).halign(gtk::Align::Center).can_target(false).build();
    tail.set_draw_func(|_, cairo, width, height| {
        let (width, height) = (f64::from(width), f64::from(height));
        let triangle = |depth: f64| {
            cairo.move_to(0.0, 0.0);
            cairo.line_to(width, 0.0);
            cairo.line_to(width / 2.0, depth);
            cairo.close_path();
        };
        cairo.set_source_rgba(0.0, 0.0, 0.0, 0.3);
        triangle(height);
        let _ = cairo.fill();
        cairo.set_source_rgb(1.0, 1.0, 1.0);
        triangle(height - 1.5);
        let _ = cairo.fill();
    });
    tail
}
