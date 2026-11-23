//! A page of photos: the grid under a header with its title and count, a view menu (thumbnail size, squares), a
//! selection mode with its action bar, and a right-click menu. What can be done depends on the page: an album's
//! photos can be removed from it, the trash's restored or deleted for good, the archive's unarchived.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use verso_desktop::actions;
use verso_desktop::library::{Source, Tile};
use verso_core::links::ImmichItem;
use verso_linux::i18n::tr;

use crate::dialogs::{self, AlbumChoice};
use crate::grid::{Grid, Move};
use verso_core::grid_options::{Arrangement, GridPage, MediaType, Order, Show, SortBy};
use verso_desktop::arrangement as page_options;
use verso_desktop::settings;
use crate::overview::{Mode, Overview};
use crate::window::Window;

/// What kind of page it is, which decides what its photos offer.
#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Library,
    Favorites,
    Album { id: String },
    Person { id: String },
    Archive,
    Trash,
    Locked,
    /// Search results, a place, a memory, a folder: photos from elsewhere, nothing page-specific.
    Plain,
    /// A partner's library: theirs to change, so only looked at and downloaded.
    Partner,
    /// A link to chosen photos (`links_page::link_page`): its photos, which can be taken out of it.
    Link { id: String },
}

impl Kind {
    /// What the page's photos are inside, for links that open a photo where it was seen.
    pub fn within(&self) -> Option<ImmichItem> {
        match self {
            Kind::Album { id } => Some(ImmichItem::Album(id.clone())),
            Kind::Person { id } => Some(ImmichItem::Person(id.clone())),
            _ => None,
        }
    }

    pub fn album_id(&self) -> Option<&str> {
        match self {
            Kind::Album { id } => Some(id),
            _ => None,
        }
    }

    pub fn link_id(&self) -> Option<&str> {
        match self {
            Kind::Link { id } => Some(id),
            _ => None,
        }
    }
}

/// A page to make: its title, where its photos come from, its kind, and what it says when empty.
pub struct Spec {
    pub title: String,
    pub source: Source,
    pub kind: Kind,
    pub empty_title: String,
    pub empty_icon: &'static str,
    /// The page's own menu items, above the view options (an album's Rename, say).
    pub menu: Option<gio::Menu>,
    /// Actions for that menu, in the `page` group.
    pub actions: Vec<gio::SimpleAction>,
    /// The page's view options (favorites only, media type, sort, order), remembered as this page's.
    pub page: Option<GridPage>,
    /// Buttons of the page's own in the header (Assign Location's button, say).
    pub buttons: Vec<gtk::Widget>,
    /// What shows above the photos (an album's header, say).
    pub above: Option<gtk::Widget>,
    /// What the empty page offers (an empty album's Add Photos, say).
    pub empty_child: Option<gtk::Widget>,
}

impl Spec {
    pub fn new(title: &str, source: Source, kind: Kind) -> Spec {
        Spec { title: title.to_owned(), source, kind, empty_title: tr("No Photos").to_owned(), empty_icon: "image-x-generic-symbolic", menu: None, actions: Vec::new(), page: None, buttons: Vec::new(), above: None, empty_child: None }
    }

    /// The page offers view options, remembered as `page`'s.
    pub fn arranged(mut self, page: GridPage) -> Spec {
        self.page = Some(page);
        self
    }

    pub fn empty(mut self, title: &str, icon: &'static str) -> Spec {
        self.empty_title = title.to_owned();
        self.empty_icon = icon;
        self
    }
}

/// An empty album's or link's Add Photos: a pill under the empty page's title (`page.add-photos`).
pub fn add_photos_button() -> gtk::Button {
    gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("verso-add-photos-symbolic").label(tr("Add Photos…")).build())
        .action_name("page.add-photos")
        .halign(gtk::Align::Center)
        .css_classes(["pill", "suggested-action"])
        .build()
}

/// The selection's actions for a kind of page: (action, label, icon), in the action bar's order.
fn selection_actions(kind: &Kind) -> Vec<(&'static str, &'static str, &'static str)> {
    match kind {
        Kind::Trash => vec![("restore", "Restore", "edit-undo-symbolic"), ("delete-forever", "Delete Forever", "user-trash-full-symbolic")],
        Kind::Partner => vec![("download", "Download", "folder-download-symbolic")],
        Kind::Locked => vec![("unlock", "Move Out of the Locked Folder", "changes-allow-symbolic"), ("download", "Download", "folder-download-symbolic"), ("trash", "Move to Trash", "user-trash-symbolic")],
        Kind::Archive => vec![
            ("favorite", "Favorite", "verso-heart-symbolic"),
            ("add-to-album", "Add to Album", "list-add-symbolic"),
            ("unarchive", "Unarchive", "mail-send-receive-symbolic"),
            ("download", "Download", "folder-download-symbolic"),
            ("trash", "Move to Trash", "user-trash-symbolic"),
        ],
        Kind::Album { .. } => vec![
            ("favorite", "Favorite", "verso-heart-symbolic"),
            ("add-to-album", "Add to Album", "list-add-symbolic"),
            ("remove-from-album", "Remove from Album", "list-remove-symbolic"),
            ("download", "Download", "folder-download-symbolic"),
            ("trash", "Move to Trash", "user-trash-symbolic"),
        ],
        // A link's photos are the library's: taken out of the link, never trashed from it.
        Kind::Link { .. } => vec![
            ("favorite", "Favorite", "verso-heart-symbolic"),
            ("add-to-album", "Add to Album", "list-add-symbolic"),
            ("remove-from-link", "Remove from Link", "list-remove-symbolic"),
            ("download", "Download", "folder-download-symbolic"),
        ],
        _ => vec![
            ("favorite", "Favorite", "verso-heart-symbolic"),
            ("add-to-album", "Add to Album", "list-add-symbolic"),
            ("archive", "Archive", "folder-symbolic"),
            ("download", "Download", "folder-download-symbolic"),
            ("trash", "Move to Trash", "user-trash-symbolic"),
        ],
    }
}

