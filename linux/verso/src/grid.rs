//! The photo grid: sections (a timeline's months, or a list) laid out in justified rows or squares, in a list view
//! that only builds the rows on screen. A month's photos are read when its rows first come into view; until then
//! its rows are grey placeholders of about the right height. ThumbHash placeholders show while thumbnails load.
//!
//! Selection works as in Files: Ctrl+click adds, Shift+click extends, and in selection mode a click toggles.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::ops::Range;
use std::rc::{Rc, Weak};

use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::Client;
use verso_core::rail::Place;
use verso_desktop::images::Kind;
use verso_desktop::layout;
use verso_desktop::library::{self, Section, Source, Tile};
use verso_desktop::text;
use verso_linux::i18n::tr;

use crate::textures::{Textures, Wanted};

const HEADER_HEIGHT: i32 = 52;
const SPACING: u32 = 4;
/// Space on either side of the rows.
const MARGIN: i32 = 12;
/// Photos are mostly landscape: a month not yet read is laid out as this shape, so its rows are about right.
/// How many rows of months around the one shown are read ahead, each way: about three screens.
const PRELOAD_ROWS: usize = 30;
const ESTIMATED_RATIO: f64 = 1.33;
/// Enough placeholders to fill a row of the widest window at the smallest size, for the scrubber's rows.
const ROW_SAMPLE: usize = 256;
/// The thumbnail sizes the zoom steps through, as a row height.
const SIZES: [u32; 6] = [96, 128, 172, 220, 280, 360];

/// One row of the list.
#[derive(Clone, Debug)]
pub enum RowModel {
    Header { section: usize },
    Tiles { section: usize, row: layout::Row },
    Placeholder { row: layout::Row, section: usize },
}

impl RowModel {
    fn section(&self) -> usize {
        match self {
            RowModel::Header { section } | RowModel::Tiles { section, .. } | RowModel::Placeholder { section, .. } => *section,
        }
    }
}

type OpenHandler = Rc<dyn Fn(Vec<Tile>, usize)>;
type ContextHandler = Rc<dyn Fn(&gtk::Widget, f64, f64)>;
type MessageHandler = Rc<dyn Fn(&str)>;
type WidthHandler = Box<dyn Fn(i32)>;
type DragHandler = Rc<dyn Fn(Vec<String>) -> Option<gdk::ContentProvider>>;

/// Where the keyboard moves the focus ring.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Move {
    Left,
    Right,
    Up,
    Down,
    First,
    Last,
}

#[derive(Default)]
struct Handlers {
    open: Option<OpenHandler>,
    selection_changed: Option<Rc<dyn Fn()>>,
    context: Option<ContextHandler>,
    loaded: Option<Rc<dyn Fn(u64)>>,
    failed: Option<MessageHandler>,
    drag: Option<DragHandler>,
}

pub struct State {
    client: Client,
    textures: Rc<Textures>,
    source: RefCell<Source>,
    sections: RefCell<Vec<Section>>,
    section_rows: RefCell<Vec<Range<usize>>>,
    store: gio::ListStore,
    list: gtk::ListView,
    stack: gtk::Stack,
    empty: adw::StatusPage,
    /// What the grid shows when the photos could not be read, with Try Again.
    failed: adw::StatusPage,
    width: Cell<u32>,
    /// The layout waiting for the width to settle.
    width_settling: RefCell<Option<glib::SourceId>>,
    size_step: Cell<usize>,
    square: Cell<bool>,
    loading: RefCell<HashSet<usize>>,
    generation: Cell<u64>,
    selection: RefCell<HashSet<String>>,
    selecting: Cell<bool>,
    anchor: RefCell<Option<String>>,
    /// The photo the keyboard is on, ringed.
    cursor: RefCell<Option<String>>,
    /// Show each photo's place on it (Assign Location).
    place_badges: Cell<bool>,
    /// A key's move into a month not read yet, made again when a month arrives (with Shift's extending, or not).
    pending_move: Cell<Option<(Move, bool)>>,
    /// A photo to bring into view once its month is here (one chosen in Months).
    pending_reveal: RefCell<Option<String>>,
    /// A photo to show once the months are known (Show in All Photos, before the Library has read them).
    reveal_when_read: RefCell<Option<(immich_api::YearMonth, String)>>,
    /// The scrubber's jump into a month not read yet, by the section and the photo it reckons is at the top: once the
    /// month is read and laid out as it is, the jump lands on that photo's row again.
    pending_place: Cell<Option<(usize, usize)>>,
    /// Counts the jumps to a row, so a drag's earlier ones, still waiting to settle, give way to its latest.
    row_jumps: Cell<u64>,
    rows: RefCell<Vec<glib::WeakRef<GridRow>>>,
    handlers: RefCell<Handlers>,
    /// The timeline's scrubber, at the right edge of a grid of months.
    scrubber: crate::scrubber::Scrubber,
    scrolled: gtk::ScrolledWindow,
}

/// A grid of photos from one source.
#[derive(Clone)]
pub struct Grid {
    host: GridHost,
    state: Rc<State>,
}

/// A grid held weakly, for handlers the grid itself keeps.
#[derive(Clone)]
pub struct WeakGrid {
    host: glib::WeakRef<GridHost>,
    state: Weak<State>,
}

impl WeakGrid {
    pub fn upgrade(&self) -> Option<Grid> {
        Some(Grid { host: self.host.upgrade()?, state: self.state.upgrade()? })
    }
}

impl Grid {
    pub fn downgrade(&self) -> WeakGrid {
        WeakGrid { host: self.host.downgrade(), state: Rc::downgrade(&self.state) }
    }

