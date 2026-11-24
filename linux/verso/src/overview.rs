//! The Library's Years and Months, as in Photos and the Mac gallery: a card for each year, showing a photo from its
//! fullest month, and each month as a few photos from different days of it (`verso_core::overview`, which the Mac and
//! the iPhone arrange them with too). A year opens its months; a photo opens All Photos at it.
//!
//! Months are read as they come into view, unless the grid has read them already; their pictures are previews
//! decoded small, a few at a time, and one whose card or month moved on is dropped before it is fetched.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::rc::Rc;

use gtk::subclass::prelude::*;
use gtk::{gdk, gio, glib, prelude::*};
use immich_api::timeline::{TimelineScope, YearMonth};
use immich_api::Client;
use verso_core::overview;
use verso_desktop::images::{Cache, Kind as ImageKind};
use verso_desktop::library::{self, Tile};
use verso_desktop::text;

use crate::collections::SquareFrame;
use crate::grid::WeakGrid;

/// Pictures are previews, decoded no larger than this on their longer side.
const PICTURE_SIDE: u32 = 720;
/// Decoded pictures kept in memory: a few screens of months (some 60 MB).
const KEPT_PICTURES: usize = 48;
/// Months kept read, beyond those the grid holds.
const KEPT_MONTHS: usize = 120;
/// Months, or pictures, fetched at once.
const AT_ONCE: usize = 4;
/// A year's card is a square at least this wide, widened to fill its line (as the Mac gallery's).
const CARD: i32 = 240;
/// The photos of a month's mosaic.
const MOSAIC: usize = 4;
/// A month's mosaic is this many times as wide as it is tall.
const MOSAIC_SHAPE: f64 = 2.2;
const SPACING: i32 = 12;

/// The Library's two views besides All Photos.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Years,
    Months,
}

/// Once something waited for is here, or `None` if it could not be had.
type Then<V> = Box<dyn FnOnce(Option<V>)>;
/// Whether a waiter still shows what it asked for.
type Wanted = Box<dyn Fn() -> bool>;
/// Start fetching a key; call back on the main loop with what came.
type Fetch<K, V> = Box<dyn Fn(K, Then<V>)>;
/// Those waiting for each key.
type Waiters<K, V> = RefCell<HashMap<K, Vec<(Wanted, Then<V>)>>>;
/// A year's card chosen: Months, at the year's first month.
type OnYear = RefCell<Option<Box<dyn Fn(YearMonth)>>>;
/// A photo chosen: All Photos, at it.
type OnPhoto = RefCell<Option<Box<dyn Fn(YearMonth, String)>>>;

/// What is fetched a few at a time, the most recent kept: months of tiles, and pictures.
struct Loader<K, V> {
    limit: usize,
    kept: RefCell<HashMap<K, V>>,
    order: RefCell<VecDeque<K>>,
    waiting: Waiters<K, V>,
    queue: RefCell<VecDeque<K>>,
    in_flight: Cell<usize>,
    fetch: Fetch<K, V>,
}

impl<K: Clone + Eq + Hash + 'static, V: Clone + 'static> Loader<K, V> {
    fn new(limit: usize, fetch: Fetch<K, V>) -> Rc<Loader<K, V>> {
        Rc::new(Loader { limit, kept: RefCell::default(), order: RefCell::default(), waiting: RefCell::default(), queue: RefCell::default(), in_flight: Cell::new(0), fetch })
    }

    fn get(self: &Rc<Self>, key: K, wanted: impl Fn() -> bool + 'static, then: impl FnOnce(Option<V>) + 'static) {
        let kept = self.kept.borrow().get(&key).cloned();
        if let Some(value) = kept {
            let mut order = self.order.borrow_mut();
            order.retain(|known| *known != key);
            order.push_back(key);
            drop(order);
            return then(Some(value));
        }
        let first = {
            let mut waiting = self.waiting.borrow_mut();
            let waiters = waiting.entry(key.clone()).or_default();
            waiters.push((Box::new(wanted), Box::new(then)));
            waiters.len() == 1
        };
        if first {
            self.queue.borrow_mut().push_back(key);
        }
        self.pump();
    }