/// The right-click menu: the bar's actions, and the ones that fit a menu better than a bar.
fn context_menu(kind: &Kind) -> gio::Menu {
    // As the Mac gallery's photo menu: open and look; the links; albums; favorite, share, stack; the picture and its
    // date and place; tags and the Locked Folder; export; archive and delete. The trash's photos only come back or go.
    let menu = gio::Menu::new();
    let section = |items: &[(&str, &str)]| {
        let part = gio::Menu::new();
        for (label, action) in items {
            part.append(Some(label), Some(&format!("selection.{action}")));
        }
        menu.append_section(None, &part);
    };
    let submenu = |label: &str, items: &[(&str, &str)]| {
        let part = gio::Menu::new();
        for (label, action) in items {
            part.append(Some(label), Some(&format!("selection.{action}")));
        }
        gio::MenuItem::new_submenu(Some(label), &part)
    };
    let mut looking = vec![(tr("Open"), "open"), (tr("Info"), "info")];
    if !matches!(kind, Kind::Library | Kind::Partner) {
        looking.push((tr("Show in All Photos"), "show-in-library"));
    }
    section(&looking);
    if *kind == Kind::Partner {
        section(&[(tr("Open in Immich"), "open-in-immich"), (tr("Copy Immich Link"), "copy-link")]);
        section(&[(tr("Download Originals…"), "download"), (tr("Download as ZIP…"), "zip")]);
        return menu;
    }
    if *kind == Kind::Trash {
        section(&[(tr("Restore"), "restore"), (tr("Delete Forever…"), "delete-forever")]);
        return menu;
    }
    let links = gio::Menu::new();
    crate::crosslink::append(&links, "asset", "selection");
    if links.n_items() > 0 {
        menu.append_section(None, &links);
    }
    let locked = *kind == Kind::Locked;
    if !locked {
        let mut albums = vec![(tr("Add to Album…"), "add-to-album"), (tr("New Album with Selection…"), "new-album")];
        if matches!(kind, Kind::Album { .. }) {
            albums.push((tr("Remove from Album"), "remove-from-album"));
            albums.push((tr("Use as Album Cover"), "cover"));
        }
        if matches!(kind, Kind::Link { .. }) {
            albums.push((tr("Remove from Link"), "remove-from-link"));
        }
        section(&albums);
    }
    let sharing = gio::Menu::new();
    // One item, ticked when every photo selected is a favorite, as the bar's heart (`favorited`).
    sharing.append(Some(tr("Favorite")), Some("selection.favorited"));
    if !locked {
        sharing.append_item(&submenu(tr("Share"), &[(tr("Create Public Link…"), "share-link"), (tr("Add to Public Link…"), "add-to-link")]));
    }
    sharing.append(Some(tr("Stack Together")), Some("selection.stack"));
    // A stack's cover, alone selected: its photos, or each photo on its own again, as the Mac's Browse Stack.
    for (label, action) in [(tr("Open Stack"), "open-stack"), (tr("Unstack"), "unstack")] {
        let item = gio::MenuItem::new(Some(label), Some(&format!("selection.{action}")));
        item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        sharing.append_item(&item);
    }
    menu.append_section(None, &sharing);
    section(&[
        (tr("Adjust Date and Time…"), "date"),
        (tr("Set the Place…"), "place"),
        (tr("Rotate Left"), "rotate-left"),
        (tr("Rotate Right"), "rotate-right"),
        (tr("Crop…"), "crop"),
    ]);
    let keeping = gio::Menu::new();
    if !locked {
        keeping.append_item(&submenu(tr("Tags"), &[(tr("Add Tag…"), "add-tag"), (tr("Remove Tag…"), "remove-tag")]));
        keeping.append(Some(tr("Move to the Locked Folder…")), Some("selection.lock"));
    }
    keeping.append_item(&submenu(tr("Export"), &[(tr("Download Originals…"), "download"), (tr("Download as ZIP…"), "zip")]));
    menu.append_section(None, &keeping);
    let last = match kind {
        Kind::Locked => vec![(tr("Move Out of the Locked Folder"), "unlock"), (tr("Move to Trash…"), "trash")],
        Kind::Archive => vec![(tr("Unarchive"), "unarchive"), (tr("Move to Trash…"), "trash")],
        _ => vec![(tr("Archive"), "archive"), (tr("Move to Trash…"), "trash")],
    };
    section(&last);
    menu
}

/// A page's View Options: what it shows, and in which order; the sort only while the timeline API reads the page.
fn view_options_menu(page: GridPage, arrangement: &Arrangement) -> gio::Menu {
    let menu = gio::Menu::new();
    let section = |title: &str, action: &str, items: &[(&str, &str)]| {
        let part = gio::Menu::new();
        for (label, target) in items {
            part.append(Some(label), Some(&format!("page.{action}::{target}")));
        }
        menu.append_section(Some(title), &part);
    };
    if page.offers_favorites() {
        section(tr("Show"), "show", &[(tr("All Items"), Show::All.code()), (tr("Favorites"), Show::Favorites.code())]);
    }
    if page.offers_media_type() {
        section(tr("Media Type"), "media", &[(tr("Photos and Videos"), MediaType::All.code()), (tr("Photos"), MediaType::Photos.code()), (tr("Videos"), MediaType::Videos.code())]);
    }
    if page.offers_sort_by() && arrangement.media_type == MediaType::All {
        section(tr("Sort By"), "sort-by", &[(tr("Date Taken"), SortBy::DateTaken.code()), (tr("Date Added"), SortBy::DateAdded.code())]);
    }
    if page.offers_order() {
        section(tr("Order"), "order", &[(tr("Newest First"), Order::NewestFirst.code()), (tr("Oldest First"), Order::OldestFirst.code())]);
    }
    menu
}