    pub fn new(client: Client, textures: Rc<Textures>, source: Source, empty_title: &str, empty_icon: &str) -> Grid {
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        let factory = gtk::SignalListItemFactory::new();
        let list = gtk::ListView::new(Some(gtk::NoSelection::new(Some(store.clone()))), Some(factory.clone()));
        list.add_css_class("gallery-grid");
        list.set_single_click_activate(false);
        let scrolled = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&list).vexpand(true).build();
        let empty = adw::StatusPage::builder().title(empty_title).icon_name(empty_icon).build();
        let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
        let scrubber = crate::scrubber::Scrubber::new();
        let with_scrubber = gtk::Overlay::builder().child(&scrolled).build();
        with_scrubber.add_overlay(&scrubber);
        let stack = gtk::Stack::new();
        stack.add_named(&spinner, Some("loading"));
        stack.add_named(&with_scrubber, Some("grid"));
        stack.add_named(&empty, Some("empty"));
        let try_again = gtk::Button::builder().label(tr("Try Again")).halign(gtk::Align::Center).css_classes(["pill"]).build();
        let failed = adw::StatusPage::builder().title(tr("Could Not Load")).icon_name("network-error-symbolic").child(&try_again).build();
        stack.add_named(&failed, Some("failed"));
        stack.set_visible_child_name("loading");
        let host = GridHost::new(&stack);
        let state = Rc::new(State {
            client,
            textures,
            source: RefCell::new(source),
            sections: RefCell::default(),
            section_rows: RefCell::default(),
            store,
            list,
            stack,
            empty,
            failed,
            width: Cell::new(0),
            width_settling: RefCell::default(),
            size_step: Cell::new(shared_size_step()),
            square: Cell::new(squares_shown()),
            loading: RefCell::default(),
            generation: Cell::new(0),
            selection: RefCell::default(),
            selecting: Cell::new(false),
            anchor: RefCell::default(),
            cursor: RefCell::default(),
            place_badges: Cell::new(false),
            pending_move: Cell::new(None),
            pending_reveal: RefCell::default(),
            reveal_when_read: RefCell::default(),
            pending_place: Cell::new(None),
            row_jumps: Cell::new(0),
            rows: RefCell::default(),
            handlers: RefCell::default(),
            scrubber,
            scrolled,
        });
        let weak = Rc::downgrade(&state);
        try_again.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                state.stack.set_visible_child_name("loading");
                state.reload();
            }
        });
        // The scrubber goes to the place it points at; its mark follows the grid as it scrolls.
        let weak = Rc::downgrade(&state);
        state.scrubber.connect_jump(move |place| {
            if let Some(state) = weak.upgrade() {
                state.scroll_to_place(place);
            }
        });
        let weak = Rc::downgrade(&state);
        state.list.vadjustment().expect("a list scrolls").connect_value_changed(move |_| {
            // While the list lays out anew, no row may be on screen: the mark stays where it was.
            if let Some(top) = weak.upgrade().and_then(|state| state.top_place().map(|top| (state, top))) {
                top.0.scrubber.set_current(Some(top.1));
            }
        });
        let weak = Rc::downgrade(&state);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let row = GridRow::new(weak.clone());
            item.set_child(Some(&row));
            item.set_activatable(false);
            item.set_focusable(false);
            if let Some(state) = weak.upgrade() {
                state.rows.borrow_mut().retain(|row| row.upgrade().is_some());
                state.rows.borrow_mut().push(row.downgrade());
            }
        });
        let weak = Rc::downgrade(&state);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else { return };
            let (Some(row), Some(object), Some(state)) = (item.child().and_downcast::<GridRow>(), item.item().and_downcast::<glib::BoxedAnyObject>(), weak.upgrade()) else {
                return;
            };
            let model = object.borrow::<RowModel>().clone();
            let section = match &model {
                RowModel::Tiles { section, .. } | RowModel::Header { section } | RowModel::Placeholder { section, .. } => *section,
            };
            state.preload_around(section);
            row.bind(&state, model);
        });
        let weak = Rc::downgrade(&state);
        host.connect_width(move |width| {
            let Some(state) = weak.upgrade() else { return };
            let width = width.max(1) as u32;
            let previous = state.width.replace(width);
            if previous == width {
                return;
            }
            if previous == 0 {
                return state.rebuild();
            }
            // A width that changes frame after frame (the Info panel sliding in, a window being resized) lays the rows
            // out once, when it settles: laying out every row of a big library on each frame made the panel lag.
            if let Some(waiting) = state.width_settling.take() {
                waiting.remove();
            }
            let again = Rc::downgrade(&state);
            let waiting = glib::timeout_add_local_once(std::time::Duration::from_millis(120), move || {
                if let Some(state) = again.upgrade() {
                    state.width_settling.replace(None);
                    state.rebuild();
                }
            });
            state.width_settling.replace(Some(waiting));
        });
        state.log_frames();
        let grid = Grid { host, state };
        grid.reload();
        grid
    }

    pub fn widget(&self) -> &gtk::Widget {
        self.host.upcast_ref()
    }

    /// Read the source again from the start.
    pub fn reload(&self) {
        self.state.reload();
    }

    /// Read the source again, keeping the months whose count has not changed as they are: while photos are imported,
    /// so only the months they land in are read and drawn again, and the rest of the grid stays still.
    pub fn reread_changed(&self) {
        self.state.read(true);
    }

    /// Show each photo's place on it.
    pub fn show_place_badges(&self) {
        self.state.place_badges.set(true);
    }

    /// The empty page's title, for a page whose view options leave nothing.
    pub fn set_empty_title(&self, title: &str) {
        self.state.empty.set_title(title);
    }

    /// What the empty page offers under its title (an empty album's Add Photos, say).
    pub fn set_empty_child(&self, child: &impl IsA<gtk::Widget>) {
        self.state.empty.set_child(Some(child));
    }

    /// The timeline the grid reads, and its options, if it reads one month by month.
    pub fn timeline(&self) -> Option<(immich_api::TimelineScope, immich_api::TimelineOptions)> {
        self.state.source.borrow().timeline()
    }

    /// Open the first photo selected, as a double click would.
    pub fn open_selected(&self) {
        let tiles = self.state.loaded_tiles();
        let selected = self.selected_ids();
        let Some(position) = tiles.iter().position(|tile| selected.contains(&tile.id)) else { return };
        if let Some(open) = self.state.handlers.borrow().open.clone() {
            open(tiles, position);
        }
    }

    pub fn set_source(&self, source: Source) {
        self.state.source.replace(source);
        self.reload();
    }

    pub fn on_open(&self, handler: impl Fn(Vec<Tile>, usize) + 'static) {
        self.state.handlers.borrow_mut().open = Some(Rc::new(handler));
    }

    pub fn on_selection_changed(&self, handler: impl Fn() + 'static) {
        self.state.handlers.borrow_mut().selection_changed = Some(Rc::new(handler));
    }

    /// A right-click: the selection is what it applies to.
    pub fn on_context_menu(&self, handler: impl Fn(&gtk::Widget, f64, f64) + 'static) {
        self.state.handlers.borrow_mut().context = Some(Rc::new(handler));
    }

    /// Called with the number of items once the sections are known.
    pub fn on_loaded(&self, handler: impl Fn(u64) + 'static) {
        self.state.handlers.borrow_mut().loaded = Some(Rc::new(handler));
    }

    pub fn on_failed(&self, handler: impl Fn(&str) + 'static) {
        self.state.handlers.borrow_mut().failed = Some(Rc::new(handler));
    }

    /// What a drag of photos carries: given their ids, the content a drop gets.
    pub fn on_drag(&self, handler: impl Fn(Vec<String>) -> Option<gdk::ContentProvider> + 'static) {
        self.state.handlers.borrow_mut().drag = Some(Rc::new(handler));
    }

    /// Move the focus ring, and with `extend` the selection with it, as arrow keys do in Files.
    pub fn move_cursor(&self, step: Move, extend: bool) {
        self.state.move_cursor(step, extend);
    }

    /// In selection mode, add the ringed photo to the selection or take it out (Space).
    pub fn toggle_cursor(&self) -> bool {
        let Some(id) = self.state.cursor.borrow().clone() else { return false };
        if !self.state.selecting.get() {
            return false;
        }
        {
            let mut selection = self.state.selection.borrow_mut();
            if !selection.remove(&id) {
                selection.insert(id);
            }
        }
        self.state.selection_changed();
        true
    }

    /// Open the photo under the focus ring, if any.
    pub fn open_cursor(&self) -> bool {
        let Some(id) = self.state.cursor.borrow().clone() else { return false };
        let tiles = self.state.loaded_tiles();
        let Some(position) = tiles.iter().position(|tile| tile.id == id) else { return false };
        if let Some(open) = self.state.handlers.borrow().open.clone() {
            open(tiles, position);
        }
        true
    }

    pub fn selecting(&self) -> bool {
        self.state.selecting.get()
    }

    pub fn set_selecting(&self, selecting: bool) {
        self.state.selecting.set(selecting);
        if !selecting {
            self.state.selection.borrow_mut().clear();
            self.state.anchor.replace(None);
        }
        self.state.selection_changed();
    }

    pub fn selected_ids(&self) -> Vec<String> {
        // In the grid's order, so actions and downloads go in the order shown.
        let selection = self.state.selection.borrow();
        self.state.loaded_tiles().into_iter().filter(|tile| selection.contains(&tile.id)).map(|tile| tile.id).collect()
    }

    pub fn selected_tiles(&self) -> Vec<Tile> {
        let selection = self.state.selection.borrow();
        self.state.loaded_tiles().into_iter().filter(|tile| selection.contains(&tile.id)).collect()
    }

    pub fn select_all(&self) {
        let ids: HashSet<String> = self.state.loaded_tiles().into_iter().map(|tile| tile.id).collect();
        self.state.selection.replace(ids);
        self.state.selecting.set(true);
        self.state.selection_changed();
    }

    pub fn clear_selection(&self) {
        self.state.selection.borrow_mut().clear();
        self.state.selection_changed();
    }

    /// Every photo read so far, in order.
    pub fn tiles(&self) -> Vec<Tile> {
        self.state.loaded_tiles()
    }

    /// The timeline's months and how many photos each holds, in the grid's order.
    pub fn month_counts(&self) -> Vec<(immich_api::YearMonth, u32)> {
        self.state.sections.borrow().iter().filter_map(|section| section.month.map(|month| (month, section.count))).collect()
    }

    /// A month's tiles, if the grid has read it.
    pub fn loaded_month(&self, month: immich_api::YearMonth) -> Option<Vec<Tile>> {
        self.state.sections.borrow().iter().find(|section| section.month == Some(month))?.tiles.clone()
    }

    /// Show a photo of a month, ringed: the month is read first if need be, and the photo's row brought into view.
    pub fn reveal(&self, month: immich_api::YearMonth, id: &str) {
        self.state.reveal(month, id);
        self.host.grab_focus();
    }

    pub fn total(&self) -> u64 {
        self.state.sections.borrow().iter().map(|section| u64::from(section.count)).sum()
    }

    /// Lay the grid out again as the shared view now is: its size and squares (`zoom`, `set_squares_shown`), and the
    /// Date Scroller (`set_date_scroller_shown`).
    pub fn relayout(&self) {
        self.state.size_step.set(shared_size_step());
        self.state.square.set(squares_shown());
        self.state.rebuild();
    }

    pub fn square(&self) -> bool {
        self.state.square.get()
    }

    /// Take photos out of the grid at once, after a change that moved them elsewhere (deleted, archived, removed).
    pub fn remove(&self, ids: &[String]) {
        let gone: HashSet<&String> = ids.iter().collect();
        let mut changed = Vec::new();
        for (index, section) in self.state.sections.borrow_mut().iter_mut().enumerate() {
            if let Some(tiles) = section.tiles.as_mut() {
                let before = tiles.len();
                tiles.retain(|tile| !gone.contains(&tile.id));
                if tiles.len() != before {
                    section.count = tiles.len() as u32;
                    changed.push(index);
                }
            }
        }
        self.state.selection.borrow_mut().retain(|id| !gone.contains(id));
        if !changed.is_empty() {
            // Months may shift: answers for months still on their way would land on the wrong ones, so they are
            // dropped, and their rows ask again when shown.
            self.state.generation.set(self.state.generation.get() + 1);
            self.state.loading.borrow_mut().clear();
            self.state.pending_move.set(None);
            self.state.pending_reveal.replace(None);
            // A month left empty goes, heading and all, and the count says what is left.
            self.state.sections.borrow_mut().retain(|section| section.tiles.as_ref().is_none_or(|tiles| !tiles.is_empty()));
            let total = self.total();
            self.state.stack.set_visible_child_name(if total == 0 { "empty" } else { "grid" });
            self.state.rebuild();
            self.state.selection_changed();
            if let Some(loaded) = self.state.handlers.borrow().loaded.clone() {
                loaded(total);
            }
        }
    }

    /// A photo was turned by quarter turns: its shape follows, and its thumbnail is read again.
    pub fn turned(&self, id: &str, quarter_turns: i32) {
        if quarter_turns % 2 != 0 {
            for section in self.state.sections.borrow_mut().iter_mut() {
                for tile in section.tiles.iter_mut().flatten().filter(|tile| tile.id == id) {
                    tile.ratio = 1.0 / tile.ratio.max(0.01);
                }
            }
        }
        for row in self.state.rows.borrow().iter().filter_map(|row| row.upgrade()) {
            for tile in row.imp().tiles.borrow().iter() {
                if *tile.shows.borrow() == id {
                    tile.shows.replace(String::new());
                }
            }
        }
        self.state.rebuild();
    }

    /// The picture of a photo's square while it is on screen, for the viewer's zoom out of it and back into it.
    pub fn tile_picture(&self, id: &str) -> Option<gtk::Picture> {
        let list = &self.state.list;
        let area = gtk::graphene::Rect::new(0.0, 0.0, list.width() as f32, list.height() as f32);
        for row in self.state.rows.borrow().iter().filter_map(|row| row.upgrade()).filter(|row| row.is_mapped()) {
            for tile in row.imp().tiles.borrow().iter() {
                if *tile.shows.borrow() == id && tile.root.is_visible() {
                    let bounds = tile.picture.compute_bounds(list)?;
                    return bounds.intersection(&area).map(|_| tile.picture.clone());
                }
            }
        }
        None
    }

    /// Bring a photo's row into view, if the grid holds it: the photo the viewer showed last, as it closes.
    pub fn bring_into_view(&self, id: &str) {
        let held = self.state.sections.borrow().iter().any(|section| section.tiles.as_ref().is_some_and(|tiles| tiles.iter().any(|tile| tile.id == id)));
        if held && self.tile_picture(id).is_none() {
            self.state.scroll_to_tile(id, false);
        }
    }

    /// Read again the month that holds the photo `id`, after a change on the server that reaches past it: a stack
    /// taken apart shows its other photos again. A source without months is read again whole.
    pub fn reread_month_of(&self, id: &str) {
        let index = self.state.sections.borrow().iter().position(|section| section.month.is_some() && section.tiles.as_ref().is_some_and(|tiles| tiles.iter().any(|tile| tile.id == id)));
        let (Some(index), true) = (index, self.state.source.borrow().timeline().is_some()) else { return self.reload() };
        if let Some(section) = self.state.sections.borrow_mut().get_mut(index) {
            section.tiles = None;
        }
        self.state.load_section(index);
    }

    /// Tell the selection's handler again, after the photos selected changed (a favorite, say).
    pub fn refresh_selection(&self) {
        self.state.selection_changed();
    }

    /// Change photos in place (a favorite, say) and draw them again.
    pub fn update(&self, ids: &[String], change: impl Fn(&mut Tile)) {
        let wanted: HashSet<&String> = ids.iter().collect();
        for section in self.state.sections.borrow_mut().iter_mut() {
            for tile in section.tiles.iter_mut().flatten() {
                if wanted.contains(&tile.id) {
                    change(tile);
                }
            }
        }
        self.state.redraw_rows();
    }
}