    fn put(&self, key: K, value: V) {
        self.kept.borrow_mut().insert(key.clone(), value);
        let mut order = self.order.borrow_mut();
        order.push_back(key);
        while order.len() > self.limit {
            if let Some(oldest) = order.pop_front() {
                self.kept.borrow_mut().remove(&oldest);
            }
        }
    }

    fn pump(self: &Rc<Self>) {
        while self.in_flight.get() < AT_ONCE {
            let Some(key) = self.queue.borrow_mut().pop_front() else { return };
            // Nobody shows it now: its waiters go, and asked again, it queues again.
            let wanted = self.waiting.borrow().get(&key).is_some_and(|waiters| waiters.iter().any(|(wanted, _)| wanted()));
            if !wanted {
                self.waiting.borrow_mut().remove(&key);
                continue;
            }
            self.in_flight.set(self.in_flight.get() + 1);
            let weak = Rc::downgrade(self);
            let done_key = key.clone();
            (self.fetch)(
                key,
                Box::new(move |value: Option<V>| {
                    let Some(loader) = weak.upgrade() else { return };
                    loader.in_flight.set(loader.in_flight.get() - 1);
                    if let Some(value) = &value {
                        loader.put(done_key.clone(), value.clone());
                    }
                    let waiters = loader.waiting.borrow_mut().remove(&done_key).unwrap_or_default();
                    for (_, then) in waiters {
                        then(value.clone());
                    }
                    loader.pump();
                }),
            );
        }
    }
}

/// A picture: the photo's id and its version (its ThumbHash).
type PictureKey = (String, Option<String>);

pub struct Overview {
    stack: gtk::Stack,
    years: gtk::FlowBox,
    months: gio::ListStore,
    month_list: gtk::ListView,
    grid: WeakGrid,
    month_loader: Rc<Loader<YearMonth, Rc<Vec<Tile>>>>,
    pictures: Rc<Loader<PictureKey, gdk::Texture>>,
    /// The month Months scrolls to once it is filled (the year a card opened).
    start_month: Cell<Option<YearMonth>>,
    pub on_year: OnYear,
    pub on_photo: OnPhoto,
}