/// Make the page.
pub fn grid_page(window: &Window, spec: Spec) -> (adw::NavigationPage, Option<Grid>) {
    let Some(session) = window.session() else {
        return (adw::NavigationPage::builder().title(&spec.title).build(), None);
    };
    // The page's view options turn the source it reads into the one shown (immich's API is v3.2 or later here, so
    // Date Added is always there).
    let arrangement = Rc::new(Cell::new(spec.page.map(|page| page_options::load(page, settings::shared())).unwrap_or_default()));
    let shown_source = if spec.page.is_some() { page_options::source(&arrangement.get(), &spec.source, true) } else { spec.source.clone() };
    let grid = Grid::new(session.connection.client.clone(), session.textures.clone(), shown_source, &spec.empty_title, spec.empty_icon);
    if arrangement.get().is_filtered() {
        grid.set_empty_title(tr("No Matching Photos"));
    }
    if let Some(child) = &spec.empty_child {
        grid.set_empty_child(child);
    }
    let title = adw::WindowTitle::new(&spec.title, "");
    let header = adw::HeaderBar::builder().title_widget(&title).build();

    let select_button = gtk::ToggleButton::builder().icon_name("selection-mode-symbolic").tooltip_text(tr("Select")).build();
    let view_menu = gio::Menu::new();
    // The photos shown: selecting them all and reading them again, the same on every page; the view (size, squares,
    // the Date Scroller, Info) is the toolbar's buttons. Then what is the page's own.
    let photos = gio::Menu::new();
    photos.append(Some(tr("Select All")), Some("win.select-all"));
    photos.append(Some(tr("Refresh")), Some("win.refresh"));
    view_menu.append_section(None, &photos);
    if let Some(menu) = &spec.menu {
        view_menu.append_section(None, menu);
    }
    // As the Mac gallery's: on the pages of the user's own photos. A period always covers the whole library.
    let offers_similar = matches!(spec.page, Some(GridPage::Library | GridPage::Favorites | GridPage::Archive | GridPage::Person | GridPage::LargeFiles));
    if offers_similar {
        let utilities = gio::Menu::new();
        utilities.append(Some(tr("Find Similar Photos…")), Some("page.similar"));
        view_menu.append_section(None, &utilities);
    }
    let menu_button = gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(tr("More")).menu_model(&view_menu).visible(view_menu.n_items() > 0).build();
    header.pack_end(&menu_button);
    for button in &spec.buttons {
        header.pack_end(button);
    }
    let view_options = spec.page.map(|page| {
        let button = gtk::MenuButton::builder().icon_name("view-sort-descending-symbolic").tooltip_text(tr("View Options")).menu_model(&view_options_menu(page, &arrangement.get())).build();
        if arrangement.get().is_filtered() {
            button.add_css_class("accent");
        }
        header.pack_end(&button);
        button
    });
    header.pack_end(&select_button);
    // The Date Scroller and square thumbnails, shown or not on every grid, as the Mac gallery's toolbar toggles: the
    // window's switches (`win.date-scroller`, `win.squares`), so the main menu's checks follow.
    let scroller = gtk::ToggleButton::builder().icon_name("verso-date-scroller-symbolic").tooltip_text(tr("Date Scroller")).action_name("win.date-scroller").visible(false).build();
    header.pack_end(&scroller);
    let squares = gtk::ToggleButton::builder().icon_name("verso-aspect-ratio-symbolic").tooltip_text(tr("Square Photos")).action_name("win.squares").build();
    header.pack_end(&squares);
    // Smaller and bigger thumbnails, every grid alike, as one pair as on the Mac, at the start of the toolbar.
    let zoom_out = gtk::Button::builder().icon_name("list-remove-symbolic").tooltip_text(tr("Smaller Thumbnails")).action_name("win.zoom-out").build();
    let zoom_in = gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("Bigger Thumbnails")).action_name("win.zoom-in").build();
    let zoom = gtk::Box::builder().css_classes(["linked"]).valign(gtk::Align::Center).build();
    zoom.append(&zoom_out);
    zoom.append(&zoom_in);
    header.pack_start(&zoom);

    // The selection's bar, shown in selection mode.
    let count_label = gtk::Label::builder().css_classes(["dim-label"]).build();
    let bar = gtk::ActionBar::new();
    bar.pack_start(&count_label);
    for (action, label, icon) in selection_actions(&spec.kind).into_iter().rev() {
        // The heart is a switch for the photos selected (`favorited`): filled while every one of them is a favorite.
        if action == "favorite" {
            // Flat as the bar's other buttons, its pressed look on while on, as the toolbar's Square Photos.
            let star = gtk::ToggleButton::builder().icon_name("verso-heart-outline-symbolic").tooltip_text(tr(label)).action_name("selection.favorited").css_classes(["flat"]).build();
            star.update_property(&[gtk::accessible::Property::Label(tr(label))]);
            star.connect_active_notify(|star| star.set_icon_name(if star.is_active() { "verso-heart-symbolic" } else { "verso-heart-outline-symbolic" }));
            bar.pack_end(&star);
            continue;
        }
        let button = gtk::Button::builder().icon_name(icon).tooltip_text(tr(label)).action_name(format!("selection.{action}")).build();
        button.update_property(&[gtk::accessible::Property::Label(tr(label))]);
        bar.pack_end(&button);
    }
    bar.set_revealed(false);

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.add_bottom_bar(&bar);
    // The Info panel beside the grid, for the photo selected (Ctrl+I), as the Mac gallery's inspector; shown or not
    // on every page alike.
    let info = crate::info::InfoPanel::new(window);
    let split = adw::OverlaySplitView::builder().sidebar_position(gtk::PackType::End).sidebar(info.widget()).min_sidebar_width(260.0).max_sidebar_width(420.0).build();
    split.set_show_sidebar(settings::shared().get("grid.showInfo").as_deref() == Some("true"));
    let info_button = gtk::ToggleButton::builder().icon_name("help-about-symbolic").tooltip_text(tr("Info")).build();
    split.bind_property("show-sidebar", &info_button, "active").bidirectional().sync_create().build();
    let (weak_grid, shown_info) = (grid.downgrade(), info.clone());
    split.connect_show_sidebar_notify(move |split| {
        let shown = split.shows_sidebar();
        settings::shared().set("grid.showInfo", shown.then_some("true"));
        if let (true, Some(grid)) = (shown, weak_grid.upgrade()) {
            shown_info.show(&grid.selected_ids());
        }
    });
    header.pack_end(&info_button);
    toolbar.set_content(Some(&split));
    let shown_overview_holder: Rc<RefCell<Option<std::rc::Weak<Overview>>>> = Rc::default();
    // The Library's Years, Months and All Photos, as in Photos and the Mac gallery: a switch in the header's middle.
    match (&spec.kind, &spec.source) {
        (Kind::Library, Source::Timeline(scope)) => {
            let overview = Overview::new(session.connection.client.clone(), scope.clone(), session.textures.cache().clone(), grid.downgrade());
            shown_overview_holder.replace(Some(Rc::downgrade(&overview)));
            let content = gtk::Stack::new();
            content.add_named(grid.widget(), Some("all"));
            content.add_named(overview.widget(), Some("overview"));
            content.set_visible_child_name("all");
            split.set_content(Some(&content));
            let toggles = adw::ToggleGroup::new();
            for (name, label) in [("years", tr("Years")), ("months", tr("Months")), ("all", tr("All Photos"))] {
                toggles.add(adw::Toggle::builder().name(name).label(label).build());
            }
            toggles.set_active_name(Some("all"));
            header.set_title_widget(Some(&toggles));
            let (shown_overview, weak_content, weak_select) = (overview.clone(), content.downgrade(), select_button.downgrade());
            let weak_scroller = scroller.downgrade();
            let (weak_zoom_out, weak_zoom_in, weak_squares): (glib::WeakRef<gtk::Widget>, glib::WeakRef<gtk::Widget>, glib::WeakRef<gtk::Widget>) =
                (zoom_out.upcast_ref::<gtk::Widget>().downgrade(), zoom_in.upcast_ref::<gtk::Widget>().downgrade(), squares.upcast_ref::<gtk::Widget>().downgrade());
            toggles.connect_active_name_notify(move |toggles| {
                let Some(content) = weak_content.upgrade() else { return };
                let name = toggles.active_name();
                match name.as_deref() {
                    Some("years") => shown_overview.show(Mode::Years),
                    Some("months") => shown_overview.show(Mode::Months),
                    _ => {}
                }
                let all = name.as_deref() == Some("all");
                content.set_visible_child_name(if all { "all" } else { "overview" });
                // Years and Months show the library, not photos to act on: selecting waits for All Photos.
                if let Some(button) = weak_select.upgrade() {
                    if !all {
                        button.set_active(false);
                    }
                    button.set_sensitive(all);
                }
                for button in [&weak_zoom_out, &weak_zoom_in, &weak_squares].into_iter().filter_map(|weak| weak.upgrade()) {
                    button.set_sensitive(all);
                }
                if let Some(button) = weak_scroller.upgrade() {
                    button.set_sensitive(all);
                }
            });
            let (weak_overview, weak_toggles) = (Rc::downgrade(&overview), toggles.downgrade());
            overview.on_year.replace(Some(Box::new(move |month| {
                if let (Some(overview), Some(toggles)) = (weak_overview.upgrade(), weak_toggles.upgrade()) {
                    overview.start_at(month);
                    toggles.set_active_name(Some("months"));
                }
            })));
            let (weak_toggles, shown) = (toggles.downgrade(), grid.downgrade());
            overview.on_photo.replace(Some(Box::new(move |month, id| {
                if let Some(toggles) = weak_toggles.upgrade() {
                    toggles.set_active_name(Some("all"));
                }
                if let Some(grid) = shown.upgrade() {
                    grid.reveal(month, &id);
                }
            })));
        }
        _ => split.set_content(Some(grid.widget())),
    }
    if let Some(above) = &spec.above {
        if let Some(content) = split.content() {
            split.set_content(gtk::Widget::NONE);
            let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
            column.append(above);
            content.set_vexpand(true);
            column.append(&content);
            split.set_content(Some(&column));
        }
    }
    let page = adw::NavigationPage::builder().title(&spec.title).child(&toolbar).build();

    // Page actions: squares, select all, and the spec's own.
    let page_actions = gio::SimpleActionGroup::new();
    let toggle_info = gio::SimpleAction::new("toggle-info", None);
    let weak_split = split.downgrade();
    toggle_info.connect_activate(move |_, _| {
        if let Some(split) = weak_split.upgrade() {
            split.set_show_sidebar(!split.shows_sidebar());
        }
    });
    page_actions.add_action(&toggle_info);
    if let (Some(page), Some(button)) = (spec.page, view_options.clone()) {
        let current = arrangement.get();
        let initial = [
            ("show", current.show.code()),
            ("media", current.media_type.code()),
            ("sort-by", current.sort_by.code()),
            ("order", current.order.code()),
        ];
        for (name, value) in initial {
            let action = gio::SimpleAction::new_stateful(name, Some(glib::VariantTy::STRING), &value.to_variant());
            let (arrangement, shown, base, weak_button, overview, empty_title) = (arrangement.clone(), grid.clone(), spec.source.clone(), button.downgrade(), shown_overview_holder.clone(), spec.empty_title.clone());
            action.connect_change_state(move |action, value| {
                let Some(value) = value else { return };
                action.set_state(value);
                let chosen = value.get::<String>().unwrap_or_default();
                let mut changed = arrangement.get();
                match action.name().as_str() {
                    "show" => changed.show = Show::from_code(&chosen).unwrap_or_default(),
                    "media" => changed.media_type = MediaType::from_code(&chosen).unwrap_or_default(),
                    "sort-by" => changed.sort_by = SortBy::from_code(&chosen).unwrap_or_default(),
                    _ => changed.order = Order::from_code(&chosen).unwrap_or_default(),
                }
                page_options::save(&changed, page, settings::shared());
                arrangement.set(changed);
                shown.set_empty_title(if changed.is_filtered() { tr("No Matching Photos") } else { &empty_title });
                if let Some(overview) = overview.borrow().as_ref().and_then(std::rc::Weak::upgrade) {
                    overview.forget();
                }
                shown.set_source(page_options::source(&changed, &base, true));
                if let Some(button) = weak_button.upgrade() {
                    button.set_menu_model(Some(&view_options_menu(page, &changed)));
                    if changed.is_filtered() { button.add_css_class("accent") } else { button.remove_css_class("accent") }
                }
            });
            page_actions.add_action(&action);
        }
    }
    let select_all = gio::SimpleAction::new("select-all", None);
    let shown = grid.clone();
    select_all.connect_activate(move |_, _| shown.select_all());
    page_actions.add_action(&select_all);
    if offers_similar {
        let similar = gio::SimpleAction::new("similar", None);
        let (shown, weak_window) = (grid.clone(), window.downgrade());
        similar.connect_activate(move |_, _| {
            if let Some(window) = weak_window.upgrade() {
                crate::similar::find_similar(&window, shown.selected_ids());
            }
        });
        page_actions.add_action(&similar);
    }
    for action in &spec.actions {
        page_actions.add_action(action);
    }
    page.insert_action_group("page", Some(&page_actions));

    // The selection's actions.
    let selection_group = gio::SimpleActionGroup::new();
    let names = [
        "favorite", "unfavorite", "add-to-album", "archive", "unarchive", "download", "trash", "restore", "delete-forever", "remove-from-album", "remove-from-link", "lock",
        "unlock", "cover", "open-in-immich", "place", "stack", "open", "info", "show-in-library", "copy-link", "new-album",
        "share-link", "add-to-link", "date", "rotate-left", "rotate-right", "crop", "add-tag", "remove-tag", "zip", "open-stack",
        "unstack",
    ];
    let kind = Rc::new(spec.kind.clone());
    for name in names {
        let action = gio::SimpleAction::new(name, None);
        let (weak_window, shown, kind) = (window.downgrade(), grid.clone(), kind.clone());
        action.connect_activate(move |_, _| {
            if let Some(window) = weak_window.upgrade() {
                act(&window, &shown, &kind, name);
            }
        });
        // Only for a stack's cover alone selected (the selection's handler below).
        if matches!(name, "open-stack" | "unstack") {
            action.set_enabled(false);
        }
        selection_group.add_action(&action);
    }
    // Favorite, as one switch for the photos selected, as the viewer's heart: on while every one of them is a favorite;
    // pressed, they all become favorites, or, when they all are, none is. It shows the change at once; the selection's
    // handler sets it from the photos again once the server has answered.
    let favorited = gio::SimpleAction::new_stateful("favorited", None, &false.to_variant());
    favorited.set_enabled(false);
    let (weak_window, shown, kind_favorited) = (window.downgrade(), grid.clone(), kind.clone());
    favorited.connect_activate(move |action, _| {
        let all = action.state().and_then(|state| state.get::<bool>()).unwrap_or(false);
        action.set_state(&(!all).to_variant());
        if let Some(window) = weak_window.upgrade() {
            act(&window, &shown, &kind_favorited, if all { "unfavorite" } else { "favorite" });
        }
    });
    selection_group.add_action(&favorited);
    // Show in *app*, the participant's id as the target, for the first photo selected.
    let show_in = gio::SimpleAction::new("show-in", Some(glib::VariantTy::STRING));
    let (weak_window, shown, kind_shown) = (window.downgrade(), grid.clone(), kind.clone());
    show_in.connect_activate(move |_, target| {
        let (Some(window), Some(app)) = (weak_window.upgrade(), target.and_then(|target| target.get::<String>())) else { return };
        if let Some(id) = shown.selected_ids().into_iter().next() {
            window.show_in(&app, &id, kind_shown.within());
        }
    });
    selection_group.add_action(&show_in);
    page.insert_action_group("selection", Some(&selection_group));

    // Selection mode follows the toggle, and the bar the selection.
    let shown = grid.clone();
    select_button.connect_toggled(move |button| {
        if button.is_active() != shown.selecting() {
            shown.set_selecting(button.is_active());
        }
    });
    // Weakly: the grid keeps this handler, and a strong grid in it would keep the page alive for good.
    let (weak_grid, weak_bar, weak_label, weak_button, weak_title) = (grid.downgrade(), bar.downgrade(), count_label.downgrade(), select_button.downgrade(), title.downgrade());
    let (selected_info, weak_split, weak_actions) = (info.clone(), split.downgrade(), selection_group.downgrade());
    let total_title = spec.title.clone();
    grid.on_selection_changed(move || {
        let Some(shown) = weak_grid.upgrade() else { return };
        let count = shown.selected_ids().len();
        if let Some(actions) = weak_actions.upgrade() {
            let selected = shown.selected_tiles();
            let stack_cover = count == 1 && selected.first().is_some_and(|tile| tile.stack.is_some());
            for name in ["open-stack", "unstack"] {
                if let Some(action) = actions.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                    action.set_enabled(stack_cover);
                }
            }
            if let Some(action) = actions.lookup_action("favorited").and_downcast::<gio::SimpleAction>() {
                action.set_enabled(!selected.is_empty());
                action.set_state(&(!selected.is_empty() && selected.iter().all(|tile| tile.is_favorite)).to_variant());
            }
        }
        if weak_split.upgrade().is_some_and(|split| split.shows_sidebar()) {
            selected_info.show(&shown.selected_ids());
        }
        if let Some(bar) = weak_bar.upgrade() {
            // The selection's actions show whenever something is selected, as the Mac gallery's toolbar acts on it.
            bar.set_revealed(shown.selecting() || count > 0);
        }
        if let Some(label) = weak_label.upgrade() {
            label.set_label(&match count {
                0 => tr("Select Items").to_owned(),
                1 => tr("1 Selected").to_owned(),
                count => tr("{count} Selected").replace("{count}", &count.to_string()),
            });
        }
        if let Some(button) = weak_button.upgrade() {
            if button.is_active() != shown.selecting() {
                button.set_active(shown.selecting());
            }
        }
        if let Some(title) = weak_title.upgrade() {
            if shown.selecting() {
                title.set_title(&tr("{count} Selected").replace("{count}", &count.to_string()));
            } else {
                title.set_title(&total_title);
            }
        }
    });
    let (weak_title, weak_grid, weak_scroller) = (title.downgrade(), grid.downgrade(), scroller.downgrade());
    grid.on_loaded(move |total| {
        if let Some(title) = weak_title.upgrade() {
            title.set_subtitle(&verso_desktop::text::items(total));
        }
        // The Date Scroller shows from two months, on a grid of months alone.
        if let (Some(scroller), Some(grid)) = (weak_scroller.upgrade(), weak_grid.upgrade()) {
            scroller.set_visible(grid.month_counts().len() >= 2);
        }
    });
    let weak_window = window.downgrade();
    grid.on_failed(move |message| {
        if let Some(window) = weak_window.upgrade() {
            window.load_failed(message);
        }
    });
    let (weak_window, within) = (window.downgrade(), spec.kind.clone());
    grid.on_open(move |tiles: Vec<Tile>, index| {
        if let Some(window) = weak_window.upgrade() {
            window.open_viewer(tiles, index, within.clone());
        }
    });
    let (weak_window, within) = (window.downgrade(), spec.kind.within());
    grid.on_drag(move |ids| {
        let resolver = weak_window.upgrade()?.resolver(within.clone())?;
        Some(crate::drag::PhotoFiles::new(ids, resolver).upcast())
    });
    let menu = context_menu(&spec.kind);
    grid.on_context_menu(move |widget, x, y| {
        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_parent(widget);
        popover.set_has_arrow(false);
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover.connect_closed(|popover| {
            let popover = popover.clone();
            glib::idle_add_local_once(move || popover.unparent());
        });
        popover.popup();
    });

    // Keys while the grid has the focus: Delete, Ctrl+A, Escape, and the period for favorites, as in the viewer.
    let keys = gtk::EventControllerKey::new();
    let (weak_window, shown, kind) = (window.downgrade(), grid.clone(), spec.kind.clone());
    let offers_favorite = selection_actions(&spec.kind).iter().any(|(action, _, _)| *action == "favorite");
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(window) = weak_window.upgrade() else { return glib::Propagation::Proceed };
        // Years and Months shown, the grid's keys wait.
        if !shown.widget().is_mapped() {
            return glib::Propagation::Proceed;
        }
        if gtk::prelude::RootExt::focus(&window).is_some_and(|focus| focus.is::<gtk::Text>() || focus.ancestor(gtk::Editable::static_type()).is_some()) {
            return glib::Propagation::Proceed;
        }
        let control = modifiers.contains(gtk::gdk::ModifierType::CONTROL_MASK);
        let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);
        let step = match key {
            gtk::gdk::Key::Left => Some(Move::Left),
            gtk::gdk::Key::Right => Some(Move::Right),
            gtk::gdk::Key::Up => Some(Move::Up),
            gtk::gdk::Key::Down => Some(Move::Down),
            gtk::gdk::Key::Home => Some(Move::First),
            gtk::gdk::Key::End => Some(Move::Last),
            _ => None,
        };
        if let Some(step) = step {
            shown.move_cursor(step, shift);
            return glib::Propagation::Stop;
        }
        match key {
            gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter if shown.open_cursor() => {}
            // Space adds the ringed photo to the selection in selection mode, and otherwise opens it, as a quick look.
            gtk::gdk::Key::space if shown.toggle_cursor() || shown.open_cursor() => {}
            gtk::gdk::Key::a if control => shown.select_all(),
            gtk::gdk::Key::Escape if shown.selecting() || !shown.selected_ids().is_empty() => shown.set_selecting(false),
            gtk::gdk::Key::Delete | gtk::gdk::Key::KP_Delete if !shown.selected_ids().is_empty() && kind != Kind::Partner => {
                act(&window, &shown, &kind, if kind == Kind::Trash { "delete-forever" } else { "trash" })
            }
            // The selection becomes favorites, or stops being ones when every photo in it is one, as the viewer's key
            // does for its photo, on the pages whose selection offers Favorite.
            gtk::gdk::Key::period if offers_favorite && !shown.selected_ids().is_empty() => {
                let all_favorites = shown.selected_tiles().iter().all(|tile| tile.is_favorite);
                act(&window, &shown, &kind, if all_favorites { "unfavorite" } else { "favorite" })
            }
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    page.add_controller(keys);
    let focused = grid.clone();
    page.connect_shown(move |_| {
        focused.widget().grab_focus();
    });
    window.register_grid(&page, &grid);
    (page, Some(grid))
}