impl State {
    fn target_height(&self) -> u32 {
        SIZES[self.size_step.get().min(SIZES.len() - 1)]
    }

    fn reload(self: &Rc<Self>) {
        self.read(false);
    }

    /// Read the sections again; with `keep`, a month read already whose count is the same keeps its tiles.
    fn read(self: &Rc<Self>, keep: bool) {
        self.generation.set(self.generation.get() + 1);
        self.loading.borrow_mut().clear();
        self.pending_move.set(None);
        self.pending_reveal.replace(None);
        let generation = self.generation.get();
        if self.sections.borrow().is_empty() {
            self.stack.set_visible_child_name("loading");
        }
        let client = self.client.clone();
        let source = self.source.borrow().clone();
        let weak = Rc::downgrade(self);
        crate::tasks::run(async move { library::sections(&client, &source).await }, move |outcome| {
            let Some(state) = weak.upgrade() else { return };
            if state.generation.get() != generation {
                return;
            }
            match outcome {
                Ok(mut sections) => {
                    if keep {
                        let known = state.sections.borrow();
                        for section in sections.iter_mut().filter(|section| section.month.is_some() && section.tiles.is_none()) {
                            section.tiles = known.iter().find(|old| old.month == section.month && old.count == section.count).and_then(|old| old.tiles.clone());
                        }
                    }
                    let total: u64 = sections.iter().map(|section| u64::from(section.count)).sum();
                    state.sections.replace(sections);
                    let ids: HashSet<String> = state.loaded_tiles().into_iter().map(|tile| tile.id).collect();
                    state.selection.borrow_mut().retain(|id| ids.contains(id) || state.sections.borrow().iter().any(|section| section.tiles.is_none()));
                    state.stack.set_visible_child_name(if total == 0 { "empty" } else { "grid" });
                    state.rebuild();
                    if let Some(loaded) = state.handlers.borrow().loaded.clone() {
                        loaded(total);
                    }
                    if let Some((month, id)) = state.reveal_when_read.take() {
                        state.reveal(month, &id);
                    }
                }
                Err(message) => {
                    state.failed.set_description(Some(&message));
                    state.stack.set_visible_child_name("failed");
                    if let Some(failed) = state.handlers.borrow().failed.clone() {
                        failed(&message);
                    }
                }
            }
        });
    }

    /// The rows' width, beside the scrubber where it shows.
    fn rows_width(&self, beside_scrubber: bool) -> u32 {
        let beside = if beside_scrubber { crate::scrubber::WIDTH as u32 } else { 0 };
        self.width.get().saturating_sub(2 * MARGIN as u32 + beside).max(1)
    }

    /// The rows of one section at the current width.
    fn rows_for(&self, index: usize, section: &Section) -> Vec<RowModel> {
        let width = self.rows_width(self.scrubber.is_visible());
        let target = self.target_height();
        let mut rows = Vec::new();
        if section.month.is_some() {
            rows.push(RowModel::Header { section: index });
        }
        match &section.tiles {
            Some(tiles) => {
                let laid = if self.square.get() {
                    layout::squares(tiles.len(), width, target, SPACING)
                } else {
                    let ratios: Vec<f64> = tiles.iter().map(|tile| tile.ratio).collect();
                    layout::justified(&ratios, width, target, SPACING)
                };
                rows.extend(laid.into_iter().map(|row| RowModel::Tiles { section: index, row }));
            }
            None => {
                let count = section.count as usize;
                let laid = if self.square.get() {
                    layout::squares(count, width, target, SPACING)
                } else {
                    layout::justified(&vec![ESTIMATED_RATIO; count], width, target, SPACING)
                };
                rows.extend(laid.into_iter().map(|row| RowModel::Placeholder { section: index, row }));
            }
        }
        rows
    }

    fn objects(rows: Vec<RowModel>) -> Vec<glib::BoxedAnyObject> {
        rows.into_iter().map(glib::BoxedAnyObject::new).collect()
    }

    /// The scrubber, for a grid of months: their counts, and the rows they are laid out in; the scrollbar gives way to it.
    fn refresh_scrubber(&self) {
        let months: Vec<(immich_api::YearMonth, u32)> = self.sections.borrow().iter().map_while(|section| section.month.map(|month| (month, section.count))).collect();
        let shown = months.len() >= 2 && months.len() == self.sections.borrow().len() && date_scroller_shown();
        let (columns, row_height) = self.scrubber_rows(self.rows_width(shown));
        self.scrubber.set_months(if shown { months } else { Vec::new() }, columns, row_height, f64::from(HEADER_HEIGHT));
        self.scrolled.set_vscrollbar_policy(if shown { gtk::PolicyType::External } else { gtk::PolicyType::Automatic });
        // The grid lays out beside it, not under it.
        self.scrolled.set_margin_end(if shown { crate::scrubber::WIDTH } else { 0 });
    }

    /// The rows the scrubber reckons months in: how many photos a row holds and its height with the space below it, as a
    /// month not read yet is laid out (its placeholders at a typical shape, or squares); a month read comes near it.
    fn scrubber_rows(&self, width: u32) -> (u32, f64) {
        let target = self.target_height();
        let rows = if self.square.get() {
            layout::squares(ROW_SAMPLE, width, target, SPACING)
        } else {
            layout::justified(&[ESTIMATED_RATIO; ROW_SAMPLE], width, target, SPACING)
        };
        rows.first().map_or((1, f64::from(target + SPACING)), |row| (row.len() as u32, f64::from(row.height + SPACING)))
    }