impl Overview {
    pub fn new(client: Client, scope: TimelineScope, cache: Cache, grid: WeakGrid) -> Rc<Overview> {
        let month_loader = {
            let (grid, client) = (grid.clone(), client.clone());
            Loader::new(
                KEPT_MONTHS,
                Box::new(move |month: YearMonth, done: Then<Rc<Vec<Tile>>>| {
                    // The grid's own reading, when it has one.
                    if let Some(tiles) = grid.upgrade().and_then(|grid| grid.loaded_month(month)) {
                        return done(Some(Rc::new(tiles)));
                    }
                    // Narrowed as the grid is by the page's view options, when the timeline API reads it.
                    let options = grid.upgrade().and_then(|grid| grid.timeline()).map(|(_, options)| options).unwrap_or_default();
                    let (client, scope) = (client.clone(), scope.clone());
                    crate::tasks::run(async move { library::month_with(&client, &scope, &options, month).await }, move |outcome| done(outcome.ok().map(Rc::new)));
                }),
            )
        };
        let pictures = Loader::new(
            KEPT_PICTURES,
            Box::new(move |(id, version): PictureKey, done: Then<gdk::Texture>| {
                let cache = cache.clone();
                crate::tasks::run(async move { cache.picture(ImageKind::Preview, &id, version.as_deref(), Some(PICTURE_SIDE)).await }, move |outcome| {
                    done(outcome.ok().map(crate::textures::texture))
                });
            }),
        );

        let years = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .activate_on_single_click(true)
            .homogeneous(true)
            .row_spacing(28)
            .column_spacing(28)
            .max_children_per_line(8)
            .valign(gtk::Align::Start)
            .margin_top(32)
            .margin_bottom(32)
            .margin_start(32)
            .margin_end(32)
            .build();
        let months = gio::ListStore::new::<glib::BoxedAnyObject>();
        let factory = gtk::SignalListItemFactory::new();
        let month_list = gtk::ListView::builder().model(&gtk::NoSelection::new(Some(months.clone()))).factory(&factory).css_classes(["gallery-months"]).build();
        let stack = gtk::Stack::new();
        stack.add_named(&gtk::ScrolledWindow::builder().child(&years).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build(), Some("years"));
        stack.add_named(&gtk::ScrolledWindow::builder().child(&month_list).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build(), Some("months"));

        let overview = Rc::new(Overview {
            stack,
            years,
            months,
            month_list,
            grid,
            month_loader,
            pictures,
            start_month: Cell::new(None),
            on_year: RefCell::default(),
            on_photo: RefCell::default(),
        });

        // A month's row: its heading and its mosaic.
        factory.connect_setup(|_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let heading = gtk::Label::builder().xalign(0.0).css_classes(["gallery-overview-month"]).build();
            let mosaic = Mosaic::new();
            let row = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_start(32).margin_end(32).margin_top(18).margin_bottom(18).build();
            row.append(&heading);
            row.append(&mosaic);
            item.set_child(Some(&row));
            item.set_activatable(false);
            item.set_focusable(false);
        });
        let weak = Rc::downgrade(&overview);
        factory.connect_bind(move |_, item| {
            let Some(overview) = weak.upgrade() else { return };
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let Some(month) = item.item().and_downcast::<glib::BoxedAnyObject>().map(|object| *object.borrow::<YearMonth>()) else { return };
            let Some(row) = item.child() else { return };
            if let Some(heading) = row.first_child().and_downcast::<gtk::Label>() {
                heading.set_label(&text::month_title(month));
            }
            if let Some(mosaic) = row.last_child().and_downcast::<Mosaic>() {
                overview.fill_mosaic(&mosaic, month);
            }
        });
        let weak = Rc::downgrade(&overview);
        overview.years.connect_child_activated(move |_, child| {
            let Some(overview) = weak.upgrade() else { return };
            let Some(month) = overview.year_cards_first_month(child) else { return };
            let on_year = overview.on_year.borrow();
            if let Some(on_year) = on_year.as_ref() {
                on_year(month);
            }
        });
        overview
    }

    /// Forget the months read, after the view options changed what they hold.
    pub fn forget(&self) {
        self.month_loader.kept.borrow_mut().clear();
        self.month_loader.order.borrow_mut().clear();
    }

    pub fn widget(&self) -> &gtk::Stack {
        &self.stack
    }

    /// Show Years or Months, from the timeline's months as the grid has them now.
    pub fn show(self: &Rc<Self>, mode: Mode) {
        let months: Vec<(YearMonth, u32)> = self.grid.upgrade().map(|grid| grid.month_counts()).unwrap_or_default();
        match mode {
            Mode::Years => {
                self.fill_years(&months);
                self.stack.set_visible_child_name("years");
            }
            Mode::Months => {
                let known: Vec<YearMonth> = (0..self.months.n_items()).filter_map(|position| self.months.item(position).and_downcast::<glib::BoxedAnyObject>().map(|object| *object.borrow::<YearMonth>())).collect();
                let wanted: Vec<YearMonth> = months.iter().map(|(month, _)| *month).collect();
                if known != wanted {
                    let objects: Vec<glib::BoxedAnyObject> = wanted.iter().map(|month| glib::BoxedAnyObject::new(*month)).collect();
                    self.months.splice(0, self.months.n_items(), &objects);
                }
                self.stack.set_visible_child_name("months");
                if let Some(start) = self.start_month.take() {
                    if let Some(position) = wanted.iter().position(|month| *month == start) {
                        // Once the list is laid out at its size (scrolled before, it stays at the top), bring the
                        // month into view, then its heading to the top.
                        let (list, scrolled, tries) = (self.month_list.downgrade(), Cell::new(false), Cell::new(0));
                        self.month_list.add_tick_callback(move |_, _| {
                            let Some(list) = list.upgrade() else { return glib::ControlFlow::Break };
                            if list.height() == 0 {
                                return glib::ControlFlow::Continue;
                            }
                            if !scrolled.replace(true) {
                                list.scroll_to(position as u32, gtk::ListScrollFlags::NONE, None);
                                return glib::ControlFlow::Continue;
                            }
                            tries.set(tries.get() + 1);
                            if align_month(&list, start) || tries.get() > 30 { glib::ControlFlow::Break } else { glib::ControlFlow::Continue }
                        });
                    }
                }
            }
        }
    }

    /// Months will open at this month (a year's card chosen).
    pub fn start_at(&self, month: YearMonth) {
        self.start_month.set(Some(month));
    }

    fn fill_years(self: &Rc<Self>, months: &[(YearMonth, u32)]) {
        while let Some(child) = self.years.first_child() {
            self.years.remove(&child);
        }
        for year in overview::years(months) {
            let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
            let frame = SquareFrame::adaptive(CARD, &picture);
            frame.add_css_class("gallery-card-picture");
            let label = gtk::Label::builder().label(year.year.to_string()).halign(gtk::Align::Start).valign(gtk::Align::Start).css_classes(["gallery-overview-year"]).build();
            let card = gtk::Overlay::builder().child(&frame).build();
            card.add_overlay(&label);
            card.set_widget_name(&format!("{:04}-{:02}", year.months[0].year, year.months[0].month));
            card.update_property(&[gtk::accessible::Property::Label(&year.year.to_string())]);
            self.years.append(&card);
            let (weak_picture, weak_self) = (picture.downgrade(), Rc::downgrade(self));
            let wanted_picture = picture.downgrade();
            self.month_loader.get(
                year.key_month,
                move || wanted_picture.upgrade().is_some_and(|picture| picture.parent().is_some()),
                move |tiles| {
                    let (Some(overview), Some(tiles)) = (weak_self.upgrade(), tiles) else { return };
                    let Some(pick) = overview::picks(&photos(&tiles), 1).into_iter().next() else { return };
                    let version = tiles.iter().find(|tile| tile.id == pick.id).and_then(|tile| tile.thumbhash.clone());
                    let wanted = weak_picture.clone();
                    let shown = weak_picture.clone();
                    overview.pictures.get(
                        (pick.id, version),
                        move || wanted.upgrade().is_some_and(|picture| picture.parent().is_some()),
                        move |texture| {
                            if let (Some(picture), Some(texture)) = (shown.upgrade(), texture) {
                                picture.set_paintable(Some(&texture));
                            }
                        },
                    );
                },
            );
        }
    }

    /// The first month of the year a card stands for.
    fn year_cards_first_month(&self, child: &gtk::FlowBoxChild) -> Option<YearMonth> {
        let name = child.child()?.widget_name();
        let (year, month) = name.split_once('-')?;
        YearMonth::new(year.parse().ok()?, month.parse().ok()?)
    }

    fn fill_mosaic(self: &Rc<Self>, mosaic: &Mosaic, month: YearMonth) {
        mosaic.show_month(month);
        let (weak_mosaic, weak_self) = (mosaic.downgrade(), Rc::downgrade(self));
        let wanted_mosaic = mosaic.downgrade();
        self.month_loader.get(
            month,
            move || wanted_mosaic.upgrade().is_some_and(|mosaic| mosaic.month() == Some(month)),
            move |tiles| {
                let (Some(overview), Some(mosaic), Some(tiles)) = (weak_self.upgrade(), weak_mosaic.upgrade(), tiles) else { return };
                if mosaic.month() != Some(month) {
                    return;
                }
                for pick in overview::picks(&photos(&tiles), MOSAIC) {
                    let tile = mosaic.add_tile(pick.day);
                    let (weak_self, id) = (Rc::downgrade(&overview), pick.id.clone());
                    tile.connect_clicked(move |_| {
                        let Some(overview) = weak_self.upgrade() else { return };
                        let on_photo = overview.on_photo.borrow();
                        if let Some(on_photo) = on_photo.as_ref() {
                            on_photo(month, id.clone());
                        }
                    });
                    let version = tiles.iter().find(|tile| tile.id == pick.id).and_then(|tile| tile.thumbhash.clone());
                    let Some(picture) = tile.child().and_downcast::<gtk::Overlay>().and_then(|overlay| overlay.child()).and_downcast::<gtk::Picture>() else { continue };
                    let (wanted, shown) = (mosaic.downgrade(), picture.downgrade());
                    overview.pictures.get(
                        (pick.id, version),
                        move || wanted.upgrade().is_some_and(|mosaic| mosaic.month() == Some(month)),
                        move |texture| {
                            if let (Some(picture), Some(texture)) = (shown.upgrade(), texture) {
                                picture.set_paintable(Some(&texture));
                            }
                        },
                    );
                }
            },
        );
    }
}