/// Do a selection action on the grid's selected photos.
pub fn act(window: &Window, grid: &Grid, kind: &Kind, action: &str) {
    let ids = grid.selected_ids();
    if ids.is_empty() {
        return;
    }
    let Some(session) = window.session() else { return };
    let client = session.connection.client.clone();
    let count = ids.len();
    let done = {
        let (weak_window, shown) = (window.downgrade(), grid.clone());
        move |outcome: Result<String, String>, removed: Vec<String>| {
            let Some(window) = weak_window.upgrade() else { return };
            match outcome {
                Ok(message) => {
                    shown.remove(&removed);
                    shown.set_selecting(false);
                    if !message.is_empty() {
                        window.toast(&message);
                    }
                }
                Err(message) => window.toast(&message),
            }
        }
    };
    let items = |count: usize| verso_desktop::text::items(count as u64);
    if action == "info" {
        let _ = WidgetExt::activate_action(grid.widget(), "page.toggle-info", None);
        return;
    }
    if crate::menu_actions::act(window, grid, kind, action, &ids) {
        return;
    }
    match action {
        "favorite" | "unfavorite" => {
            let favorite = action == "favorite";
            let (shown, changed, weak_window) = (grid.clone(), ids.clone(), window.downgrade());
            crate::tasks::run(async move { actions::set_favorite(&client, ids, favorite).await }, move |outcome| {
                match outcome {
                    Ok(()) => shown.update(&changed, |tile| tile.is_favorite = favorite),
                    Err(message) => {
                        if let Some(window) = weak_window.upgrade() {
                            window.toast(&message);
                        }
                    }
                }
                // The heart and the menu's tick follow the photos as they now are.
                shown.refresh_selection();
            });
        }
        "archive" | "unarchive" => {
            let archived = action == "archive";
            let message = if archived { tr("Archived {items}") } else { tr("Unarchived {items}") }.replace("{items}", &items(count));
            let removed = ids.clone();
            crate::tasks::run(async move { actions::set_archived(&client, ids, archived).await.map(|()| message) }, move |outcome| done(outcome, removed));
        }
        "lock" | "unlock" => {
            let locked = action == "lock";
            if session.connection.with_api_key {
                return window.toast(tr("The Locked Folder needs a sign-in with a password or single sign-on."));
            }
            let message = if locked { tr("Moved {items} to the Locked Folder") } else { tr("Moved {items} out of the Locked Folder") }.replace("{items}", &items(count));
            let run = move || {
                let (client, ids, done, message) = (client.clone(), ids.clone(), done.clone(), message.clone());
                let removed = ids.clone();
                crate::tasks::run(async move { actions::set_locked(&client, ids, locked).await.map(|()| message) }, move |outcome| done(outcome, removed));
            };
            if locked {
                let heading = if count == 1 { tr("Move to the Locked Folder?").to_owned() } else { tr("Move {items} to the Locked Folder?").replace("{items}", &items(count)) };
                let body = tr("They leave the library, albums and searches, and show only in the Locked Folder, opened with your PIN code.");
                dialogs::confirm(window, &heading, body, tr("Move"), false, run);
            } else {
                run();
            }
        }
        "trash" => {
            let (heading, body) = if count == 1 {
                // Name the photo, by when it was taken: the one selected may be off screen.
                let taken = grid.selected_tiles().first().map(|tile| verso_desktop::text::taken(tile.taken)).unwrap_or_default();
                (tr("Move to Trash?").to_owned(), tr("The photo taken {date} goes to Recently Deleted, where it can be restored until the trash is emptied.").replace("{date}", &taken))
            } else {
                (tr("Move {items} to Trash?").replace("{items}", &items(count)), tr("They go to Recently Deleted, where they can be restored until the trash is emptied.").to_owned())
            };
            dialogs::confirm(window, &heading, &body, tr("Move to Trash"), true, move || {
                let (client, ids, done) = (client.clone(), ids.clone(), done.clone());
                let message = tr("Moved {items} to the trash").replace("{items}", &items(count));
                let removed = ids.clone();
                crate::tasks::run(async move { actions::trash(&client, ids).await.map(|()| message) }, move |outcome| done(outcome, removed));
            });
        }
        "delete-forever" => {
            let heading = if count == 1 { tr("Delete Forever?").to_owned() } else { tr("Delete {items} Forever?").replace("{items}", &items(count)) };
            let body = match grid.selected_tiles().first().filter(|_| count == 1) {
                Some(tile) => tr("The photo taken {date} is deleted from Immich for good. This cannot be undone.").replace("{date}", &verso_desktop::text::taken(tile.taken)),
                None => tr("This deletes them from Immich for good, and cannot be undone.").to_owned(),
            };
            dialogs::confirm(window, &heading, &body, tr("Delete Forever"), true, move || {
                let (client, ids, done) = (client.clone(), ids.clone(), done.clone());
                let removed = ids.clone();
                crate::tasks::run(async move { actions::delete_forever(&client, ids).await.map(|()| String::new()) }, move |outcome| done(outcome, removed));
            });
        }
        "restore" => {
            let removed = ids.clone();
            crate::tasks::run(
                async move { actions::restore(&client, ids).await.map(|restored| tr("Restored {items}").replace("{items}", &items(restored as usize))) },
                move |outcome| done(outcome, removed),
            );
        }
        "remove-from-album" => {
            let Some(album_id) = kind.album_id().map(str::to_owned) else { return };
            let removed = ids.clone();
            let message = tr("Removed {items} from the album").replace("{items}", &items(count));
            crate::tasks::run(async move { actions::remove_from_album(&client, album_id, ids).await.map(|()| message) }, move |outcome| done(outcome, removed));
        }
        "remove-from-link" => {
            let Some(link_id) = kind.link_id().map(str::to_owned) else { return };
            let removed = ids.clone();
            let message = tr("Removed {items} from the link").replace("{items}", &items(count));
            crate::tasks::run(
                async move { client.remove_assets_from_shared_link(&link_id, &ids).await.map(|_| message).map_err(|error| verso_desktop::errors::said(&error)) },
                move |outcome| done(outcome, removed),
            );
        }
        "cover" => {
            let Some(album_id) = kind.album_id().map(str::to_owned) else { return };
            let asset_id = ids[0].clone();
            let weak_window = window.downgrade();
            crate::tasks::run(async move { actions::set_album_cover(&client, album_id, asset_id).await }, move |outcome| {
                if let Some(window) = weak_window.upgrade() {
                    window.toast(&outcome.map(|()| tr("Album cover changed").to_owned()).unwrap_or_else(|message| message));
                    window.refresh_albums();
                }
            });
        }
        "add-to-album" => add_to_album(window, ids, Some(grid.clone())),
        "stack" => {
            if count < 2 {
                return window.toast(tr("Select two or more photos to stack them"));
            }
            // The first in the grid's order heads the stack, as Immich makes the first id given the primary.
            // Only the Library shows a stack as one photo; elsewhere (an album, say) every photo stays where it is.
            let removed: Vec<String> = if *kind == Kind::Library { ids.iter().skip(1).cloned().collect() } else { Vec::new() };
            let message = tr("Stacked {items}").replace("{items}", &items(count));
            let shown = grid.clone();
            crate::tasks::run(async move { client.create_stack(&ids).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                // The photo that heads the stack knows it at once: its badge shows, and the viewer offers its photos.
                let outcome = outcome.map(|stack| {
                    let held = u32::try_from(stack.assets.len()).unwrap_or(u32::MAX);
                    shown.update(std::slice::from_ref(&stack.primary_asset_id), |tile| tile.stack = Some((stack.id.clone(), held)));
                    message
                });
                done(outcome, removed)
            });
        }
        "open-stack" => {
            if let Some((stack_id, _)) = grid.selected_tiles().first().and_then(|tile| tile.stack.clone()) {
                crate::stacks::show_stack(window, &stack_id);
            }
        }
        "unstack" => {
            let Some((cover, (stack_id, _))) = grid.selected_tiles().into_iter().next().and_then(|tile| tile.stack.clone().map(|stack| (tile.id, stack))) else { return };
            let (shown, weak_window) = (grid.clone(), window.downgrade());
            crate::tasks::run(async move { client.delete_stack(&stack_id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let Some(window) = weak_window.upgrade() else { return };
                match outcome {
                    Ok(()) => {
                        window.toast(tr("Unstacked: each photo shows on its own again"));
                        shown.update(std::slice::from_ref(&cover), |tile| tile.stack = None);
                        shown.reread_month_of(&cover);
                    }
                    Err(message) => window.toast(&message),
                }
            });
        }
        "place" => {
            let shown = grid.clone();
            crate::edit::edit_place(window, ids, None, move || {
                shown.set_selecting(false);
                // Immich names the place a moment after it answers; then the grid shows it (and Assign Location
                // lets the photo go).
                let weak = shown.downgrade();
                glib::timeout_add_local_once(std::time::Duration::from_millis(2500), move || {
                    if let Some(grid) = weak.upgrade() {
                        grid.reload();
                    }
                });
            });
        }
        "download" => window.download(ids),
        "open-in-immich" => window.open_in_immich(&ids[0], kind.within()),
        _ => {}
    }
}

/// Ask which album, then add the photos to it (making it first if new).
pub fn add_to_album(window: &Window, ids: Vec<String>, grid: Option<Grid>) {
    let Some(session) = window.session() else { return };
    let albums = window.album_choices();
    let weak_window = window.downgrade();
    dialogs::choose_album(window, albums, move |choice| {
        let Some(window) = weak_window.upgrade() else { return };
        let client = session.connection.client.clone();
        let ids = ids.clone();
        let count = ids.len();
        let (weak_window, grid) = (window.downgrade(), grid.clone());
        crate::tasks::run(
            async move {
                match choice {
                    AlbumChoice::Existing { id, name } => actions::add_to_album(&client, id, ids).await.map(|added| (name, added)),
                    AlbumChoice::New(name) => actions::create_album(&client, name, ids).await.map(|album| (album.name, count)),
                }
            },
            move |outcome| {
                let Some(window) = weak_window.upgrade() else { return };
                match outcome {
                    Ok((name, added)) => {
                        let message = if added == 0 {
                            tr("Already in “{album}”").replace("{album}", &name)
                        } else {
                            tr("Added {items} to “{album}”").replace("{items}", &verso_desktop::text::items(added as u64)).replace("{album}", &name)
                        };
                        window.toast(&message);
                        window.refresh_albums();
                        if let Some(grid) = grid {
                            grid.set_selecting(false);
                        }
                    }
                    Err(message) => window.toast(&message),
                }
            },
        );
    });
}

/// A page that only says something: a section still to come, or one this account cannot open.
pub fn message_page(title: &str, heading: &str, description: &str, icon: &str) -> adw::NavigationPage {
    let status = adw::StatusPage::builder().title(heading).description(description).icon_name(icon).build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&status));
    adw::NavigationPage::builder().title(title).child(&toolbar).build()
}