    /// With `VERSO_SCROLL_LOG` set, each frame's scroll position and every row on screen, by what it shows and where,
    /// on standard error: a row whose place on the page (scroll position plus its place on screen) changes from one
    /// frame to the next is the list moving it, not the scrolling (the jump seen scrolling up).
    fn log_frames(self: &Rc<Self>) {
        if std::env::var_os("VERSO_SCROLL_LOG").is_none() {
            return;
        }
        let weak = Rc::downgrade(self);
        self.list.add_tick_callback(move |list, clock| {
            let Some(state) = weak.upgrade() else { return glib::ControlFlow::Break };
            let Some(adjustment) = list.vadjustment() else { return glib::ControlFlow::Continue };
            let rows: Vec<String> = state
                .rows
                .borrow()
                .iter()
                .filter_map(|row| row.upgrade())
                .filter(|row| row.is_mapped())
                .filter_map(|row| {
                    let y = row.compute_point(list, &gtk::graphene::Point::new(0.0, 0.0))?.y();
                    let shown = match row.imp().model.borrow().as_ref()? {
                        RowModel::Header { section } => format!("h{section}"),
                        RowModel::Tiles { section, row } => format!("t{section}.{}", row.start),
                        RowModel::Placeholder { section, row } => format!("p{section}.{}", row.start),
                    };
                    (y > -400.0 && y < list.height() as f32 + 400.0).then(|| format!("{shown}@{y:.1}h{}", row.height()))
                })
                .collect();
            eprintln!("FRAME {} v={:.1} up={:.1} {}", clock.frame_time(), adjustment.value(), adjustment.upper(), rows.join(" "));
            glib::ControlFlow::Continue
        });
    }

    /// The section shown at the top of the grid.
    fn top_section(&self) -> Option<usize> {
        let rows = self.rows.borrow();
        rows.iter()
            .filter_map(|row| row.upgrade())
            .filter(|row| row.is_mapped())
            .filter_map(|row| {
                let y = row.compute_point(&self.list, &gtk::graphene::Point::new(0.0, 0.0))?.y();
                let section = match row.imp().model.borrow().as_ref()? {
                    RowModel::Tiles { section, .. } | RowModel::Header { section } | RowModel::Placeholder { section, .. } => *section,
                };
                (y + row.height() as f32 > 0.0).then_some((y, section))
            })
            .min_by(|first, second| first.0.total_cmp(&second.0))
            .map(|(_, section)| section)
    }

    /// Where the grid is, for the scrubber's mark: the place at the top of the list, in the scrubber's rows.
    fn top_place(&self) -> Option<Place> {
        let columns = self.scrubber.columns() as usize;
        let row_height = self.scrubber.row_height();
        let rows = self.rows.borrow();
        let (y, row) = rows
            .iter()
            .filter_map(|row| row.upgrade())
            .filter(|row| row.is_mapped())
            .filter_map(|row| {
                let y = row.compute_point(&self.list, &gtk::graphene::Point::new(0.0, 0.0))?.y();
                (y + row.height() as f32 > 0.0).then_some((y, row))
            })
            .min_by(|first, second| first.0.total_cmp(&second.0))?;
        let past = f64::from((-y).max(0.0));
        let model = row.imp().model.borrow().clone()?;
        match model {
            RowModel::Header { section } => Some(Place { month: section, row: None, offset: past }),
            RowModel::Tiles { section, row: tiles } | RowModel::Placeholder { section, row: tiles } => {
                let into = past / f64::from(row.height().max(1)) * row_height;
                Some(Place { month: section, row: Some((tiles.start / columns.max(1)) as u32), offset: into })
            }
        }
    }

    /// Scroll to the place the scrubber points at: a month's heading, or the row with the photo its rows reckon is at
    /// the top there. A month not read yet is laid out as placeholders, so once it is read the jump lands again.
    fn scroll_to_place(self: &Rc<Self>, place: Place) {
        let tile = place.row.map(|row| row as usize * self.scrubber.columns() as usize);
        let unread = self.sections.borrow().get(place.month).is_some_and(|section| section.tiles.is_none());
        self.pending_place.set(tile.filter(|_| unread).map(|tile| (place.month, tile)));
        self.scroll_to_row(place.month, tile);
    }