/// A month's tiles as the overview picks from them.
fn photos(tiles: &[Tile]) -> Vec<overview::Photo> {
    tiles.iter().map(|tile| overview::Photo { id: tile.id.clone(), taken: Some(tile.taken), is_video: tile.is_video }).collect()
}

/// Scroll Months so the month's heading is at the top, once its row is laid out; whether it was.
fn align_month(list: &gtk::ListView, month: YearMonth) -> bool {
    let rows = std::iter::successors(list.first_child(), |item| item.next_sibling()).filter_map(|item| item.first_child());
    for row in rows {
        if !row.last_child().and_downcast::<Mosaic>().is_some_and(|mosaic| mosaic.month() == Some(month)) {
            continue;
        }
        let (Some(point), Some(adjustment)) = (row.compute_point(list, &gtk::graphene::Point::new(0.0, 0.0)), list.vadjustment()) else { return false };
        adjustment.set_value(adjustment.value() + f64::from(point.y()) - f64::from(row.margin_top()));
        return true;
    }
    false
}

mod mosaic_imp {
    use super::*;

    #[derive(Default)]
    pub struct Mosaic {
        pub month: Cell<Option<YearMonth>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Mosaic {
        const NAME: &'static str = "ImmichGalleryMosaic";
        type Type = super::Mosaic;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for Mosaic {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().add_css_class("gallery-mosaic");
            self.obj().set_overflow(gtk::Overflow::Hidden);
        }

        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for Mosaic {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            for child in std::iter::successors(self.obj().first_child(), |child| child.next_sibling()) {
                let _ = child.measure(orientation, -1);
            }
            match orientation {
                gtk::Orientation::Horizontal => (120, 900, -1, -1),
                _ => {
                    let width = if for_size > 0 { for_size } else { 900 };
                    let height = (f64::from(width) / MOSAIC_SHAPE).round() as i32;
                    (height, height, -1, -1)
                }
            }
        }

        fn size_allocate(&self, width: i32, height: i32, _baseline: i32) {
            let tiles: Vec<gtk::Widget> = std::iter::successors(self.obj().first_child(), |child| child.next_sibling()).collect();
            let Some((first, others)) = tiles.split_first() else { return };
            if others.is_empty() {
                first.size_allocate(&gtk::Allocation::new(0, 0, width, height), -1);
                return;
            }
            // One large photo, and the others above one another beside it, as Photos' Months.
            let large = if others.len() > 1 { (width - SPACING) * 2 / 3 } else { (width - SPACING) / 2 };
            first.size_allocate(&gtk::Allocation::new(0, 0, large, height), -1);
            let (left, side) = (large + SPACING, width - large - SPACING);
            let count = others.len() as i32;
            let each = (height - SPACING * (count - 1)) / count;
            for (index, tile) in others.iter().enumerate() {
                tile.size_allocate(&gtk::Allocation::new(left, index as i32 * (each + SPACING), side, each), -1);
            }
        }
    }
}

glib::wrapper! {
    /// A month's few photos: one large, the others beside it, at a fixed shape whatever the photos'.
    pub struct Mosaic(ObjectSubclass<mosaic_imp::Mosaic>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Mosaic {
    fn new() -> Mosaic {
        glib::Object::builder().property("hexpand", true).build()
    }

    fn month(&self) -> Option<YearMonth> {
        self.imp().month.get()
    }

    /// Start showing a month: its photos come once it is read.
    fn show_month(&self, month: YearMonth) {
        self.imp().month.set(Some(month));
        while let Some(child) = self.first_child() {
            child.unparent();
        }
        self.add_css_class("empty");
        self.queue_resize();
    }

    /// A photo's place in the mosaic, with its day of the month on it; its picture comes later.
    fn add_tile(&self, day: Option<u32>) -> gtk::Button {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let overlay = gtk::Overlay::builder().child(&picture).build();
        if let Some(day) = day {
            let label = gtk::Label::builder().label(day.to_string()).halign(gtk::Align::Start).valign(gtk::Align::Start).css_classes(["gallery-mosaic-day"]).build();
            overlay.add_overlay(&label);
        }
        let button = gtk::Button::builder().child(&overlay).css_classes(["gallery-mosaic-tile"]).overflow(gtk::Overflow::Hidden).build();
        button.set_parent(self);
        self.remove_css_class("empty");
        self.queue_resize();
        button
    }
}