    /// Put a section's heading (`tile` none), or its row with photo `tile`, at the top, reading the section if need be.
    fn scroll_to_row(self: &Rc<Self>, section: usize, tile: Option<usize>) {
        let Some(position) = self.row_position(section, tile) else { return };
        self.list.scroll_to(position as u32, gtk::ListScrollFlags::NONE, None);
        self.load_section(section);
        let jump = self.row_jumps.get() + 1;
        self.row_jumps.set(jump);
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            let Some(state) = weak.upgrade().filter(|state| state.row_jumps.get() == jump) else { return };
            let target = state.rows.borrow().iter().filter_map(|row| row.upgrade()).find(|row| {
                row.is_mapped() && row.imp().model.borrow().as_ref().is_some_and(|model| shows(model, section, tile))
            });
            if let (Some(target), Some(adjustment)) = (target, state.list.vadjustment()) {
                if let Some(point) = target.compute_point(&state.list, &gtk::graphene::Point::new(0.0, 0.0)) {
                    // Just past the row, then back to it. The list holds what it last scrolled to at the edge it came
                    // in at: from above, a jump down, that is the bottom, and the month read in between pushes the row
                    // down; from below, it is the top, where it stays as the months around it are read.
                    adjustment.set_value(adjustment.value() + f64::from(point.y()) + 1.0);
                    if let Some(position) = state.row_position(section, tile) {
                        state.list.scroll_to(position as u32, gtk::ListScrollFlags::NONE, None);
                    }
                }
            }
        });
    }

    /// Where a section's heading is in the list (`tile` none), or its row with photo `tile` (its last, past its end).
    fn row_position(&self, section: usize, tile: Option<usize>) -> Option<usize> {
        let range = self.section_rows.borrow().get(section).cloned()?;
        let Some(tile) = tile else { return Some(range.start) };
        let mut found = None;
        for position in range {
            let Some(object) = self.store.item(position as u32).and_downcast::<glib::BoxedAnyObject>() else { continue };
            let end = match &*object.borrow::<RowModel>() {
                RowModel::Tiles { row, .. } | RowModel::Placeholder { row, .. } => row.start + row.len(),
                RowModel::Header { .. } => continue,
            };
            found = Some(position);
            if tile < end {
                break;
            }
        }
        found
    }

    /// Lay out every section again (a new width, size or shape), keeping the first photo on screen in view.
    fn rebuild(&self) {
        if self.width.get() == 0 {
            return;
        }
        // At the top, the grid stays at the top; else the first photo on screen stays in view.
        let at_top = self.list.vadjustment().is_none_or(|adjustment| adjustment.value() < 1.0);
        let anchor = if at_top { None } else { self.first_visible_tile() };
        // The scrubber first: whether it shows decides the width the rows have.
        self.refresh_scrubber();
        let mut all = Vec::new();
        let mut ranges = Vec::new();
        for (index, section) in self.sections.borrow().iter().enumerate() {
            let start = all.len();
            all.extend(self.rows_for(index, section));
            ranges.push(start..all.len());
        }
        let anchor_row = anchor.and_then(|(section, tile_index)| {
            all.iter().position(|row| match row {
                RowModel::Tiles { section: row_section, row } => *row_section == section && (row.start..row.start + row.len()).contains(&tile_index),
                _ => false,
            })
        });
        self.section_rows.replace(ranges);
        self.store.splice(0, self.store.n_items(), &Self::objects(all));
        if let Some(top) = self.top_place() {
            self.scrubber.set_current(Some(top));
        }
        if let Some(position) = anchor_row {
            self.list.scroll_to(position as u32, gtk::ListScrollFlags::NONE, None);
        }
    }

    /// Lay out one section again, after its photos were read. Its heading stays the same row: the list keeps what is on
    /// screen in place by a row there, often the heading a jump went to, and a row taken out loses that place.
    fn replace_section(&self, index: usize) {
        let mut rows = {
            let sections = self.sections.borrow();
            let Some(section) = sections.get(index) else { return };
            self.rows_for(index, section)
        };
        let count = rows.len();
        let kept_heading = matches!(rows.first(), Some(RowModel::Header { .. }));
        if kept_heading {
            rows.remove(0);
        }
        // The ranges first, and let go of: the splice binds rows, and a bind reads them.
        let range = {
            let mut ranges = self.section_rows.borrow_mut();
            let Some(range) = ranges.get(index).cloned() else { return };
            let delta = count as isize - range.len() as isize;
            ranges[index] = range.start..range.start + count;
            for later in ranges.iter_mut().skip(index + 1) {
                *later = (later.start as isize + delta) as usize..(later.end as isize + delta) as usize;
            }
            range
        };
        let skip = usize::from(kept_heading);
        self.store.splice((range.start + skip) as u32, (range.len() - skip) as u32, &Self::objects(rows));
        // The kept heading's count, as read.
        if kept_heading {
            for row in self.rows.borrow().iter().filter_map(|row| row.upgrade()) {
                let model = row.imp().model.borrow().clone().filter(|model| matches!(model, RowModel::Header { section } if *section == index));
                if let Some(model) = model {
                    row.bind(self, model);
                }
            }
        }
    }

    /// Read the months around one being shown, a few screens' worth each way, so a month is read before it scrolls into
    /// view, up as well as down: a month read where it shows changes size under the eye, its estimated rows giving way
    /// to its real ones, and what is on screen slides (scrolling up after the scrubber, most of all).
    fn preload_around(self: &Rc<Self>, section: usize) {
        let counts: Vec<usize> = self.section_rows.borrow().iter().map(|range| range.len()).collect();
        for index in around(&counts, section, PRELOAD_ROWS) {
            self.load_section(index);
        }
    }

    /// Read a timeline's month, once, when its rows come into view.
    fn load_section(self: &Rc<Self>, index: usize) {
        let Some((scope, options)) = self.source.borrow().timeline() else { return };
        let month = {
            let sections = self.sections.borrow();
            match sections.get(index) {
                Some(section) if section.tiles.is_none() => section.month,
                _ => None,
            }
        };
        let Some(month) = month else { return };
        if !self.loading.borrow_mut().insert(index) {
            return;
        }
        let generation = self.generation.get();
        let client = self.client.clone();
        let weak = Rc::downgrade(self);
        // Off the bind that asked: the list must not change while it binds a row.
        crate::tasks::run(async move { library::month_with(&client, &scope, &options, month).await }, move |outcome| {
            let Some(state) = weak.upgrade() else { return };
            if state.generation.get() != generation {
                return;
            }
            state.loading.borrow_mut().remove(&index);
            match outcome {
                Ok(tiles) => {
                    if let Some(section) = state.sections.borrow_mut().get_mut(index) {
                        section.count = tiles.len() as u32;
                        section.tiles = Some(tiles);
                    }
                    state.replace_section(index);
                    // The scrubber's jump into this month lands on its photo's row as read, if the grid is still there.
                    if let Some((_, tile)) = state.pending_place.get().filter(|(section, _)| *section == index) {
                        state.pending_place.set(None);
                        if state.top_section() == Some(index) {
                            state.scroll_to_row(index, Some(tile));
                        }
                    }
                    // A key waiting for a month moves now; if it still needs another, it asks for that one.
                    if let Some((step, extend)) = state.pending_move.take() {
                        state.move_cursor(step, extend);
                    }
                    let revealed = state.pending_reveal.borrow().clone().filter(|id| state.sections.borrow().get(index).and_then(|section| section.tiles.as_ref()).is_some_and(|tiles| tiles.iter().any(|tile| tile.id == *id)));
                    if let Some(id) = revealed {
                        state.pending_reveal.replace(None);
                        state.scroll_to_tile(&id, true);
                    }
                }
                Err(message) => {
                    state.pending_move.set(None);
                    if let Some(failed) = state.handlers.borrow().failed.clone() {
                        failed(&message);
                    }
                }
            }
        });
    }

    fn loaded_tiles(&self) -> Vec<Tile> {
        self.sections.borrow().iter().flat_map(|section| section.tiles.iter().flatten().cloned()).collect()
    }

    fn tile(&self, section: usize, index: usize) -> Option<Tile> {
        self.sections.borrow().get(section)?.tiles.as_ref()?.get(index).cloned()
    }

    /// The section and index of the first photo in a row on screen.
    fn first_visible_tile(&self) -> Option<(usize, usize)> {
        let rows = self.rows.borrow();
        let list_height = self.list.height();
        rows.iter()
            .filter_map(|row| row.upgrade())
            .filter(|row| row.is_mapped())
            .filter_map(|row| {
                let point = row.compute_point(&self.list, &gtk::graphene::Point::new(0.0, 0.0))?;
                let y = point.y();
                (y + row.height() as f32 > 0.0 && y < list_height as f32).then_some((y, row))
            })
            .min_by(|first, second| first.0.total_cmp(&second.0))
            .and_then(|(_, row)| match row.imp().model.borrow().clone()? {
                RowModel::Tiles { section, row } => Some((section, row.start)),
                RowModel::Header { section } => Some((section, 0)),
                RowModel::Placeholder { .. } => None,
            })
    }

    /// The rows of photos as laid out now: section, first index, and each tile's left edge and width.
    fn tile_rows(&self) -> Vec<(usize, layout::Row)> {
        (0..self.store.n_items())
            .filter_map(|position| self.store.item(position).and_downcast::<glib::BoxedAnyObject>())
            .filter_map(|object| match object.borrow::<RowModel>().clone() {
                RowModel::Tiles { section, row } => Some((section, row)),
                _ => None,
            })
            .collect()
    }

    /// Show a photo of a month, ringed (see [`Grid::reveal`]).
    fn reveal(self: &Rc<Self>, month: immich_api::YearMonth, id: &str) {
        let state = self;
        if state.sections.borrow().is_empty() {
            state.reveal_when_read.replace(Some((month, id.to_owned())));
            return;
        }
        state.cursor.replace(Some(id.to_owned()));
        state.anchor.replace(Some(id.to_owned()));
        if !state.selecting.get() {
            let mut selection = state.selection.borrow_mut();
            selection.clear();
            selection.insert(id.to_owned());
        }
        state.selection_changed();
        let index = state.sections.borrow().iter().position(|section| section.month == Some(month));
        let Some(index) = index else { return };
        if state.unread(index) {
            if let Some(start) = state.section_rows.borrow().get(index).map(|range| range.start) {
                state.list.scroll_to(start as u32, gtk::ListScrollFlags::NONE, None);
            }
            state.pending_reveal.replace(Some(id.to_owned()));
            state.load_section(index);
        } else {
            state.scroll_to_tile(id, true);
        }
    }

    /// Whether a month of the timeline is still to be read (its rows are placeholders).
    fn unread(&self, index: usize) -> bool {
        self.source.borrow().timeline().is_some() && self.sections.borrow().get(index).is_some_and(|section| section.tiles.is_none() && section.month.is_some())
    }

    /// The month a move needs read first, if any: the first or last month for Home and End, the next or previous
    /// for a step off the edge of the month the ring is in.
    fn month_needed(&self, step: Move, current: Option<&str>) -> Option<usize> {
        let count = self.sections.borrow().len();
        let here = current.and_then(|id| {
            let sections = self.sections.borrow();
            sections.iter().enumerate().find_map(|(index, section)| section.tiles.as_ref()?.iter().position(|tile| tile.id == id).map(|position| (index, position, section.tiles.as_ref().map_or(0, Vec::len))))
        });
        let needed = match (step, here) {
            (Move::Last, _) => (0..count).rev().find(|index| !self.sections.borrow()[*index].tiles.as_ref().is_some_and(Vec::is_empty))?,
            (Move::First, _) | (_, None) => (0..count).find(|index| !self.sections.borrow()[*index].tiles.as_ref().is_some_and(Vec::is_empty))?,
            (Move::Left, Some((section, 0, _))) => section.checked_sub(1)?,
            (Move::Right, Some((section, position, length))) if position + 1 == length => section + 1,
            (Move::Up, Some((section, position, _))) => {
                let first_row = self.tile_rows().into_iter().find(|(row_section, _)| *row_section == section)?;
                if position >= first_row.1.len() {
                    return None;
                }
                section.checked_sub(1)?
            }
            (Move::Down, Some((section, position, _))) => {
                let last_row = self.tile_rows().into_iter().rev().find(|(row_section, _)| *row_section == section)?;
                if position < last_row.1.start {
                    return None;
                }
                section + 1
            }
            _ => return None,
        };
        self.unread(needed).then_some(needed)
    }

    fn move_cursor(self: &Rc<Self>, step: Move, extend: bool) {
        // Into a month not read yet: read it (bringing it into view), and move once it is here.
        let ringed = self.cursor.borrow().clone();
        if let Some(index) = self.month_needed(step, ringed.as_deref()) {
            self.pending_move.set(Some((step, extend)));
            if let Some(start) = self.section_rows.borrow().get(index).map(|range| range.start) {
                self.list.scroll_to(start as u32, gtk::ListScrollFlags::NONE, None);
            }
            self.load_section(index);
            return;
        }
        let tiles = self.loaded_tiles();
        if tiles.is_empty() {
            return;
        }
        let current = self.cursor.borrow().clone().and_then(|id| tiles.iter().position(|tile| tile.id == id));
        let target = match (current, step) {
            (_, Move::Last) => tiles.len() - 1,
            (None, _) | (_, Move::First) => 0,
            (Some(here), Move::Left) => here.saturating_sub(1),
            (Some(here), Move::Right) => (here + 1).min(tiles.len() - 1),
            (Some(here), Move::Up | Move::Down) => {
                // The photo in the row above or below whose middle is nearest this one's.
                let rows = self.tile_rows();
                let sections = self.sections.borrow();
                let flat = |section: usize, index: usize| -> usize {
                    sections.iter().take(section).map(|section| section.tiles.as_ref().map_or(0, Vec::len)).sum::<usize>() + index
                };
                let Some(row_index) = rows.iter().position(|(section, row)| (flat(*section, row.start)..flat(*section, row.start) + row.len()).contains(&here)) else {
                    return;
                };
                let (section, row) = &rows[row_index];
                let middle = |row: &layout::Row, offset: usize| -> i64 {
                    let left: u32 = row.widths.iter().take(offset).map(|width| width + SPACING).sum();
                    i64::from(left) + i64::from(row.widths[offset] / 2)
                };
                let here_middle = middle(row, here - flat(*section, row.start));
                let next_row = if step == Move::Up { row_index.checked_sub(1) } else { Some(row_index + 1).filter(|index| *index < rows.len()) };
                let Some(next_row) = next_row else { return };
                let (next_section, next) = &rows[next_row];
                let nearest = (0..next.len()).min_by_key(|offset| (middle(next, *offset) - here_middle).abs()).unwrap_or(0);
                flat(*next_section, next.start + nearest)
            }
        };
        let id = tiles[target].id.clone();
        if extend {
            let anchor = self.anchor.borrow().clone().and_then(|anchor| tiles.iter().position(|tile| tile.id == anchor)).or(current).unwrap_or(target);
            let (from, to) = (anchor.min(target), anchor.max(target));
            let mut selection = self.selection.borrow_mut();
            selection.clear();
            selection.extend(tiles[from..=to].iter().map(|tile| tile.id.clone()));
            drop(selection);
            self.selecting.set(true);
        } else {
            self.anchor.replace(Some(id.clone()));
            if !self.selecting.get() {
                // As in Files: outside selection mode the selection follows the ring, so what a key acts on is
                // the photo ringed.
                let mut selection = self.selection.borrow_mut();
                selection.clear();
                selection.insert(id.clone());
            }
        }
        self.cursor.replace(Some(id.clone()));
        // Bring its row into view; moving up into a month's first row, its heading comes into view with it.
        self.scroll_to_tile(&id, matches!(step, Move::Up | Move::Left | Move::First));
        self.selection_changed();
    }

    /// Bring a photo's row into view, and with `heading`, its month's heading too when it is the first row.
    fn scroll_to_tile(&self, id: &str, heading: bool) {
        let position = (0..self.store.n_items()).find(|position| {
            self.store.item(*position).and_downcast::<glib::BoxedAnyObject>().is_some_and(|object| match &*object.borrow::<RowModel>() {
                RowModel::Tiles { section, row } => self.sections.borrow().get(*section).and_then(|section| section.tiles.as_ref()).is_some_and(|tiles| tiles[row.start..row.start + row.len()].iter().any(|tile| tile.id == id)),
                _ => false,
            })
        });
        if let Some(position) = position {
            let heading_above = position > 0 && self.store.item(position - 1).and_downcast::<glib::BoxedAnyObject>().is_some_and(|object| matches!(&*object.borrow::<RowModel>(), RowModel::Header { .. }));
            self.list.scroll_to(if heading && heading_above { position - 1 } else { position }, gtk::ListScrollFlags::NONE, None);
        }
    }

    fn redraw_rows(&self) {
        let rows: Vec<GridRow> = self.rows.borrow().iter().filter_map(|row| row.upgrade()).collect();
        for row in rows {
            // Cloned out first: binding replaces the model, which must not be borrowed then.
            let model = row.imp().model.borrow().clone();
            if let Some(model) = model {
                row.bind(self, model);
            }
        }
    }

    fn selection_changed(&self) {
        self.redraw_rows();
        if let Some(handler) = self.handlers.borrow().selection_changed.clone() {
            handler();
        }
    }

    /// A click on a photo, with the keys held.
    fn clicked(&self, section: usize, index: usize, modifiers: gdk::ModifierType) {
        let Some(tile) = self.tile(section, index) else { return };
        self.cursor.replace(Some(tile.id.clone()));
        if modifiers.contains(gdk::ModifierType::SHIFT_MASK) {
            let tiles = self.loaded_tiles();
            let here = tiles.iter().position(|candidate| candidate.id == tile.id).unwrap_or(0);
            let anchor = self.anchor.borrow().clone().and_then(|anchor| tiles.iter().position(|tile| tile.id == anchor)).unwrap_or(here);
            let (from, to) = (anchor.min(here), anchor.max(here));
            self.selection.borrow_mut().extend(tiles[from..=to].iter().map(|tile| tile.id.clone()));
            self.selecting.set(true);
            self.selection_changed();
        } else if modifiers.contains(gdk::ModifierType::CONTROL_MASK) || self.selecting.get() {
            {
                let mut selection = self.selection.borrow_mut();
                if !selection.remove(&tile.id) {
                    selection.insert(tile.id.clone());
                }
            }
            self.anchor.replace(Some(tile.id));
            self.selecting.set(true);
            self.selection_changed();
        } else {
            // A click selects the photo alone, as in Files and the Mac gallery; a double click opens it.
            {
                let mut selection = self.selection.borrow_mut();
                selection.clear();
                selection.insert(tile.id.clone());
            }
            self.anchor.replace(Some(tile.id));
            self.selection_changed();
        }
    }

    /// Open a photo (a double click).
    fn opened(&self, section: usize, index: usize) {
        let Some(tile) = self.tile(section, index) else { return };
        let tiles = self.loaded_tiles();
        let position = tiles.iter().position(|candidate| candidate.id == tile.id).unwrap_or(0);
        if let Some(open) = self.handlers.borrow().open.clone() {
            open(tiles, position);
        }
    }

    fn clear_selection(&self) {
        if self.selection.borrow().is_empty() {
            return;
        }
        self.selection.borrow_mut().clear();
        self.selection_changed();
    }

    /// A right-click on a photo: it joins the selection, or becomes it when it was not selected.
    fn context(&self, section: usize, index: usize, widget: &gtk::Widget, x: f64, y: f64) {
        let Some(tile) = self.tile(section, index) else { return };
        self.cursor.replace(Some(tile.id.clone()));
        if !self.selection.borrow().contains(&tile.id) {
            let mut selection = self.selection.borrow_mut();
            selection.clear();
            selection.insert(tile.id.clone());
        }
        self.selection_changed();
        if let Some(context) = self.handlers.borrow().context.clone() {
            context(widget, x, y);
        }
    }
}

/// Whether a widget shows in its scrolled window now.
fn on_screen(widget: &gtk::Widget) -> bool {
    if !widget.is_mapped() {
        return false;
    }
    let Some(scrolled) = widget.ancestor(gtk::ScrolledWindow::static_type()) else { return false };
    let Some(bounds) = widget.compute_bounds(&scrolled) else { return false };
    bounds.y() + bounds.height() > 0.0 && bounds.y() < scrolled.height() as f32
}

/// One photo's widgets in a row.
pub struct TileWidgets {
    root: gtk::Overlay,
    picture: gtk::Picture,
    duration: gtk::Label,
    favorite: gtk::Image,
    /// A stack's cover: the stack's badge, with how many photos it holds.
    stack: gtk::Box,
    stack_count: gtk::Label,
    live: gtk::Image,
    check: gtk::Image,
    /// Where the photo was taken, on pages about places (Assign Location).
    place: gtk::Label,
    /// The photo it shows now, so a thumbnail that arrives late lands only on its own tile.
    shows: Rc<RefCell<String>>,
}

impl TileWidgets {
    fn new(parent: &GridRow) -> TileWidgets {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let root = gtk::Overlay::builder().child(&picture).overflow(gtk::Overflow::Hidden).build();
        root.add_css_class("gallery-tile");
        // Along the bottom, as the Mac gallery's: a favorite at the start; at the end a stack with its count, a Live
        // Photo, and a video's length.
        let favorite = gtk::Image::builder().icon_name("verso-heart-symbolic").halign(gtk::Align::Start).valign(gtk::Align::End).css_classes(["gallery-badge"]).visible(false).build();
        let stack_count = gtk::Label::new(None);
        let stack = gtk::Box::builder().spacing(2).visible(false).build();
        stack.append(&gtk::Image::from_icon_name("verso-stack-symbolic"));
        stack.append(&stack_count);
        let live = gtk::Image::builder().icon_name("verso-live-symbolic").visible(false).build();
        let duration = gtk::Label::builder().css_classes(["numeric"]).visible(false).build();
        let corner = gtk::Box::builder().spacing(6).halign(gtk::Align::End).valign(gtk::Align::End).css_classes(["gallery-badge"]).build();
        corner.append(&stack);
        corner.append(&live);
        corner.append(&duration);
        let check = gtk::Image::builder().halign(gtk::Align::Start).valign(gtk::Align::Start).css_classes(["gallery-check"]).visible(false).build();
        let place = gtk::Label::builder().halign(gtk::Align::Center).valign(gtk::Align::End).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["gallery-badge", "gallery-place"]).visible(false).build();
        for overlay in [corner.upcast_ref::<gtk::Widget>(), favorite.upcast_ref(), check.upcast_ref(), place.upcast_ref()] {
            overlay.set_can_target(false);
            root.add_overlay(overlay);
        }
        root.set_parent(parent);
        TileWidgets { root, picture, duration, favorite, stack, stack_count, live, check, place, shows: Rc::default() }
    }

    fn show(&self, state: &State, tile: &Tile) {
        let changed = *self.shows.borrow() != tile.id;
        if changed {
            self.shows.replace(tile.id.clone());
            match state.textures.cached(Kind::Thumbnail, &tile.id, tile.thumbhash.as_deref()) {
                Some(texture) => self.picture.set_paintable(Some(&texture)),
                None => {
                    let placeholder = tile.thumbhash.as_deref().and_then(|hash| state.textures.placeholder(hash));
                    self.picture.set_paintable(placeholder.as_ref());
                    let (picture, shows, id) = (self.picture.downgrade(), self.shows.clone(), tile.id.clone());
                    let (watched, watched_shows, watched_id) = (self.picture.downgrade(), self.shows.clone(), tile.id.clone());
                    let wanted = move || {
                        let Some(picture) = watched.upgrade() else { return Wanted::No };
                        if *watched_shows.borrow() != watched_id {
                            return Wanted::No;
                        }
                        if on_screen(picture.upcast_ref()) {
                            Wanted::Now
                        } else {
                            Wanted::Later
                        }
                    };
                    state.textures.get_while(Kind::Thumbnail, &tile.id, tile.thumbhash.as_deref(), wanted, move |texture| {
                        if let (Some(picture), Some(texture)) = (picture.upgrade(), texture) {
                            if *shows.borrow() == id {
                                picture.set_paintable(Some(&texture));
                            }
                        }
                    });
                }
            }
        }
        self.root.remove_css_class("gallery-placeholder");
        self.duration.set_visible(tile.is_video);
        if let Some(duration) = tile.duration_ms.filter(|_| tile.is_video) {
            self.duration.set_label(&text::duration(duration));
        } else {
            self.duration.set_label("");
        }
        self.favorite.set_visible(tile.is_favorite);
        // On Assign Location: the city, "GPS" for coordinates without one, or "No GPS".
        self.place.set_visible(state.place_badges.get());
        if state.place_badges.get() {
            self.place.set_label(&match (tile.located, &tile.city) {
                (_, Some(city)) => city.clone(),
                (Some(true), None) => tr("GPS").to_owned(),
                _ => tr("No GPS").to_owned(),
            });
        }
        self.stack.set_visible(tile.stack.is_some());
        if let Some((_, count)) = &tile.stack {
            self.stack_count.set_label(&count.to_string());
        }
        self.live.set_visible(tile.is_live);
        if state.cursor.borrow().as_deref() == Some(tile.id.as_str()) {
            self.root.add_css_class("cursor");
        } else {
            self.root.remove_css_class("cursor");
        }
        let selected = state.selection.borrow().contains(&tile.id);
        self.check.set_visible(state.selecting.get() || selected);
        self.check.set_icon_name(Some(if selected { "object-select-symbolic" } else { "" }));
        if selected {
            self.root.add_css_class("selected");
            self.check.add_css_class("checked");
        } else {
            self.root.remove_css_class("selected");
            self.check.remove_css_class("checked");
        }
        self.root.update_property(&[gtk::accessible::Property::Label(&text::taken(tile.taken))]);
    }

    fn show_placeholder(&self) {
        self.shows.replace(String::new());
        self.picture.set_paintable(gdk::Paintable::NONE);
        self.root.add_css_class("gallery-placeholder");
        self.root.remove_css_class("selected");
        for badge in [self.duration.upcast_ref::<gtk::Widget>(), self.favorite.upcast_ref(), self.stack.upcast_ref(), self.live.upcast_ref(), self.check.upcast_ref()] {
            badge.set_visible(false);
        }
    }
}

mod row_imp {
    use super::*;

    #[derive(Default)]
    pub struct GridRow {
        pub header: RefCell<Option<gtk::Box>>,
        pub title: RefCell<Option<gtk::Label>>,
        pub count: RefCell<Option<gtk::Label>>,
        pub tiles: RefCell<Vec<TileWidgets>>,
        pub geometry: RefCell<Vec<(i32, i32)>>,
        pub height: Cell<i32>,
        pub is_header: Cell<bool>,
        /// A long press just selected: the release that ends it is not a click.
        pub long_pressed: Cell<bool>,
        pub model: RefCell<Option<RowModel>>,
        pub state: RefCell<Weak<State>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridRow {
        const NAME: &'static str = "ImmichGalleryGridRow";
        type Type = super::GridRow;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for GridRow {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for GridRow {
        fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            if orientation == gtk::Orientation::Vertical {
                let height = if self.is_header.get() { HEADER_HEIGHT } else { self.height.get() + SPACING as i32 };
                (height, height, -1, -1)
            } else {
                (0, 0, -1, -1)
            }
        }

        fn size_allocate(&self, width: i32, _height: i32, _baseline: i32) {
            if let Some(header) = self.header.borrow().as_ref() {
                if self.is_header.get() {
                    header.size_allocate(&gtk::Allocation::new(MARGIN, 0, (width - 2 * MARGIN).max(1), HEADER_HEIGHT), -1);
                }
            }
            let geometry = self.geometry.borrow();
            for (tile, (x, tile_width)) in self.tiles.borrow().iter().zip(geometry.iter()) {
                tile.root.size_allocate(&gtk::Allocation::new(MARGIN + x, 0, *tile_width, self.height.get()), -1);
            }
        }
    }
}

glib::wrapper! {
    pub struct GridRow(ObjectSubclass<row_imp::GridRow>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl GridRow {
    fn new(state: Weak<State>) -> GridRow {
        let row: GridRow = glib::Object::new();
        row.imp().state.replace(state);
        let title = gtk::Label::builder().xalign(0.0).hexpand(true).css_classes(["gallery-month"]).build();
        let count = gtk::Label::builder().xalign(1.0).css_classes(["dim-label", "numeric"]).build();
        let header = gtk::Box::builder().spacing(12).valign(gtk::Align::End).margin_bottom(8).build();
        header.append(&title);
        header.append(&count);
        header.set_parent(&row);
        header.set_child_visible(false);
        row.imp().header.replace(Some(header));
        row.imp().title.replace(Some(title));
        row.imp().count.replace(Some(count));

        let click = gtk::GestureClick::builder().button(0).build();
        let weak_row = row.downgrade();
        click.connect_released(move |gesture, presses, x, _y| {
            let Some(row) = weak_row.upgrade() else { return };
            let button = gesture.current_button();
            if row.imp().long_pressed.replace(false) || button == gdk::BUTTON_SECONDARY || presses > 2 {
                return;
            }
            // A double click opens the photo; the first click of it selected it.
            if presses == 2 {
                if let Some((section, index)) = row.tile_at(x) {
                    if let Some(state) = row.imp().state.borrow().upgrade() {
                        state.opened(section, index);
                    }
                }
                return;
            }
            if let Some(host) = row.ancestor(GridHost::static_type()) {
                host.grab_focus();
            }
            let state = row.imp().state.borrow().upgrade();
            match (row.tile_at(x), state) {
                (Some((section, index)), Some(state)) => state.clicked(section, index, gesture.current_event_state()),
                // A click beside the photos clears the selection, as in Files.
                (None, Some(state)) if !gesture.current_event_state().intersects(gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::CONTROL_MASK) && !state.selecting.get() => state.clear_selection(),
                _ => {}
            };
        });
        row.add_controller(click);
        let menu_click = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
        let weak_row = row.downgrade();
        menu_click.connect_pressed(move |_, _, x, y| {
            let Some(row) = weak_row.upgrade() else { return };
            if let Some((section, index)) = row.tile_at(x) {
                if let Some(state) = row.imp().state.borrow().upgrade() {
                    state.context(section, index, row.upcast_ref(), x, y);
                }
            }
        });
        row.add_controller(menu_click);
        let press = gtk::GestureLongPress::new();
        let weak_row = row.downgrade();
        press.connect_pressed(move |_, x, _| {
            let Some(row) = weak_row.upgrade() else { return };
            if let Some((section, index)) = row.tile_at(x) {
                if let Some(state) = row.imp().state.borrow().upgrade() {
                    row.imp().long_pressed.set(true);
                    state.selecting.set(true);
                    state.clicked(section, index, gdk::ModifierType::empty());
                }
            }
        });
        row.add_controller(press);
        // Dragging photos out: the selection when the photo is in it, else the photo alone.
        let drag = gtk::DragSource::builder().actions(gdk::DragAction::COPY).build();
        let weak_row = row.downgrade();
        drag.connect_prepare(move |source, x, _y| {
            let row = weak_row.upgrade()?;
            let (section, index) = row.tile_at(x)?;
            let state = row.imp().state.borrow().upgrade()?;
            let tile = state.tile(section, index)?;
            let selection = state.selection.borrow().clone();
            let ids: Vec<String> = if selection.contains(&tile.id) {
                state.loaded_tiles().into_iter().filter(|candidate| selection.contains(&candidate.id)).map(|candidate| candidate.id).collect()
            } else {
                vec![tile.id.clone()]
            };
            if let Some(texture) = state.textures.cached(Kind::Thumbnail, &tile.id, tile.thumbhash.as_deref()) {
                source.set_icon(Some(&texture), 32, 32);
            }
            let handler = state.handlers.borrow().drag.clone()?;
            handler(ids)
        });
        row.add_controller(drag);
        row
    }

    /// The photo under `x`, as a section and an index in it.
    fn tile_at(&self, x: f64) -> Option<(usize, usize)> {
        let model = self.imp().model.borrow().clone()?;
        let RowModel::Tiles { section, row } = model else { return None };
        let x = x as i32 - MARGIN;
        let position = self.imp().geometry.borrow().iter().position(|(start, width)| x >= *start && x < start + width)?;
        Some((section, row.start + position))
    }

    fn ensure_tiles(&self, count: usize) {
        let imp = self.imp();
        while imp.tiles.borrow().len() < count {
            let tile = TileWidgets::new(self);
            imp.tiles.borrow_mut().push(tile);
        }
        for (index, tile) in imp.tiles.borrow().iter().enumerate() {
            tile.root.set_child_visible(index < count);
        }
    }

    fn set_geometry(&self, row: &layout::Row) {
        let mut x = 0;
        let mut geometry = Vec::with_capacity(row.len());
        for width in &row.widths {
            geometry.push((x, *width as i32));
            x += *width as i32 + SPACING as i32;
        }
        self.imp().geometry.replace(geometry);
        self.imp().height.set(row.height as i32);
    }

    fn bind(&self, state: &State, model: RowModel) {
        let imp = self.imp();
        imp.model.replace(Some(model.clone()));
        let header = imp.header.borrow().clone();
        match &model {
            RowModel::Header { section } => {
                imp.is_header.set(true);
                self.ensure_tiles(0);
                imp.geometry.replace(Vec::new());
                if let Some(header) = header {
                    header.set_child_visible(true);
                }
                let sections = state.sections.borrow();
                if let Some(section) = sections.get(*section) {
                    if let (Some(title), Some(month)) = (imp.title.borrow().as_ref(), section.month) {
                        title.set_label(&text::month_title(month));
                    }
                    if let Some(count) = imp.count.borrow().as_ref() {
                        count.set_label(&text::items(u64::from(section.count)));
                    }
                }
            }
            RowModel::Tiles { section, row } => {
                imp.is_header.set(false);
                if let Some(header) = header {
                    header.set_child_visible(false);
                }
                self.set_geometry(row);
                self.ensure_tiles(row.len());
                let sections = state.sections.borrow();
                let tiles = sections.get(*section).and_then(|section| section.tiles.as_ref());
                for (offset, widgets) in imp.tiles.borrow().iter().take(row.len()).enumerate() {
                    match tiles.and_then(|tiles| tiles.get(row.start + offset)) {
                        Some(tile) => widgets.show(state, tile),
                        None => widgets.show_placeholder(),
                    }
                }
            }
            RowModel::Placeholder { row, .. } => {
                imp.is_header.set(false);
                if let Some(header) = header {
                    header.set_child_visible(false);
                }
                self.set_geometry(row);
                self.ensure_tiles(row.len());
                for widgets in imp.tiles.borrow().iter().take(row.len()) {
                    widgets.show_placeholder();
                }
            }
        }
        let _ = model.section();
        self.queue_resize();
    }
}

mod host_imp {
    use super::*;

    #[derive(Default)]
    pub struct GridHost {
        pub width: Cell<i32>,
        pub on_width: RefCell<Option<WidthHandler>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridHost {
        const NAME: &'static str = "ImmichGalleryGridHost";
        type Type = super::GridHost;
        type ParentType = gtk::Widget;

    }

    impl ObjectImpl for GridHost {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    // No layout manager: GTK calls a widget's own size_allocate only when it has none, and the grid needs to hear
    // of its width.
    impl WidgetImpl for GridHost {
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            match self.obj().first_child() {
                Some(child) => {
                    let (minimum, natural, _, _) = child.measure(orientation, for_size);
                    (minimum, natural, -1, -1)
                }
                None => (0, 0, -1, -1),
            }
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            if let Some(child) = self.obj().first_child() {
                child.size_allocate(&gtk::Allocation::new(0, 0, width, height), baseline);
            }
            if self.width.replace(width) != width {
                // Not during allocation: laying out again changes the list.
                let host = self.obj().downgrade();
                glib::idle_add_local_once(move || {
                    if let Some(host) = host.upgrade() {
                        if let Some(callback) = host.imp().on_width.borrow().as_ref() {
                            callback(host.imp().width.get());
                        }
                    }
                });
            }
        }
    }
}

glib::wrapper! {
    /// Holds the grid, and says when its width changes, which lays it out again.
    pub struct GridHost(ObjectSubclass<host_imp::GridHost>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl GridHost {
    fn new(child: &impl IsA<gtk::Widget>) -> GridHost {
        let host: GridHost = glib::Object::builder().property("hexpand", true).property("vexpand", true).property("focusable", true).build();
        child.set_parent(&host);
        // A click anywhere in the grid, between photos or below the last, gives it the keys, as in Files.
        let click = gtk::GestureClick::builder().button(0).build();
        let weak_host = host.downgrade();
        click.connect_pressed(move |_, _, _, _| {
            if let Some(host) = weak_host.upgrade() {
                host.grab_focus();
            }
        });
        host.add_controller(click);
        host
    }

    fn connect_width(&self, callback: impl Fn(i32) + 'static) {
        self.imp().on_width.replace(Some(Box::new(callback)));
    }
}

/// The settings every grid shares, as the Mac gallery's: the thumbnails' size (a step of `SIZES`) and whether they are
/// squares; by default as Immich shows them, at their own shape.
const SIZE: &str = "grid.size";
const SQUARES: &str = "grid.squares";

/// The thumbnails' size, as a step of `SIZES`.
pub fn shared_size_step() -> usize {
    verso_desktop::settings::shared().get(SIZE).and_then(|step| step.parse().ok()).unwrap_or(2).min(SIZES.len() - 1)
}

/// Bigger (`1`) or smaller (`-1`) thumbnails on every grid, each laying out again when told (`Grid::relayout`).
/// Whether it changed.
pub fn zoom(steps: i32) -> bool {
    let step = (shared_size_step() as i32 + steps).clamp(0, SIZES.len() as i32 - 1) as usize;
    let changed = step != shared_size_step();
    verso_desktop::settings::shared().set(SIZE, Some(&step.to_string()));
    changed
}

/// Whether the thumbnails are squares.
pub fn squares_shown() -> bool {
    verso_desktop::settings::shared().get(SQUARES).as_deref() == Some("true")
}

pub fn set_squares_shown(shown: bool) {
    verso_desktop::settings::shared().set(SQUARES, shown.then_some("true"));
}

/// The setting: the Date Scroller, the scrubber at a grid's edge, is shown unless hidden from the toolbar, as the Mac
/// gallery's (`grid.dateScroller`, one for every grid).
const DATE_SCROLLER: &str = "grid.dateScroller";

/// Whether grids of months show the Date Scroller.
pub fn date_scroller_shown() -> bool {
    verso_desktop::settings::shared().get(DATE_SCROLLER).as_deref() != Some("false")
}

/// Show or hide the Date Scroller on every grid of months; each lays out again when told (`Grid::relayout`).
pub fn set_date_scroller_shown(shown: bool) {
    verso_desktop::settings::shared().set(DATE_SCROLLER, (!shown).then_some("false"));
}

/// Whether a row of the list is a section's heading (`tile` none), or its row with photo `tile`.
fn shows(model: &RowModel, section: usize, tile: Option<usize>) -> bool {
    match (model, tile) {
        (RowModel::Header { section: shown }, None) => *shown == section,
        (RowModel::Tiles { section: shown, row } | RowModel::Placeholder { section: shown, row }, Some(tile)) => {
            *shown == section && (row.start..row.start + row.len()).contains(&tile)
        }
        _ => false,
    }
}

/// The sections to read around `section`, of sections with `counts` rows: it, then those before and after it, each way
/// until `rows` rows are covered.
fn around(counts: &[usize], section: usize, rows: usize) -> Vec<usize> {
    let mut wanted = vec![section];
    let mut covered = 0;
    for (index, count) in counts.iter().enumerate().take(section).rev() {
        if covered >= rows {
            break;
        }
        covered += count;
        wanted.push(index);
    }
    covered = 0;
    for (index, count) in counts.iter().enumerate().skip(section + 1) {
        if covered >= rows {
            break;
        }
        covered += count;
        wanted.push(index);
    }
    wanted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn months_are_read_ahead_both_ways_by_rows() {
        let counts = [5, 20, 3, 8, 12, 4, 30];
        // Ten rows each way: above, 3 rows are not enough, so the 20 above them too; below, 12 cover it.
        assert_eq!(around(&counts, 3, 10), [3, 2, 1, 4]);
        assert_eq!(around(&counts, 0, 10), [0, 1]);
        assert_eq!(around(&counts, 6, 10), [6, 5, 4]);
        assert_eq!(around(&counts, 6, 0), [6]);
    }

    #[test]
    fn the_scrubbers_jump_finds_the_heading_or_the_row_with_its_photo() {
        let row = |start: usize, count: usize| layout::Row { start, height: 100, widths: vec![100; count] };
        assert!(shows(&RowModel::Header { section: 2 }, 2, None));
        assert!(!shows(&RowModel::Header { section: 2 }, 2, Some(0)));
        assert!(shows(&RowModel::Tiles { section: 2, row: row(5, 5) }, 2, Some(7)));
        assert!(!shows(&RowModel::Tiles { section: 2, row: row(5, 5) }, 2, Some(10)));
        assert!(!shows(&RowModel::Tiles { section: 2, row: row(5, 5) }, 3, Some(7)));
        assert!(shows(&RowModel::Placeholder { section: 0, row: row(0, 4) }, 0, Some(3)));
    }
}
