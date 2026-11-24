//! The main window: sign in (or find the drive's sign-in), then the library in a sidebar and its pages, with the
//! viewer over the whole window. It also does what several pages share: downloads, Open With, Show in Files (through
//! the drive), links to Immich, and immich-crosslink links from other apps.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::{Album, TimelineScope};
use verso_desktop::connection::{self, Connection};
use verso_desktop::images::Cache;
use verso_desktop::library::{self, Source, Tile};
use verso_desktop::arrangement::GridPage;
use verso_desktop::{albums, links, text};
use verso_core::links::ImmichItem;
use verso_core::sign_in::BrowserSignIn;
use verso_desktop::session::{self, ServerOffer, SignInError, SignedIn};
use verso_linux::i18n::tr;

use crate::grid::Grid;
use crate::pages::{self, Kind, Spec};
use crate::textures::Textures;

/// Cargo rebuilds when the interface changes only if the file is included somewhere it can see.
const _INTERFACE: &str = include_str!("window.blp");

/// A signed-in account and its pictures.
pub struct Session {
    pub connection: Connection,
    pub textures: Rc<Textures>,
    /// What the session's maps draw from (`map_style`).
    pub maps: Rc<crate::map_style::Styles>,
}

/// A sidebar page: its id, title and icon.
type Entry = (&'static str, &'static str, &'static str);

/// The sidebar: headings, each with its pages.
const SIDEBAR: &[(&str, &[Entry])] = &[
    (
        "Photos",
        &[
            ("library", "Library", "image-x-generic-symbolic"),
            ("favorites", "Favorites", "verso-heart-symbolic"),
            ("videos", "Videos", "video-x-generic-symbolic"),
        ],
    ),
    (
        "Explore",
        &[
            ("map", "Map", "find-location-symbolic"),
            ("places", "Places", "mark-location-symbolic"),
            ("memories", "Memories", "document-open-recent-symbolic"),
            ("tags", "Tags", "bookmark-new-symbolic"),
            ("folders", "Folders", "folder-symbolic"),
        ],
    ),
    ("Collections", &[("albums", "Albums", "folder-pictures-symbolic"), ("people", "People", "system-users-symbolic")]),
    ("Sharing", &[("shared-links", "Shared Links", "verso-share-symbolic"), ("partners", "Partners", "avatar-default-symbolic")]),
    (
        "Utilities",
        &[
            ("duplicates", "Duplicates", "edit-copy-symbolic"),
            ("large-files", "Large Files", "drive-harddisk-symbolic"),
            ("assign-location", "Assign Location", "mark-location-symbolic"),
            ("archive", "Archive", "package-x-generic-symbolic"),
            ("trash", "Recently Deleted", "user-trash-symbolic"),
            ("locked", "Locked Folder", "system-lock-screen-symbolic"),
        ],
    ),
];


mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(file = "src/window.blp")]
    pub struct Window {
        #[template_child]
        pub toasts: TemplateChild<adw::ToastOverlay>,
        /// The import at the sidebar's foot, its list and its queue.
        pub imports: RefCell<Option<Rc<crate::imports::Imports>>>,
        /// The notifications' bell beside the account, while signed in.
        pub bell: RefCell<Option<Rc<crate::notifications::Bell>>>,
        #[template_child]
        pub navigation: TemplateChild<adw::NavigationView>,
        /// The sign-in's first page, with the app icon chosen for the style.
        #[template_child]
        pub welcome: TemplateChild<adw::StatusPage>,
        /// The sign-in's first page following libadwaita's style, once it was shown.
        pub welcome_follows_style: RefCell<Option<glib::SignalHandlerId>>,
        #[template_child]
        pub server_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub connect_button: TemplateChild<gtk::Button>,
        /// The offer to take Immich Mount's account over, where it is signed in on this computer.
        #[template_child]
        pub takeover_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub browser_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub browser_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub password_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub email_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub password_row: TemplateChild<adw::PasswordEntryRow>,
        #[template_child]
        pub api_key_row: TemplateChild<adw::PasswordEntryRow>,
        #[template_child]
        pub split_view: TemplateChild<adw::NavigationSplitView>,
        #[template_child]
        pub sidebar: TemplateChild<gtk::ListBox>,
        #[template_child]
        pub content_page: TemplateChild<adw::NavigationPage>,
        #[template_child]
        pub content_view: TemplateChild<adw::NavigationView>,
        #[template_child]
        pub content_overlay: TemplateChild<gtk::Overlay>,
        /// Where the open photo flies between its square and the viewer (`motion`), made when first needed.
        pub flight: RefCell<Option<crate::motion::FlightLayer>>,
        /// The photo the viewer let go of as it started hiding, until it is known whether it closed onto a grid.
        pub closing: RefCell<Option<crate::viewer::Closing>>,
        pub session: RefCell<Option<Rc<Session>>>,
        /// Whether the session's server can be reached, and the banner that says when it cannot (`connectivity`).
        pub connectivity: RefCell<Option<Rc<crate::connectivity::Connectivity>>>,
        pub offer: RefCell<Option<ServerOffer>>,
        /// The certificate the person trusted as they signed in, with the address it was presented for: every step of
        /// signing in to that address trusts it, and it is kept with the server once signed in.
        pub accepted_certificate: RefCell<Option<(String, immich_api::CertificatePin)>>,
        /// The certificate last asked about while the library showed, so the question comes once, not at every check.
        pub asked_certificate: std::cell::Cell<Option<immich_api::CertificatePin>>,
        /// Immich Mount's server, while its account is offered.
        pub immich_mount_server: RefCell<Option<String>>,
        /// What waits for the window to have its account or its sign-in (`Window::when_ready`).
        pub when_ready: RefCell<Vec<super::Waiting>>,
        /// The window shows its account or its sign-in.
        pub ready: std::cell::Cell<bool>,
        pub attempt: RefCell<Option<BrowserSignIn>>,
        /// Each page of photos and its grid, for Refresh and the zoom.
        pub grids: RefCell<Vec<(glib::WeakRef<adw::NavigationPage>, Grid)>>,
        /// The account's albums, most recently changed first.
        pub albums: RefCell<Vec<Album>>,
        /// Links that arrived before the library was ready.
        pub pending: RefCell<Vec<String>>,
        /// The sidebar page shown, by id.
        pub shown: RefCell<String>,
        /// The sidebar is being filled again: its selection changes are not the user's.
        pub filling: std::cell::Cell<bool>,
        /// Edit Sidebar is on: each page and section shows with a switch, to hide or show it.
        pub editing_sidebar: std::cell::Cell<bool>,
        /// Edit Sidebar's Reset and Done, above the account at the sidebar's foot.
        pub sidebar_bar: RefCell<Option<gtk::ActionBar>>,
        /// The sidebar's foot (`Window::sidebar_foot`).
        pub sidebar_foot: RefCell<Option<gtk::Box>>,
        /// The account at the bottom of the sidebar.
        pub account_footer: RefCell<Option<gtk::Box>>,
        /// Edit Sidebar's button beside the account, pressed while editing.
        pub edit_button: RefCell<Option<gtk::ToggleButton>>,
        /// The window's Preferences, while open.
        pub preferences: glib::WeakRef<adw::Window>,
        /// Whether the sidebar was folded before Full Screen or the slideshow folded it.
        pub folded_before: std::cell::Cell<Option<bool>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Window {
        const NAME: &'static str = "ImmichGalleryWindow";
        type Type = super::Window;
        type ParentType = adw::ApplicationWindow;

        fn class_init(class: &mut Self::Class) {
            class.bind_template();
            class.bind_template_callbacks();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    #[gtk::template_callbacks]
    impl Window {
        #[template_callback]
        fn on_connect(&self, #[rest] _values: &[glib::Value]) {
            self.obj().connect_to_server();
        }

        #[template_callback]
        fn on_browser_sign_in(&self, #[rest] _values: &[glib::Value]) {
            self.obj().begin_browser_sign_in();
        }

        #[template_callback]
        fn on_password_sign_in(&self, #[rest] _values: &[glib::Value]) {
            self.obj().sign_in_with_password();
        }

        #[template_callback]
        fn on_api_key_sign_in(&self, #[rest] _values: &[glib::Value]) {
            self.obj().sign_in_with_api_key();
        }

        #[template_callback]
        fn on_take_over(&self, #[rest] _values: &[glib::Value]) {
            self.obj().take_over_immich_mount();
        }

        #[template_callback]
        fn on_sidebar_selected(&self, #[rest] _values: &[glib::Value]) {
            // The list empties as the window is taken down, after its template's children were let go: the selection
            // changes then too, and there is nothing to show (reaching the list then panicked, and Verso crashed on
            // closing its window).
            if self.filling.get() || !self.sidebar.is_bound() {
                return;
            }
            let Some(row) = self.sidebar.selected_row() else { return };
            self.obj().show_section(&row.widget_name());
        }
    }

    impl ObjectImpl for Window {}
    impl WidgetImpl for Window {}
    impl WindowImpl for Window {}
    impl ApplicationWindowImpl for Window {}
    impl AdwApplicationWindowImpl for Window {}
}

glib::wrapper! {
    pub struct Window(ObjectSubclass<imp::Window>)
        @extends adw::ApplicationWindow, gtk::ApplicationWindow, gtk::Window, gtk::Widget,
        @implements gio::ActionGroup, gio::ActionMap, gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget,
            gtk::Native, gtk::Root, gtk::ShortcutManager;
}

/// What waits for the window to be ready (`Window::when_ready`).
type Waiting = Box<dyn FnOnce(&Window)>;

impl Window {
    pub fn new(application: &adw::Application) -> Self {
        let window: Window = glib::Object::builder().property("application", application).build();
        window.install_actions();
        window.install_drop_target();
        window.follow_viewer();
        window.restore_size();
        // Every page shown gets the banner that says when the server cannot be reached.
        for view in [&window.imp().content_view, &window.imp().navigation] {
            let weak = window.downgrade();
            view.connect_visible_page_notify(move |_| {
                if let Some(window) = weak.upgrade() {
                    window.attach_banners();
                }
            });
        }
        if let Some(server) = session::configured_server() {
            window.imp().server_row.set_text(&server);
        }
        window.imp().navigation.replace_with_tags(&["loading"]);
        let shown = window.clone();
        crate::tasks::run(connection::connect(), move |outcome| match outcome {
            Ok(Some(connection)) => {
                // The tray comes back with the window, if it was quit.
                crate::tasks::runtime().spawn_blocking(session::wake_service);
                shown.start_session(connection);
            }
            Ok(None) => shown.show_connect(),
            Err(message) => {
                shown.show_connect();
                shown.toast(&message);
            }
        });
        window
    }

    /// Open at the size the window was last closed at, maximised if it was, as GNOME's apps do (Wayland leaves the
    /// place to the compositor). The first time, three quarters of the screen, as a gallery wants room: a fixed size
    /// was small on a large screen.
    fn restore_size(&self) {
        let settings = verso_desktop::settings::shared();
        let read = |key: &str| settings.get(key).and_then(|value| value.parse::<i32>().ok()).filter(|value| *value > 0);
        match (read("window.width"), read("window.height")) {
            (Some(width), Some(height)) => self.set_default_size(width, height),
            _ => {
                let screen = gdk::Display::default().and_then(|display| display.monitors().item(0)).and_downcast::<gdk::Monitor>().map(|monitor| monitor.geometry());
                if let Some(screen) = screen {
                    let fit = |side: i32, least: i32| ((side * 3) / 4).max(least).min((side * 9) / 10);
                    self.set_default_size(fit(screen.width(), 1000), fit(screen.height(), 700));
                }
            }
        }
        if settings.get("window.maximized").as_deref() == Some("true") {
            self.maximize();
        }
        self.connect_close_request(|window| {
            let settings = verso_desktop::settings::shared();
            // The size it has when not maximised, which GTK keeps as the default size.
            let (width, height) = window.default_size();
            if width > 0 && height > 0 {
                settings.set("window.width", Some(&width.to_string()));
                settings.set("window.height", Some(&height.to_string()));
            }
            settings.set("window.maximized", Some(if window.is_maximized() { "true" } else { "false" }));
            // Gone from the screen at once, taken down a moment later: taking down a long session's pages and pictures
            // held the window on screen for seconds, as if it had hung (reported with a library of 30,000 photos).
            if window.is_visible() {
                window.set_visible(false);
                let window = window.clone();
                glib::timeout_add_local_once(std::time::Duration::from_millis(100), move || window.destroy());
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
    }

    /// Run `then` once the window shows its account or its sign-in. The tray's requests wait for it when they start
    /// the app: Preferences opened while the account is still being read showed a page without it, and GNOME placed
    /// the window partly off screen (on GNOME 50).
    pub fn when_ready(&self, then: impl FnOnce(&Window) + 'static) {
        if self.imp().ready.get() {
            then(self);
        } else {
            self.imp().when_ready.borrow_mut().push(Box::new(then));
        }
    }

    fn now_ready(&self) {
        self.imp().ready.set(true);
        let waiting: Vec<_> = self.imp().when_ready.borrow_mut().drain(..).collect();
        for then in waiting {
            then(self);
        }
    }

    /// The first page, asking for the server; with the offer of Immich Mount's account where it is signed in here.
    fn show_connect(&self) {
        self.imp().welcome.set_icon_name(Some(&crate::app_icon_name()));
        // The look chosen for the style, while the page is shown and the style changes.
        if self.imp().welcome_follows_style.borrow().is_none() {
            let welcome = self.imp().welcome.downgrade();
            let following = adw::StyleManager::default().connect_dark_notify(move |_| {
                if let Some(welcome) = welcome.upgrade() {
                    welcome.set_icon_name(Some(&crate::app_icon_name()));
                }
            });
            self.imp().welcome_follows_style.replace(Some(following));
            self.connect_destroy(|window| {
                if let Some(following) = window.imp().welcome_follows_style.take() {
                    adw::StyleManager::default().disconnect(following);
                }
            });
        }
        self.imp().navigation.replace_with_tags(&["connect"]);
        self.now_ready();
        let window = self.clone();
        crate::tasks::run(session::immich_mount_account(), move |server| {
            let group = &window.imp().takeover_group;
            group.set_visible(server.is_some());
            if let Some(server) = &server {
                group.set_description(Some(&tr("Immich Mount is signed in to {server} on this computer. Verso can use that account, with a sign-in of its own, and show your library in Files as Verso Drive.").replace("{server}", server)));
            }
            window.imp().immich_mount_server.replace(server);
        });
    }

    /// Take Immich Mount's account over (`session::take_over_immich_mount`), then open the library.
    fn take_over_immich_mount(&self) {
        let Some(url) = self.imp().immich_mount_server.borrow().clone() else { return };
        self.set_busy(true);
        let window = self.clone();
        crate::tasks::run(
            async move {
                session::take_over_immich_mount(url).await?;
                let started = session::start_service();
                connection::connect().await.map(|connection| (connection, started))
            },
            move |outcome| {
                window.set_busy(false);
                match outcome {
                    Ok((Some(connection), started)) => {
                        if let Err(message) = started {
                            window.toast(&message);
                        }
                        window.start_session(connection);
                    }
                    Ok((None, _)) => window.toast(tr("Signed in, but the sign-in could not be read back")),
                    Err(message) => window.toast(&message),
                }
            },
        );
    }

    pub fn session(&self) -> Option<Rc<Session>> {
        self.imp().session.borrow().clone()
    }

    /// A message at the window's foot. A failure because the server could not be reached says so once in a while,
    /// as the banner does, rather than once per failure.
    pub fn toast(&self, message: &str) {
        // A refused certificate: the banner says so, and the person is asked about it once.
        if immich_api::is_certificate_text(message) {
            let connectivity = self.imp().connectivity.borrow().clone();
            if let Some(connectivity) = connectivity {
                return connectivity.failed();
            }
        }
        if immich_api::is_offline_text(message) {
            let connectivity = self.imp().connectivity.borrow().clone();
            if let Some(connectivity) = connectivity {
                connectivity.failed();
                if let Some(text) = connectivity.unreachable_toast() {
                    self.show_toast(&text);
                }
                return;
            }
        }
        self.show_toast(message);
    }

    fn show_toast(&self, message: &str) {
        let toast = adw::Toast::new(&glib::markup_escape_text(message));
        toast.set_timeout(4);
        self.imp().toasts.add_toast(toast);
    }

    /// A page could not read what it shows. When the server could not be reached, the banner says so and the page is
    /// read again once it answers; any other failure is a toast.
    pub fn load_failed(&self, message: &str) {
        if immich_api::is_offline_text(message) || immich_api::is_certificate_text(message) {
            let connectivity = self.imp().connectivity.borrow().clone();
            if let Some(connectivity) = connectivity {
                return connectivity.failed();
            }
        }
        self.show_toast(message);
    }

    /// The banner under the header of the pages shown, each page once, that says when the server cannot be reached
    /// (`connectivity`). The library's split view is not one: its content's pages are.
    fn attach_banners(&self) {
        let Some(connectivity) = self.imp().connectivity.borrow().clone() else { return };
        let over = self.imp().navigation.visible_page().filter(|page| page.tag().as_deref() != Some("library"));
        for page in [self.imp().content_view.visible_page(), over].into_iter().flatten() {
            connectivity.attach(&page);
        }
    }

    fn install_actions(&self) {
        let action = |name: &str, run: fn(&Window)| {
            let action = gio::SimpleAction::new(name, None);
            let weak = self.downgrade();
            action.connect_activate(move |_, _| {
                if let Some(window) = weak.upgrade() {
                    run(&window);
                }
            });
            self.add_action(&action);
        };
        action("refresh", |window| window.refresh());
        // Edit Sidebar's moves and sections (`edit_layout`): `op:arguments`.
        let sidebar_edit = gio::SimpleAction::new("sidebar-edit", Some(glib::VariantTy::STRING));
        let weak = self.downgrade();
        sidebar_edit.connect_activate(move |_, request| {
            if let (Some(window), Some(request)) = (weak.upgrade(), request.and_then(|request| request.get::<String>())) {
                window.edit_layout(&request);
            }
        });
        self.add_action(&sidebar_edit);
        // Ctrl+I: the Info panel of the page shown (application shortcuts reach the window's actions, not a page's).
        action("toggle-info", |window| {
            if let Some(page) = window.imp().content_view.visible_page() {
                let _ = WidgetExt::activate_action(&page, "page.toggle-info", None);
            }
        });
        // The album sections' menus: how many, and in which order.
        for section in [albums::Section::Mine, albums::Section::Shared] {
            let name = if section == albums::Section::Mine { "my-albums" } else { "shared-albums" };
            let (limit, sort_by) = section.load(verso_desktop::settings::shared());
            let show = gio::SimpleAction::new_stateful(&format!("{name}-show"), Some(glib::VariantTy::STRING), &limit.map_or("all".to_owned(), |count| count.to_string()).to_variant());
            let sort = gio::SimpleAction::new_stateful(&format!("{name}-sort"), Some(glib::VariantTy::STRING), &sort_by.code().to_variant());
            for action in [&show, &sort] {
                let weak = self.downgrade();
                action.connect_change_state(move |action, value| {
                    let (Some(window), Some(value)) = (weak.upgrade(), value) else { return };
                    action.set_state(value);
                    let settings = verso_desktop::settings::shared();
                    let (mut limit, mut sort_by) = section.load(settings);
                    let chosen = value.get::<String>().unwrap_or_default();
                    if action.name().ends_with("-show") {
                        limit = chosen.parse().ok();
                    } else if let Some(key) = albums::SortBy::from_code(&chosen) {
                        sort_by = key;
                    }
                    section.save(settings, limit, sort_by);
                    window.fill_sidebar();
                });
                self.add_action(action);
            }
        }
        action("import", |window| window.choose_imports(false));
        action("import-folders", |window| window.choose_imports(true));
        action("edit-sidebar", |window| window.edit_sidebar(true));
        action("account-settings", |window| window.show_preferences(Some("account")));
        action("administration", |window| window.show_preferences(Some("admin")));
        action("sign-out", |window| window.confirm_sign_out());
        self.imp().imports.replace(Some(crate::imports::Imports::new(self)));
        action("search", |window| window.select_section("search"));
        action("zoom-in", |window| window.zoom(1));
        action("zoom-out", |window| window.zoom(-1));
        action("new-album", |window| window.new_album());
        action("select-all", |window| {
            if let Some(grid) = window.current_grid() {
                grid.select_all();
            }
        });
        // The shared view's switches, checked in the main menu and pressed in each grid's toolbar: square thumbnails
        // and the Date Scroller, as the Mac gallery's View menu and toolbar have them.
        for (name, shown, set) in [
            ("squares", crate::grid::squares_shown as fn() -> bool, crate::grid::set_squares_shown as fn(bool)),
            ("date-scroller", crate::grid::date_scroller_shown, crate::grid::set_date_scroller_shown),
        ] {
            let switch = gio::SimpleAction::new_stateful(name, None, &shown().to_variant());
            let weak = self.downgrade();
            switch.connect_change_state(move |switch, value| {
                let (Some(window), Some(value)) = (weak.upgrade(), value) else { return };
                switch.set_state(value);
                set(value.get::<bool>().unwrap_or(false));
                window.relayout_grids();
            });
            self.add_action(&switch);
        }
    }

    /// Files dropped anywhere on the window are imported: into the library, or into the album on an album's page.
    /// An album's sidebar row, card and list row take drops of their own (`take_imports_into`).
    fn install_drop_target(&self) {
        let weak = self.downgrade();
        self.add_controller(import_drop_target(move |_, paths| {
            let Some(window) = weak.upgrade().filter(|window| window.session().is_some()) else { return false };
            match window.current_album() {
                Some(album) => window.import_into(paths, &album),
                None => {
                    window.import(paths, None);
                    true
                }
            }
        }));
    }

    /// Files dropped on `widget` (an album's sidebar row or card) are imported into album `id`.
    pub fn take_imports_into(&self, widget: &impl IsA<gtk::Widget>, id: &str) {
        let (weak, id) = (self.downgrade(), id.to_owned());
        widget.add_controller(import_drop_target(move |_, paths| weak.upgrade().is_some_and(|window| window.import_into(paths, &id))));
    }

    /// Files dropped on `widget` are imported into the album its name holds when they are dropped: a list's cell,
    /// bound to one album after another.
    pub fn take_imports_into_named(&self, widget: &impl IsA<gtk::Widget>) {
        let weak = self.downgrade();
        widget.add_controller(import_drop_target(move |target, paths| {
            let id = target.widget().map(|widget| widget.widget_name().to_string()).filter(|id| !id.is_empty());
            match (weak.upgrade(), id) {
                (Some(window), Some(id)) => window.import_into(paths, &id),
                _ => false,
            }
        }));
    }

    /// Import `paths` into album `id`, unless the account may only view it, which the import at the sidebar's foot
    /// says, importing nothing; a toast says it too while that cannot be seen (another import runs, or the sidebar is
    /// folded away).
    fn import_into(&self, paths: Vec<PathBuf>, id: &str) -> bool {
        if self.session().is_none() {
            return false;
        }
        if !self.may_add_to(id) {
            let name = self.imp().albums.borrow().iter().find(|album| album.id == id).map(|album| album.name.clone()).unwrap_or_default();
            let message = tr("You can view “{album}” but not add to it").replace("{album}", &name);
            let imports = self.imp().imports.borrow().clone();
            let said = imports.is_some_and(|imports| imports.stopped(&message));
            let split_view = &self.imp().split_view;
            if !said || (split_view.is_collapsed() && split_view.shows_content()) {
                self.toast(&message);
            }
            return false;
        }
        self.import(paths, Some(id.to_owned()));
        true
    }

    // --- Signing in ---

    fn connect_to_server(&self) {
        let imp = self.imp();
        let address = session::normalised_address(&imp.server_row.text());
        imp.connect_button.set_sensitive(false);
        let window = self.clone();
        let trusted = self.trusted_for(&address);
        crate::tasks::run(session::probe(address.clone(), trusted), move |outcome| {
            let imp = window.imp();
            imp.connect_button.set_sensitive(true);
            match outcome {
                Ok(offer) => {
                    if let Some(label) = &offer.browser_button {
                        imp.browser_button.set_label(label);
                    }
                    imp.browser_group.set_visible(offer.browser_button.is_some());
                    imp.password_group.set_visible(offer.password);
                    imp.offer.replace(Some(offer));
                    imp.navigation.push_by_tag("sign-in");
                }
                // Asked, and on Trust checked again with that certificate trusted for this address alone.
                Err(SignInError::Certificate(refusal)) => window.ask_about_certificate(&refusal, &host_of(&address), move |window, certificate| {
                    window.imp().accepted_certificate.replace(Some((address.clone(), certificate)));
                    window.connect_to_server();
                }),
                Err(SignInError::Failed(message)) => window.toast(&message),
            }
        });
    }

    /// The certificate trusted for `url` as one signs in to it: the one the person trusted just now for this address,
    /// else the one kept for it, where it is the server signed in to.
    fn trusted_for(&self, url: &str) -> Option<immich_api::CertificatePin> {
        let accepted = self.imp().accepted_certificate.borrow().as_ref().filter(|(address, _)| address == url).map(|(_, certificate)| *certificate);
        accepted.or_else(|| session::trusted_certificate_for(url))
    }

    /// Ask whether to trust a certificate the system refused, in Adwaita's own question: what it is, why that matters,
    /// and how to check it; Cancel is the default, and Trust This Certificate runs `on_trust` with its fingerprint.
    pub fn ask_about_certificate(&self, refusal: &immich_api::CertificateRefusal, host: &str, on_trust: impl Fn(&Window, immich_api::CertificatePin) + 'static) {
        let question = session::certificate_question(refusal, host, chrono::Utc::now());
        let dialog = adw::AlertDialog::new(Some(&question.heading), Some(&question.body));
        dialog.set_prefer_wide_layout(true);
        let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        for detail in &question.details {
            let row = adw::ActionRow::builder()
                .title(glib::markup_escape_text(&detail.title))
                .subtitle(glib::markup_escape_text(&detail.value))
                .subtitle_selectable(true)
                .css_classes(["property"])
                .build();
            // The fingerprints, to compare pair by pair.
            if detail.fingerprint {
                row.add_css_class("monospace");
            }
            list.append(&row);
        }
        dialog.set_extra_child(Some(&list));
        dialog.add_responses(&[("cancel", &question.cancel), ("trust", &question.trust)]);
        dialog.set_response_appearance("trust", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let (weak, certificate) = (self.downgrade(), refusal.certificate.sha256);
        dialog.connect_response(Some("trust"), move |_, _| {
            if let Some(window) = weak.upgrade() {
                on_trust(&window, certificate);
            }
        });
        // Over Preferences where it is open, else it would sit hidden under it.
        match self.preferences_window() {
            Some(preferences) => dialog.present(Some(&preferences)),
            None => dialog.present(Some(self)),
        }
    }

    /// The server's certificate was refused while the library showed: ask about it the first time this certificate
    /// is presented (`asked` is the person's own request, from the banner, which asks again). Trusting it keeps it for
    /// the server, restarts the service with it, and connects again.
    fn certificate_refused(&self, refusal: &immich_api::CertificateRefusal, asked: bool) {
        let presented = refusal.certificate.sha256;
        if !asked && self.imp().asked_certificate.replace(Some(presented)) == Some(presented) {
            return;
        }
        let host = self.session().map(|session| host_of(&session.connection.server)).unwrap_or_default();
        self.ask_about_certificate(refusal, &host, |window, certificate| window.trust_and_reconnect(certificate));
    }

    /// Trust `certificate` for the server signed in to, restart the service with it, and open the library again.
    fn trust_and_reconnect(&self, certificate: immich_api::CertificatePin) {
        self.reconnect(move || session::trust_certificate(certificate));
    }

    /// Forget the certificate trusted for the server (Preferences, Account), and connect again: the person is asked
    /// at once, unless the system trusts the server's certificate by now.
    pub fn forget_certificate(&self) {
        self.imp().asked_certificate.set(None);
        self.reconnect(session::forget_certificate);
    }

    /// Change what is trusted for the server with `change`, restart the service with it, and open the library again.
    fn reconnect(&self, change: impl FnOnce() -> Result<(), String> + Send + 'static) {
        self.set_busy(true);
        let window = self.clone();
        crate::tasks::run(
            async move {
                change()?;
                let started = session::start_service();
                connection::connect().await.map(|connection| (connection, started))
            },
            move |outcome| {
                window.set_busy(false);
                match outcome {
                    Ok((Some(connection), started)) => {
                        if let Err(message) = started {
                            window.toast(&message);
                        }
                        window.start_session(connection);
                    }
                    Ok((None, _)) => window.signed_out(),
                    Err(message) => window.toast(&message),
                }
            },
        );
    }

    fn server_url(&self) -> Option<String> {
        self.imp().offer.borrow().as_ref().map(|offer| offer.url.clone())
    }

    fn begin_browser_sign_in(&self) {
        let Some(url) = self.server_url() else { return };
        let attempt = match BrowserSignIn::new() {
            Ok(attempt) => attempt,
            Err(error) => return self.toast(&error.to_string()),
        };
        let (state, challenge) = (attempt.state.clone(), attempt.code_challenge.clone());
        self.imp().attempt.replace(Some(attempt));
        let window = self.clone();
        let trusted = self.trusted_for(&url);
        crate::tasks::run(session::begin_browser_sign_in(url, trusted, state, challenge), move |outcome| match outcome {
            Ok(address) => {
                claim_redirect();
                gtk::UriLauncher::new(&address).launch(Some(&window), gio::Cancellable::NONE, |_| {});
                window.toast(tr("Continue in your browser"));
            }
            Err(message) => window.toast(&message),
        });
    }

    fn handle_redirect(&self, address: &str) {
        let belongs = self.imp().attempt.borrow().as_ref().is_some_and(|attempt| verso_core::sign_in::is_redirect_for(address, &attempt.state));
        let (Some(url), true, Some(attempt)) = (self.server_url(), belongs, if belongs { self.imp().attempt.take() } else { None }) else {
            return self.toast(tr("This sign-in belongs to an earlier attempt. Finish the latest one, or sign in again."));
        };
        let window = self.clone();
        self.set_busy(true);
        let trusted = self.trusted_for(&url);
        crate::tasks::run(session::finish_browser_sign_in(url, trusted, address.to_owned(), attempt), move |outcome| window.finish_sign_in(outcome));
    }

    fn sign_in_with_password(&self) {
        let Some(url) = self.server_url() else { return };
        let imp = self.imp();
        let (email, password) = (imp.email_row.text().to_string(), imp.password_row.text().to_string());
        if email.trim().is_empty() || password.is_empty() {
            return self.toast(tr("Enter your email and password"));
        }
        self.set_busy(true);
        let window = self.clone();
        let trusted = self.trusted_for(&url);
        crate::tasks::run(session::sign_in_with_password(url, trusted, email, password), move |outcome| window.finish_sign_in(outcome));
    }

    fn sign_in_with_api_key(&self) {
        let Some(url) = self.server_url() else { return };
        let key = self.imp().api_key_row.text().to_string();
        if key.trim().is_empty() {
            return self.toast(tr("Enter an API key"));
        }
        self.set_busy(true);
        let window = self.clone();
        let trusted = self.trusted_for(&url);
        crate::tasks::run(session::sign_in_with_api_key(url, trusted, key), move |outcome| window.finish_sign_in(outcome));
    }

    fn set_busy(&self, busy: bool) {
        self.imp().navigation.set_sensitive(!busy);
    }

    /// Keep the credential where the service looks for it, start the service (the tray, and the drive once it is on),
    /// then open the library.
    fn finish_sign_in(&self, outcome: Result<SignedIn, String>) {
        let signed_in = match outcome {
            Ok(signed_in) => signed_in,
            Err(message) => {
                self.set_busy(false);
                return self.toast(&message);
            }
        };
        let Some(url) = self.server_url() else { return self.set_busy(false) };
        self.imp().password_row.set_text("");
        self.imp().api_key_row.set_text("");
        let trusted = self.trusted_for(&url);
        self.imp().accepted_certificate.replace(None);
        let window = self.clone();
        crate::tasks::run(
            async move {
                session::store_credential(url, signed_in.credential, trusted).await?;
                let started = session::start_service();
                connection::connect().await.map(|connection| (connection, started))
            },
            move |outcome| {
                window.set_busy(false);
                match outcome {
                    Ok((Some(connection), started)) => {
                        if let Err(message) = started {
                            window.toast(&message);
                        }
                        window.start_session(connection);
                    }
                    Ok((None, _)) => window.toast(tr("Signed in, but the sign-in could not be read back")),
                    Err(message) => window.toast(&message),
                }
            },
        );
    }

    fn start_session(&self, connection: Connection) {
        let (client, answered) = (connection.client.clone(), connection.account.is_some());
        let (weak, refused) = (self.downgrade(), self.downgrade());
        let connectivity = crate::connectivity::Connectivity::new(
            client,
            move || {
                if let Some(window) = weak.upgrade() {
                    window.refresh();
                }
            },
            move |refusal, asked| {
                if let Some(window) = refused.upgrade() {
                    window.certificate_refused(refusal, asked);
                }
            },
        );
        // Started without an answer from the server: find out at once whether it can be reached.
        if !answered {
            connectivity.ask();
        }
        self.imp().connectivity.replace(Some(connectivity));
        let cache = Cache::new(connection.cache_directory(), connection.client.clone());
        let trimmed = cache.clone();
        crate::tasks::runtime().spawn_blocking(move || trimmed.trim());
        let host = host_of(&connection.server);
        let bell = crate::notifications::Bell::new(self, connection.client.clone(), connection.account_key(), host);
        self.imp().bell.replace(Some(bell));
        let maps = crate::map_style::Styles::new(connection.client.clone());
        let session = Rc::new(Session { textures: Textures::new(cache), connection, maps });
        self.imp().session.replace(Some(session));
        self.imp().grids.borrow_mut().clear();
        self.sidebar_foot();
        self.fill_sidebar();
        self.fill_account_footer();
        self.imp().navigation.replace_with_tags(&["library"]);
        // A new session's pages, over its client: a session started again (a certificate trusted) shows none of the
        // earlier one's.
        self.imp().shown.replace(String::new());
        self.select_section("library");
        self.now_ready();
        self.refresh_albums();
        // Keep the picture cache to its budgets while the app runs, not only at its start.
        let weak = self.downgrade();
        glib::timeout_add_seconds_local(30 * 60, move || {
            let Some(window) = weak.upgrade() else { return glib::ControlFlow::Break };
            if let Some(session) = window.session() {
                let cache = session.textures.cache().clone();
                crate::tasks::runtime().spawn_blocking(move || cache.trim());
            }
            glib::ControlFlow::Continue
        });
        for address in self.imp().pending.take() {
            self.handle_address(&address);
        }
    }

    /// Sign out of the gallery and the drive (one sign-in serves both), after asking.
    pub fn confirm_sign_out(&self) {
        let window = self.clone();
        // Over Preferences where it is open (the tray's Sign Out… opens it on the account), else it would sit hidden
        // under it, in this window.
        let parent: gtk::Widget = self.preferences_window().map_or_else(|| self.clone().upcast(), |preferences| preferences.upcast());
        crate::dialogs::confirm(
            &parent,
            tr("Sign Out?"),
            tr("Verso and its drive sign out together, and what Verso keeps on this computer (thumbnails, and the photos and videos it downloaded) is removed. Files you downloaded to a folder of your own stay. Your library on the server stays as it is."),
            tr("Sign Out"),
            true,
            move || {
                let shown = window.clone();
                crate::tasks::run(async { session::disconnect() }, move |outcome| match outcome {
                    Ok(()) => {
                        if let Some(preferences) = shown.preferences_window() {
                            preferences.close();
                        }
                        // Every window of the app shows the account: all of them sign out.
                        let windows: Vec<Window> = shown.application().map(|application| application.windows().into_iter().filter_map(|window| window.downcast::<Window>().ok()).collect()).unwrap_or_default();
                        for window in windows {
                            window.signed_out();
                        }
                        shown.toast(tr("Signed out"));
                    }
                    Err(message) => shown.toast(&message),
                });
            },
        );
    }

    /// Leave the account: the session, its cache, the albums and pages go, and the sign-in shows.
    fn signed_out(&self) {
        self.close_viewer();
        self.imp().connectivity.take();
        self.imp().bell.take();
        if let Some(session) = self.imp().session.take() {
            let _ = std::fs::remove_dir_all(session.connection.cache_directory());
        }
        self.imp().albums.borrow_mut().clear();
        self.imp().grids.borrow_mut().clear();
        self.imp().shown.replace(String::new());
        self.show_connect();
    }

    // --- The sidebar and its pages ---

    fn fill_sidebar(&self) {
        // Refilling selects the page shown again, which must not open it again (it would pop an album's page).
        self.imp().filling.set(true);
        self.fill_sidebar_rows();
        self.imp().filling.set(false);
    }

    fn fill_sidebar_rows(&self) {
        let sidebar = &self.imp().sidebar;
        sidebar.remove_all();
        let with_api_key = self.session().is_some_and(|session| session.connection.with_api_key);
        let editing = self.imp().editing_sidebar.get();
        let hidden = verso_desktop::sidebar::hidden(verso_desktop::settings::shared());
        let is_hidden = |id: &str| hidden.iter().any(|known| known == id);
        // The sections in the order Edit Sidebar arranged, each with its pages (`sidebar::Layout`).
        let layout = sidebar_layout();
        let albums = self.imp().albums.borrow().clone();
        for section in &layout.sections {
            let hidden_id = format!("section:{}", section.id);
            let title = section_title(section);
            let pages: Vec<&Entry> = layout.pages_in(&section.id).into_iter().filter_map(page_entry).filter(|(id, _, _)| !(*id == "locked" && with_api_key)).collect();
            if editing {
                sidebar.append(&self.editing_section_row(&layout, section, &title, !is_hidden(&hidden_id)));
                for (id, title, icon) in pages {
                    // The Library always shows, so the sidebar never empties.
                    let shown = (*id != "library").then(|| !is_hidden(id));
                    sidebar.append(&self.editing_page_row(&layout, id, tr(title), icon, shown));
                }
                continue;
            }
            if is_hidden(&hidden_id) {
                continue;
            }
            if let Some((album_section, filter)) = album_section_of(&section.id) {
                self.append_album_section(&albums, album_section, filter, &title);
                continue;
            }
            let pages: Vec<&Entry> = pages.into_iter().filter(|(id, _, _)| *id == "library" || !is_hidden(id)).collect();
            if pages.is_empty() {
                continue;
            }
            sidebar.append(&heading_row(&title));
            for (id, title, icon) in pages {
                sidebar.append(&entry_row(id, tr(title), icon));
            }
        }
        if !editing && !self.imp().shown.borrow().is_empty() {
            let shown = self.imp().shown.borrow().clone();
            self.mark_selected(&shown);
        }
    }

    /// An album section: its heading with its Show and Sort menu, as many albums as chosen there, in its order, and Show
    /// All when there are more, as the Mac gallery lists them.
    fn append_album_section(&self, albums: &[Album], section: albums::Section, filter: albums::Filter, title: &str) {
        let sidebar = &self.imp().sidebar;
        let (limit, sort_by) = section.load(verso_desktop::settings::shared());
        let (listed, cut) = section.albums(albums, sort_by, limit);
        if listed.is_empty() {
            return;
        }
        sidebar.append(&album_heading_row(title, section));
        for album in &listed {
            sidebar.append(&self.album_row(album));
        }
        if cut {
            let row = entry_row(&format!("albums-filter:{}", filter.code()), tr("Show All"), "view-more-horizontal-symbolic");
            row.add_css_class("dim-label");
            sidebar.append(&row);
        }
    }

    /// A section in Edit Sidebar: its switch, its menu (Rename and Delete for the user's own, Move Up and Down for
    /// every one), and a place to drop a page, at the section's start.
    fn editing_section_row(&self, layout: &verso_desktop::sidebar::Layout, section: &verso_desktop::sidebar::Section, title: &str, shown: bool) -> gtk::ListBoxRow {
        let menu = gio::Menu::new();
        let target = |op: &str| format!("win.sidebar-edit::{op}:{}", section.id);
        if section.is_custom() {
            menu.append(Some(tr("Rename…")), Some(&target("section-rename")));
        }
        let moving = gio::Menu::new();
        moving.append(Some(tr("Move Up")), Some(&target("section-up")));
        moving.append(Some(tr("Move Down")), Some(&target("section-down")));
        menu.append_section(None, &moving);
        if section.is_custom() {
            let leaving = gio::Menu::new();
            leaving.append(Some(tr("Delete Section")), Some(&target("section-delete")));
            menu.append_section(None, &leaving);
        }
        let row = editing_row(&format!("section:{}", section.id), title, None, Some(shown), Some(&menu));
        if layout.takes_pages(&section.id) {
            let (first, id) = (layout.pages_in(&section.id).first().map(|page| (*page).to_owned()), section.id.clone());
            self.accept_page_drops(&row, move |page, _| match &first {
                Some(first) => format!("page-before:{page}:{first}"),
                None => format!("page-to:{page}:{id}"),
            });
        }
        row
    }

    /// A page in Edit Sidebar: a handle to drag it by, its switch, and its menu: Move Up, Move Down, and Move To each
    /// other section that takes pages.
    fn editing_page_row(&self, layout: &verso_desktop::sidebar::Layout, id: &str, title: &str, icon: &str, shown: Option<bool>) -> gtk::ListBoxRow {
        let menu = gio::Menu::new();
        let moving = gio::Menu::new();
        moving.append(Some(tr("Move Up")), Some(&format!("win.sidebar-edit::page-up:{id}")));
        moving.append(Some(tr("Move Down")), Some(&format!("win.sidebar-edit::page-down:{id}")));
        menu.append_section(None, &moving);
        let here = layout.section_of(id).unwrap_or_default().to_owned();
        let to = gio::Menu::new();
        for section in layout.sections.iter().filter(|section| section.id != here && layout.takes_pages(&section.id)) {
            to.append(Some(&section_title(section)), Some(&format!("win.sidebar-edit::page-to:{id}:{}", section.id)));
        }
        if to.n_items() > 0 {
            menu.append_submenu(Some(tr("Move To")), &to);
        }
        let row = editing_row(id, title, Some(icon), shown, Some(&menu));
        // Dragged by the row, onto another page (before it, or after it past its middle) or a section's heading.
        let source = gtk::DragSource::builder().actions(gdk::DragAction::MOVE).build();
        let dragged = format!("{SIDEBAR_DRAG}{id}");
        source.connect_prepare(move |_, _, _| Some(gdk::ContentProvider::for_value(&dragged.to_value())));
        let weak_row = row.downgrade();
        source.connect_drag_begin(move |source, _| {
            if let Some(row) = weak_row.upgrade() {
                source.set_icon(Some(&gtk::WidgetPaintable::new(Some(&row))), 0, 0);
            }
        });
        row.add_controller(source);
        let pages: Vec<String> = layout.pages_in(&here).into_iter().map(str::to_owned).collect();
        let (target, section) = (id.to_owned(), here);
        self.accept_page_drops(&row, move |page, after| {
            let next = if after { pages.iter().position(|known| *known == target).and_then(|index| pages.get(index + 1)).cloned() } else { Some(target.clone()) };
            match next {
                Some(before) => format!("page-before:{page}:{before}"),
                None => format!("page-to:{page}:{section}"),
            }
        });
        row
    }

    /// Let pages be dropped on `row`: `request` makes the layout's change from the page and whether it fell past the
    /// row's middle. A line shows where it would land.
    fn accept_page_drops(&self, row: &gtk::ListBoxRow, request: impl Fn(&str, bool) -> String + 'static) {
        let drop = gtk::DropTarget::new(String::static_type(), gdk::DragAction::MOVE);
        let below = |row: &gtk::ListBoxRow, y: f64| row.css_classes().iter().any(|class| class == "verso-sidebar-section") || y > f64::from(row.height()) / 2.0;
        drop.connect_motion(move |target, _, y| {
            if let Some(row) = target.widget().and_downcast::<gtk::ListBoxRow>() {
                let after = below(&row, y);
                row.remove_css_class(if after { "verso-drop-before" } else { "verso-drop-after" });
                row.add_css_class(if after { "verso-drop-after" } else { "verso-drop-before" });
            }
            gdk::DragAction::MOVE
        });
        drop.connect_leave(|target| {
            if let Some(row) = target.widget() {
                row.remove_css_class("verso-drop-before");
                row.remove_css_class("verso-drop-after");
            }
        });
        let weak = self.downgrade();
        drop.connect_drop(move |target, value, _, y| {
            let (Some(window), Ok(text)) = (weak.upgrade(), value.get::<String>()) else { return false };
            let Some(page) = text.strip_prefix(SIDEBAR_DRAG) else { return false };
            let Some(row) = target.widget().and_downcast::<gtk::ListBoxRow>() else { return false };
            let after = below(&row, y);
            let request = request(page, after);
            // After the drop has finished: the change fills the sidebar again, taking this row away.
            glib::idle_add_local_once(move || window.edit_layout(&request));
            true
        });
        row.add_controller(drop);
    }

    /// Change the sidebar's layout, as Edit Sidebar's menus, drags and New Section ask (`op:arguments`), remember it,
    /// and fill the sidebar again.
    fn edit_layout(&self, request: &str) {
        let settings = verso_desktop::settings::shared();
        let mut layout = sidebar_layout();
        let (op, rest) = request.split_once(':').unwrap_or((request, ""));
        let two = || rest.split_once(':').unwrap_or((rest, ""));
        let changed = match op {
            "page-up" => layout.step_page(rest, -1),
            "page-down" => layout.step_page(rest, 1),
            "page-to" => {
                let (page, section) = two();
                layout.move_page(page, section, None)
            }
            "page-before" => {
                let (page, before) = two();
                let section = layout.section_of(before).unwrap_or_default().to_owned();
                layout.move_page(page, &section, Some(before))
            }
            "section-up" => layout.step_section(rest, -1),
            "section-down" => layout.step_section(rest, 1),
            "section-delete" => {
                let deleted = layout.remove_section(rest);
                if deleted {
                    verso_desktop::sidebar::set_hidden(settings, &format!("section:{rest}"), false);
                }
                deleted
            }
            "section-rename" | "section-new" => {
                let current = layout.sections.iter().find(|section| section.id == rest).and_then(|section| section.name.clone()).unwrap_or_default();
                let (heading, yes) = if op == "section-new" { (tr("New Section"), tr("Add")) } else { (tr("Rename Section"), tr("Rename")) };
                let (weak, id, new) = (self.downgrade(), rest.to_owned(), op == "section-new");
                crate::dialogs::ask_text(self, heading, tr("Name"), &current, yes, move |name| {
                    let Some(window) = weak.upgrade() else { return };
                    let mut layout = sidebar_layout();
                    let changed = if new { layout.add_section(&name).is_some() } else { layout.rename_section(&id, &name) };
                    if changed {
                        layout.save(verso_desktop::settings::shared());
                        window.fill_sidebar();
                    }
                });
                false
            }
            _ => false,
        };
        if changed {
            layout.save(settings);
            self.fill_sidebar();
        }
    }

    /// The sidebar's foot, made once: Edit Sidebar's Reset and Done while it is on, the import while there is one
    /// (`imports`), and the account with the notifications' bell (`notifications`) and Edit Sidebar's button.
    fn sidebar_foot(&self) -> gtk::Box {
        if let Some(foot) = self.imp().sidebar_foot.borrow().clone() {
            return foot;
        }
        let foot = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        if let Some(imports) = self.imp().imports.borrow().as_ref() {
            foot.append(imports.widget());
        }
        if let Some(toolbar) = self.imp().sidebar.ancestor(adw::ToolbarView::static_type()).and_downcast::<adw::ToolbarView>() {
            toolbar.add_bottom_bar(&foot);
        }
        self.imp().sidebar_foot.replace(Some(foot.clone()));
        foot
    }

    /// Keep one of Verso's notifications, in the bell beside the account.
    pub fn keep_notification(&self, notification: verso_desktop::notifications::Notification) {
        let bell = self.imp().bell.borrow().clone();
        if let Some(bell) = bell {
            bell.add(notification);
        }
    }

    /// The account at the bottom of the sidebar, as the Mac gallery's: a button with its picture, its name and server
    /// and an arrow, lighting up under the pointer, opening a menu with the name, email and storage used, Account
    /// Settings, Preferences, Administration for an admin, and Sign Out; and beside it the notifications' bell and Edit
    /// Sidebar's button.
    pub fn fill_account_footer(&self) {
        let Some(session) = self.session() else { return };
        if let Some(account) = session.connection.account.clone() {
            self.build_account_footer(&account);
        }
        // Read again, so a new name, picture or storage shows.
        let (client, weak) = (session.connection.client.clone(), self.downgrade());
        crate::tasks::run(async move { client.me().await.ok() }, move |account| {
            if let (Some(window), Some(account)) = (weak.upgrade(), account) {
                window.build_account_footer(&account);
            }
        });
    }

    fn build_account_footer(&self, account: &immich_api::UserDetails) {
        let Some(session) = self.session() else { return };
        let existing = self.imp().account_footer.borrow().clone();
        let footer = match existing {
            Some(footer) => footer,
            None => {
                let footer = gtk::Box::builder().spacing(6).margin_top(6).margin_bottom(6).margin_start(6).margin_end(6).build();
                self.sidebar_foot().append(&footer);
                self.imp().account_footer.replace(Some(footer.clone()));
                footer
            }
        };
        while let Some(child) = footer.first_child() {
            footer.remove(&child);
        }
        let name = if account.name.trim().is_empty() { account.email.clone() } else { account.name.clone() };
        let avatar = adw::Avatar::new(28, Some(&name), true);
        let host = host_of(&session.connection.server);
        let labels = gtk::Box::builder().orientation(gtk::Orientation::Vertical).valign(gtk::Align::Center).build();
        labels.append(&gtk::Label::builder().label(&name).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build());
        labels.append(&gtk::Label::builder().label(&host).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["caption", "dim-label"]).build());
        let content = gtk::Box::builder().spacing(8).build();
        content.append(&avatar);
        labels.set_hexpand(true);
        content.append(&labels);
        // The menu opens upward: the arrow says the row is a menu.
        content.append(&gtk::Image::builder().icon_name("pan-up-symbolic").css_classes(["dim-label"]).valign(gtk::Align::Center).build());
        let used = account.quota_usage_in_bytes.map(|used| match account.quota_size_in_bytes.filter(|quota| *quota > 0) {
            Some(quota) => tr("{used} of {quota} used").replace("{used}", &text::size(used)).replace("{quota}", &text::size(quota)),
            None => tr("{used} used").replace("{used}", &text::size(used)),
        });
        // Who is signed in, at the menu's top: the name, then the email and the storage used, as information.
        let menu = gio::Menu::new();
        let who = gio::Menu::new();
        let card = gio::MenuItem::new(None, None);
        card.set_attribute_value("custom", Some(&"account".to_variant()));
        who.append_item(&card);
        menu.append_section(None, &who);
        let settings = gio::Menu::new();
        settings.append(Some(tr("Account Settings…")), Some("win.account-settings"));
        settings.append(Some(tr("Preferences…")), Some("app.preferences"));
        if session.connection.is_admin() {
            settings.append(Some(tr("Administration…")), Some("win.administration"));
        }
        menu.append_section(None, &settings);
        let leaving = gio::Menu::new();
        leaving.append(Some(tr("Sign Out…")), Some("win.sign-out"));
        menu.append_section(None, &leaving);
        let button = gtk::MenuButton::builder().child(&content).menu_model(&menu).hexpand(true).css_classes(["verso-account"]).tooltip_text(tr("Account")).build();
        if let Some(popover) = button.popover().and_downcast::<gtk::PopoverMenu>() {
            let details = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).margin_start(12).margin_end(12).margin_top(6).margin_bottom(6).build();
            details.append(&gtk::Label::builder().label(&name).xalign(0.0).css_classes(["heading"]).build());
            for line in std::iter::once(account.email.clone()).chain(used) {
                details.append(&gtk::Label::builder().label(&line).xalign(0.0).css_classes(["caption", "dim-label"]).build());
            }
            popover.add_child(&details, "account");
        }
        footer.append(&button);
        if let Some(bell) = self.imp().bell.borrow().as_ref() {
            footer.append(&bell.button);
        }
        let edit = gtk::ToggleButton::builder().icon_name("document-edit-symbolic").tooltip_text(tr("Edit Sidebar")).active(self.imp().editing_sidebar.get()).valign(gtk::Align::Center).css_classes(["flat"]).build();
        let weak = self.downgrade();
        edit.connect_toggled(move |edit| {
            if let Some(window) = weak.upgrade().filter(|window| window.imp().editing_sidebar.get() != edit.is_active()) {
                window.edit_sidebar(edit.is_active());
            }
        });
        footer.append(&edit);
        self.imp().edit_button.replace(Some(edit));
        let (client, user_id, weak_avatar) = (session.connection.client.clone(), account.id.clone(), avatar.downgrade());
        crate::tasks::run(async move { client.profile_image(&user_id).await.ok().map(|media| media.bytes.to_vec()) }, move |picture| {
            if let (Some(avatar), Some(bytes)) = (weak_avatar.upgrade(), picture) {
                if let Ok(texture) = gtk::gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)) {
                    avatar.set_custom_image(Some(&texture));
                }
            }
        });
    }

    /// Edit Sidebar on or off: on, each page and section shows with a switch, and Reset and Done show under the list,
    /// above the account. Shown and hidden, not revealed: the revealer kept its room after Done.
    pub fn edit_sidebar(&self, on: bool) {
        self.imp().editing_sidebar.set(on);
        if let Some(edit) = self.imp().edit_button.borrow().as_ref().filter(|edit| edit.is_active() != on) {
            edit.set_active(on);
        }
        if self.imp().sidebar_bar.borrow().is_none() {
            let reset = gtk::Button::builder().label(tr("Reset Sidebar…")).build();
            let done = gtk::Button::builder().label(tr("Done")).css_classes(["suggested-action"]).build();
            let add = gtk::Button::builder().icon_name("list-add-symbolic").tooltip_text(tr("New Section…")).action_name("win.sidebar-edit").action_target(&"section-new:".to_variant()).build();
            let bar = gtk::ActionBar::new();
            bar.pack_start(&reset);
            bar.pack_end(&done);
            bar.pack_end(&add);
            self.sidebar_foot().prepend(&bar);
            let weak = self.downgrade();
            done.connect_clicked(move |_| {
                if let Some(window) = weak.upgrade() {
                    window.edit_sidebar(false);
                }
            });
            let weak = self.downgrade();
            reset.connect_clicked(move |_| {
                let Some(window) = weak.upgrade() else { return };
                let again = window.downgrade();
                crate::dialogs::confirm(&window, tr("Reset the Sidebar?"), tr("Every page and section shows again, where it first was, and your own sections go."), tr("Reset"), false, move || {
                    if let Some(window) = again.upgrade() {
                        verso_desktop::sidebar::reset(verso_desktop::settings::shared());
                        window.fill_sidebar();
                    }
                });
            });
            self.imp().sidebar_bar.replace(Some(bar));
        }
        if let Some(bar) = self.imp().sidebar_bar.borrow().as_ref() {
            bar.set_visible(on);
        }
        self.fill_sidebar();
    }

    /// A sidebar row for an album: its cover, small, and its name. Files dropped on it are imported into the album.
    fn album_row(&self, album: &Album) -> gtk::ListBoxRow {
        let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
        let cover = crate::collections::SquareFrame::new(20, &picture);
        cover.add_css_class("gallery-sidebar-cover");
        cover.set_valign(gtk::Align::Center);
        if let (Some(session), Some(id)) = (self.session(), album.thumbnail_asset_id.clone()) {
            let weak = picture.downgrade();
            session.textures.get(verso_desktop::images::Kind::Thumbnail, &id, None, move |texture| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(&texture));
                }
            });
        }
        let content = gtk::Box::builder().spacing(12).build();
        content.append(&cover);
        content.append(&gtk::Label::builder().label(&album.name).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build());
        let row = gtk::ListBoxRow::builder().child(&content).name(format!("album:{}", album.id)).build();
        self.take_imports_into(&row, &album.id);
        row
    }

    /// Mark the sidebar's row for `id`; a page with none (Search, from the header) leaves no row marked.
    fn mark_selected(&self, id: &str) {
        let sidebar = &self.imp().sidebar;
        let mut index = 0;
        while let Some(row) = sidebar.row_at_index(index) {
            if row.widget_name() == id {
                if sidebar.selected_row().as_ref() != Some(&row) {
                    sidebar.select_row(Some(&row));
                }
                return;
            }
            index += 1;
        }
        sidebar.unselect_all();
    }

    /// The sidebar page shown, by id.
    pub fn shown_section(&self) -> String {
        self.imp().shown.borrow().clone()
    }

    /// Show a section from its start, read again, even when it is the one shown.
    pub fn reopen_section(&self, id: &str) {
        self.mark_selected(id);
        self.show_section(id);
    }

    /// Photos are being found or imported.
    pub fn importing(&self) -> bool {
        self.imp().imports.borrow().as_ref().is_some_and(|imports| imports.busy())
    }

    pub fn select_section(&self, id: &str) {
        self.mark_selected(id);
        if *self.imp().shown.borrow() != id {
            self.show_section(id);
        }
    }

    fn show_section(&self, id: &str) {
        if self.session().is_none() {
            return;
        }
        self.imp().shown.replace(id.to_owned());
        let page = self.section_page(id);
        self.imp().content_page.set_title(&page.title());
        self.imp().content_view.replace(&[page]);
        self.imp().split_view.set_show_content(true);
    }

    fn section_page(&self, id: &str) -> adw::NavigationPage {
        let grid_page = |spec: Spec| pages::grid_page(self, spec).0;
        match id {
            "library" => grid_page(Spec::new(tr("Library"), Source::Timeline(TimelineScope::LibraryStacked), Kind::Library).arranged(GridPage::Library).empty(tr("No Photos Yet"), "image-x-generic-symbolic")),
            "favorites" => grid_page(Spec::new(tr("Favorites"), Source::Timeline(TimelineScope::Favorites), Kind::Favorites).arranged(GridPage::Favorites).empty(tr("No Favorites"), "verso-heart-symbolic")),
            "videos" => grid_page(Spec::new(tr("Videos"), Source::Search(Box::new(library::videos_query())), Kind::Plain).arranged(GridPage::Videos).empty(tr("No Videos"), "video-x-generic-symbolic")),
            "archive" => grid_page(Spec::new(tr("Archive"), Source::Timeline(TimelineScope::Archive), Kind::Archive).arranged(GridPage::Archive).empty(tr("Nothing Archived"), "package-x-generic-symbolic")),
            "trash" => grid_page(self.trash_spec()),
            "locked" => crate::collections::locked_page(self),
            "albums" => crate::albums_page::albums_page(self),
            "people" => crate::people_page::people_page(self),
            "map" => crate::map::map_page(self),
            "places" => crate::explore::places_page(self),
            "search" => crate::search_page::search_page(self),
            "memories" => crate::memories::memories_page(self),
            "tags" => crate::utility_pages::tags_page(self),
            "folders" => crate::explore::folders_page(self),
            "shared-links" => crate::links_page::shared_links_page(self),
            "partners" => crate::utility_pages::partners_page(self),
            "duplicates" => crate::utility_pages::duplicates_page(self),
            "large-files" => crate::explore::large_files_page(self),
            "assign-location" => crate::explore::assign_location_page(self),
            other if other.starts_with("albums-filter:") => {
                // A section's Show All: the Albums page, showing that section's albums.
                if let Some(filter) = albums::Filter::from_code(&other["albums-filter:".len()..]) {
                    let settings = verso_desktop::settings::shared();
                    let arrangement = albums::Arrangement { filter, ..albums::Arrangement::load(settings) };
                    arrangement.save(settings);
                }
                crate::albums_page::albums_page(self)
            }
            other => match other.strip_prefix("album:") {
                Some(album_id) => {
                    let name = self.imp().albums.borrow().iter().find(|album| album.id == album_id).map(|album| album.name.clone()).unwrap_or_default();
                    crate::album_page::album_page(self, album_id, &name)
                }
                None => pages::message_page(other, tr("Not Here Yet"), "", "dialog-question-symbolic"),
            },
        }
    }

    fn trash_spec(&self) -> Spec {
        let mut spec = Spec::new(tr("Recently Deleted"), Source::Timeline(TimelineScope::Trash), Kind::Trash).empty(tr("The Trash Is Empty"), "user-trash-symbolic");
        let menu = gio::Menu::new();
        menu.append(Some(tr("Restore All")), Some("page.restore-all"));
        menu.append(Some(tr("Empty Trash…")), Some("page.empty-trash"));
        spec.menu = Some(menu);
        let restore = gio::SimpleAction::new("restore-all", None);
        let weak = self.downgrade();
        restore.connect_activate(move |_, _| {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let client = session.connection.client.clone();
            let shown = window.clone();
            crate::tasks::run(async move { client.restore_trash().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                match outcome {
                    Ok(count) => shown.toast(&tr("Restored {items}").replace("{items}", &text::items(count))),
                    Err(message) => shown.toast(&message),
                }
                shown.refresh();
            });
        });
        let empty = gio::SimpleAction::new("empty-trash", None);
        let weak = self.downgrade();
        empty.connect_activate(move |_, _| {
            let Some(window) = weak.upgrade() else { return };
            let shown = window.clone();
            crate::dialogs::confirm(&window, tr("Empty the Trash?"), tr("Everything in Recently Deleted is deleted from Immich for good. This cannot be undone."), tr("Empty Trash"), true, move || {
                let Some(session) = shown.session() else { return };
                let client = session.connection.client.clone();
                let done = shown.clone();
                crate::tasks::run(async move { verso_desktop::actions::empty_trash(&client).await }, move |outcome| {
                    match outcome {
                        Ok(count) => done.toast(&tr("Deleted {items} for good").replace("{items}", &text::items(count))),
                        Err(message) => done.toast(&message),
                    }
                    done.refresh();
                });
            });
        });
        spec.actions = vec![restore, empty];
        spec
    }

    /// Open a page on top of the section shown (an album from the albums page, say).
    pub fn push_page(&self, page: &adw::NavigationPage) {
        self.imp().content_view.push(page);
        self.imp().split_view.set_show_content(true);
    }

    /// Show `page` as the section's own (the Locked Folder's photos once unlocked).
    pub fn replace_section_page(&self, page: &adw::NavigationPage) {
        self.imp().content_view.replace(std::slice::from_ref(page));
    }

    pub fn open_album(&self, id: &str, name: &str) {
        let page = crate::album_page::album_page(self, id, name);
        self.push_page(&page);
    }

    /// Show an album's page again, read anew, in place of the one shown (after the album changed).
    pub fn open_album_again(&self, id: &str, name: &str) {
        let shown = self.imp().content_view.visible_page();
        if shown.as_ref().and_then(|page| page.tag()).as_deref() == Some(&format!("album:{id}")) {
            let page = crate::album_page::album_page(self, id, name);
            let mut stack: Vec<adw::NavigationPage> = Vec::new();
            let pages = self.imp().content_view.navigation_stack();
            for position in 0..pages.n_items() {
                if let Some(known) = pages.item(position).and_downcast::<adw::NavigationPage>() {
                    stack.push(if Some(&known) == shown.as_ref() { page.clone() } else { known });
                }
            }
            self.imp().content_view.replace(&stack);
        }
    }

    pub fn open_person(&self, id: &str, name: &str) {
        let page = crate::people_page::person_page(self, id, name);
        self.push_page(&page);
    }

    /// Show a photo in the Library, selected, at its month (Show in All Photos).
    pub fn show_in_library(&self, tile: &Tile) {
        self.select_section("library");
        let Some(month) = immich_api::YearMonth::new(chrono::Datelike::year(&tile.taken), chrono::Datelike::month(&tile.taken)) else { return };
        if let Some(grid) = self.current_grid() {
            grid.reveal(month, &tile.id);
        }
    }

    /// Whether the page is still among the content's pages: shown, or under one pushed over it.
    pub fn holds_page(&self, page: &adw::NavigationPage) -> bool {
        let stack = self.imp().content_view.navigation_stack();
        (0..stack.n_items()).any(|position| stack.item(position).is_some_and(|item| item == *page.upcast_ref::<glib::Object>()))
    }

    /// Read every grid of the window again, after a change that shows in more than one (a stack's primary, say).
    /// While photos are imported: the grids show those come in so far, reading again only the months that changed, and
    /// an album's page its header.
    pub fn show_imports_so_far(&self) {
        let grids: Vec<Grid> = self.imp().grids.borrow().iter().filter(|(page, _)| page.upgrade().is_some()).map(|(_, grid)| grid.clone()).collect();
        for grid in grids {
            grid.reread_changed();
        }
        if let Some(page) = self.imp().content_view.visible_page() {
            let _ = page.activate_action("page.reread", None);
        }
    }

    pub fn reload_grids(&self) {
        let grids: Vec<Grid> = self.imp().grids.borrow().iter().filter(|(page, _)| page.upgrade().is_some()).map(|(_, grid)| grid.clone()).collect();
        for grid in grids {
            grid.reload();
        }
    }

    /// Lay every grid of the window out again: the Date Scroller was shown or hidden.
    pub fn relayout_grids(&self) {
        let grids: Vec<Grid> = self.imp().grids.borrow().iter().filter(|(page, _)| page.upgrade().is_some()).map(|(_, grid)| grid.clone()).collect();
        for grid in grids {
            grid.relayout();
        }
    }

    pub fn register_grid(&self, page: &adw::NavigationPage, grid: &Grid) {
        let mut grids = self.imp().grids.borrow_mut();
        grids.retain(|(page, _)| page.upgrade().is_some());
        grids.push((page.downgrade(), grid.clone()));
    }

    /// The grid of the page shown, if it has one.
    fn current_grid(&self) -> Option<Grid> {
        let page = self.imp().content_view.visible_page()?;
        self.imp().grids.borrow().iter().find(|(shown, _)| shown.upgrade().as_ref() == Some(&page)).map(|(_, grid)| grid.clone())
    }

    /// The album whose page is shown, for drops.
    fn current_album(&self) -> Option<String> {
        let page = self.imp().content_view.visible_page()?;
        page.tag().and_then(|tag| tag.strip_prefix("album:").map(str::to_owned))
    }

    pub fn refresh(&self) {
        // The page's id is taken out first: showing it again sets it, which a borrow held here would refuse.
        let shown = self.imp().shown.borrow().clone();
        if let Some(grid) = self.current_grid() {
            grid.reload();
        } else if !shown.is_empty() {
            self.show_section(&shown);
        }
        // A page with a header of its own (an album's) reads it again; others have no such action.
        if let Some(page) = self.imp().content_view.visible_page() {
            let _ = page.activate_action("page.reread", None);
        }
        self.refresh_albums();
    }

    /// Bigger or smaller thumbnails, on every grid, as the Mac gallery's one size; on a page of cards or faces, bigger
    /// or smaller cards (`cards`).
    fn zoom(&self, steps: i32) {
        let on_cards = self.imp().content_view.visible_page().is_some_and(|page| page.has_css_class("verso-card-page"));
        if on_cards {
            crate::cards::zoom(steps);
        } else if crate::grid::zoom(steps) {
            self.relayout_grids();
        }
    }

    // --- Albums ---

    /// Read the albums again: the sidebar's list and the choices for Add to Album.
    pub fn refresh_albums(&self) {
        let Some(session) = self.session() else { return };
        let client = session.connection.client.clone();
        let window = self.clone();
        crate::tasks::run(async move { client.albums().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            if let Ok(mut albums) = outcome {
                albums.sort_by_key(|album| std::cmp::Reverse(album.updated_at));
                window.imp().albums.replace(albums);
                window.fill_sidebar();
            }
        });
    }

    pub fn albums(&self) -> Vec<Album> {
        self.imp().albums.borrow().clone()
    }

    /// The albums photos can be added to: the account's own, and those it may edit.
    pub fn album_choices(&self) -> Vec<(String, String)> {
        let user = self.session().and_then(|session| session.connection.user_id().map(str::to_owned));
        self.imp().albums.borrow().iter().filter(|album| adds_to(album, user.as_deref())).map(|album| (album.id.clone(), album.name.clone())).collect()
    }

    /// Whether the account may add photos to album `id`; one not listed yet is left to the server.
    fn may_add_to(&self, id: &str) -> bool {
        let user = self.session().and_then(|session| session.connection.user_id().map(str::to_owned));
        self.imp().albums.borrow().iter().find(|album| album.id == id).is_none_or(|album| adds_to(album, user.as_deref()))
    }

    fn new_album(&self) {
        let weak = self.downgrade();
        crate::dialogs::ask_text(self, tr("New Album"), tr("Name"), "", tr("Create"), move |name| {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let client = session.connection.client.clone();
            let shown = window.clone();
            crate::tasks::run(async move { verso_desktop::actions::create_album(&client, name, Vec::new()).await }, move |outcome| match outcome {
                Ok(album) => {
                    shown.refresh_albums();
                    shown.open_album(&album.id, &album.name);
                }
                Err(message) => shown.toast(&message),
            });
        });
    }

    // --- The viewer ---

    /// A photo opens beside the sidebar, as a page over the one it came from: in place, its photo zooming out of its
    /// square while the page it leaves fades (`motion`), as on the Mac. It opens once the frame the click changed (the
    /// photo selected) is drawn: a still of the page taken before its layout came out empty.
    pub fn open_viewer(&self, tiles: Vec<Tile>, index: usize, kind: Kind) {
        let Some(clock) = self.imp().content_view.frame_clock() else { return self.show_viewer(tiles, index, kind) };
        let pending = Rc::new(RefCell::new(Some((tiles, index, kind))));
        let handler: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::default();
        let open = {
            let (window, pending, handler, clock) = (self.downgrade(), pending.clone(), handler.clone(), clock.clone());
            move || {
                if let Some(id) = handler.take() {
                    clock.disconnect(id);
                }
                if let (Some(window), Some((tiles, index, kind))) = (window.upgrade(), pending.take()) {
                    window.show_viewer(tiles, index, kind);
                }
            }
        };
        let after_paint = open.clone();
        handler.replace(Some(clock.connect_after_paint(move |_| after_paint())));
        clock.request_phase(gdk::FrameClockPhase::AFTER_PAINT);
        // A window not drawn (minimised) has no next frame: it opens anyway.
        glib::timeout_add_local_once(std::time::Duration::from_millis(150), open);
    }

    fn show_viewer(&self, tiles: Vec<Tile>, index: usize, kind: Kind) {
        let grid = self.current_grid();
        let overlay = self.imp().content_overlay.get();
        let square = grid.as_ref().zip(tiles.get(index)).and_then(|(grid, tile)| grid.tile_picture(&tile.id));
        let opening = square.and_then(|picture| {
            Some(crate::viewer::Opening {
                thumbnail: picture.paintable()?,
                from: picture.compute_bounds(&overlay)?,
                backdrop: self.imp().content_view.visible_page().and_then(|page| crate::motion::still(&page)),
            })
        });
        let page = crate::viewer::viewer_page(self, tiles, index, kind, grid, opening);
        self.imp().content_view.push(&page);
    }

    /// The layer the photo flies on, over the pages, and the overlay its places are measured in.
    pub(crate) fn flight_layer(&self) -> (crate::motion::FlightLayer, gtk::Overlay) {
        let overlay = self.imp().content_overlay.get();
        let layer = self.imp().flight.borrow_mut().get_or_insert_with(|| {
            let layer = crate::motion::FlightLayer::default();
            overlay.add_overlay(&layer);
            layer
        }).clone();
        (layer, overlay)
    }

    /// The viewer, as it starts hiding, lets go of its photo (`viewer::State::leaving`).
    pub(crate) fn viewer_leaving(&self, closing: crate::viewer::Closing) {
        self.imp().closing.replace(Some(closing));
    }

    /// The viewer's photo flies back into its square when the viewer closes onto the grid (pages, the viewer's
    /// included, switch in place). A page pushed over the viewer, or a section chosen, is no closing.
    fn follow_viewer(&self) {
        let content = self.imp().content_view.get();
        let weak = self.downgrade();
        content.connect_popped(move |_, page| {
            let Some(window) = weak.upgrade() else { return };
            let closing = window.imp().closing.take();
            if let Some(closing) = closing.filter(|_| page.tag().is_some_and(|tag| tag == "viewer")) {
                window.fly_back(closing);
            }
        });
        let weak = self.downgrade();
        content.connect_pushed(move |content| {
            if let Some(window) = weak.upgrade() {
                window.page_changed(content);
            }
        });
        let weak = self.downgrade();
        content.connect_replaced(move |content| {
            if let Some(window) = weak.upgrade() {
                window.page_changed(content);
            }
        });
    }

    /// Another page came over the content (the viewer's own included): a zoom flying to the page that was there lands
    /// at once, and a photo the viewer let go of is no closing.
    fn page_changed(&self, content: &adw::NavigationView) {
        self.imp().closing.replace(None);
        let viewer_shown = content.visible_page().and_then(|page| page.tag()).is_some_and(|tag| tag == "viewer");
        if let (Some(layer), false) = (self.imp().flight.borrow().clone(), viewer_shown) {
            layer.land();
        }
    }

    /// The viewer closed onto a page: its photo flies back into its square, brought into view, while the viewer
    /// fades; zoomed in, or a video, the viewer only fades.
    fn fly_back(&self, closing: crate::viewer::Closing) {
        let (layer, overlay) = self.flight_layer();
        let grid = self.current_grid();
        if let Some(grid) = &grid {
            grid.bring_into_view(&closing.id);
        }
        let Some((photo, from)) = closing.lifted else {
            let nowhere = gtk::graphene::Rect::zero();
            layer.fly(crate::motion::Flight { backdrop: closing.backdrop, photo: Box::new(|| None), from: nowhere, to: Box::new(move || Some(nowhere)), done: Box::new(|| {}) });
            return;
        };
        // The square it lands on stays empty until it has.
        let hidden: Rc<RefCell<Option<gtk::Picture>>> = Rc::default();
        let (weak_grid, id, hiding) = (grid.as_ref().map(Grid::downgrade), closing.id.clone(), hidden.clone());
        let to = Box::new(move || {
            let picture = weak_grid.as_ref()?.upgrade()?.tile_picture(&id)?;
            let bounds = picture.compute_bounds(&overlay)?;
            if hiding.borrow().as_ref() != Some(&picture) {
                if let Some(earlier) = hiding.replace(Some(picture.clone())) {
                    earlier.set_opacity(1.0);
                }
                picture.set_opacity(0.0);
            }
            Some(bounds)
        });
        let done = Box::new(move || {
            if let Some(picture) = hidden.take() {
                picture.set_opacity(1.0);
            }
        });
        layer.fly(crate::motion::Flight { backdrop: closing.backdrop, photo: Box::new(move || Some(photo.clone())), from, to, done });
    }

    /// Full Screen and the slideshow show the photo alone: the sidebar folds away while they run.
    pub fn set_presenting(&self, presenting: bool) {
        let split = &self.imp().split_view;
        if presenting {
            if self.imp().folded_before.get().is_none() {
                self.imp().folded_before.set(Some(split.is_collapsed()));
            }
            split.set_collapsed(true);
            split.set_show_content(true);
        } else if let Some(folded) = self.imp().folded_before.take() {
            split.set_collapsed(folded);
        }
    }

    /// A page over the whole window, as the viewer is: a memory's player.
    pub fn present_over(&self, page: &adw::NavigationPage) {
        self.imp().navigation.push(page);
    }

    /// Back from a page over the whole window.
    pub fn close_over(&self) {
        self.imp().navigation.pop();
    }

    pub fn close_viewer(&self) {
        let content = &self.imp().content_view;
        if content.visible_page().and_then(|page| page.tag()).is_some_and(|tag| tag == "viewer") {
            content.pop();
        }
    }

    // --- Files: downloads, Open With, Show in Files ---

    /// Download the originals of `ids`, unchanged, into a folder the user picks.
    pub fn download(&self, ids: Vec<String>) {
        let Some(session) = self.session() else { return };
        let dialog = gtk::FileDialog::builder().title(tr("Download Originals To")).accept_label(tr("Download")).build();
        let window = self.clone();
        dialog.select_folder(Some(self), gio::Cancellable::NONE, move |chosen| {
            let Some(folder) = chosen.ok().and_then(|folder| folder.path()) else { return };
            let client = session.connection.client.clone();
            let count = ids.len();
            window.toast(&tr("Downloading {items}…").replace("{items}", &text::items(count as u64)));
            let shown = window.clone();
            let place = folder.clone();
            crate::tasks::run(
                async move {
                    let mut done = 0;
                    let mut failed = Vec::new();
                    for id in ids {
                        let outcome = async {
                            let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                            // Downloaded beside its place under a name of its own, then given the first free name:
                            // a failed download leaves nothing, and two downloads never write one file.
                            let partial = verso_desktop::images::partial_path(&folder.join(&id));
                            if let Err(error) = client.download_original(&id, &partial).await {
                                let _ = tokio::fs::remove_file(&partial).await;
                                return Err(error.to_string());
                            }
                            for _ in 0..100 {
                                let target = free_name(&folder, &details.original_file_name);
                                match verso_desktop::images::place(&partial, &target) {
                                    Ok(true) => return Ok(()),
                                    Ok(false) => continue,
                                    Err(error) => {
                                        let _ = std::fs::remove_file(&partial);
                                        return Err(error.to_string());
                                    }
                                }
                            }
                            let _ = std::fs::remove_file(&partial);
                            Err(tr("no free name for it in the folder").to_owned())
                        }
                        .await;
                        match outcome {
                            Ok(_) => done += 1,
                            Err(message) => failed.push(message),
                        }
                    }
                    (done, failed)
                },
                move |(done, failed)| {
                    let mut message = tr("Downloaded {items} to {folder}").replace("{items}", &text::items(done)).replace("{folder}", &place.display().to_string());
                    if let Some(first) = failed.first() {
                        message.push_str(&format!(". {}", tr("{count} failed: {error}").replace("{count}", &failed.len().to_string()).replace("{error}", first)));
                    }
                    shown.toast(&message);
                },
            );
        });
    }

    /// The item's crosslink, which the drive reads to find its file.
    fn crosslink(&self, id: &str, within: Option<ImmichItem>) -> Option<String> {
        let session = self.session()?;
        Some(links::crosslink(&session.connection.server, session.connection.user_id(), &links::asset(id, within)))
    }

    /// What finding a photo's file takes: the account, and where the photo was seen.
    pub fn resolver(&self, within: Option<ImmichItem>) -> Option<crate::drag::Resolver> {
        let session = self.session()?;
        let connection = &session.connection;
        Some(crate::drag::Resolver {
            client: connection.client.clone(),
            server: connection.server.clone(),
            user_id: connection.user_id().map(str::to_owned),
            cache: connection.cache_directory(),
            within,
        })
    }

    /// Open the original in another program: from the drive when it is mounted (read as the program reads it, with
    /// nothing downloaded first), else downloaded to the cache.
    pub fn open_with(&self, id: &str, within: Option<ImmichItem>) {
        let Some(resolver) = self.resolver(within) else { return };
        let id = id.to_owned();
        let window = self.clone();
        crate::tasks::run(async move { resolver.file(&id).await }, move |outcome| match outcome {
            Ok(path) => {
                let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
                launcher.set_always_ask(true);
                let shown = window.clone();
                launcher.launch(Some(&window), gio::Cancellable::NONE, move |outcome| {
                    if let Err(error) = outcome {
                        if !error.matches(gtk::DialogError::Dismissed) && !error.matches(gtk::DialogError::Cancelled) {
                            shown.toast(&tr("No app could be offered to open it: {error}").replace("{error}", error.message()));
                        }
                    }
                });
            }
            Err(message) => window.toast(&message),
        });
    }

    /// Show the photo in another participant of Immich Crosslink, by its desktop entry (`crosslink::send`): Verso
    /// Drive's shows it in Files.
    pub fn show_in(&self, app: &str, id: &str, within: Option<ImmichItem>) {
        if let Some(link) = self.crosslink(id, within) {
            crate::crosslink::send(self, app, &link);
        }
    }

    pub fn open_in_immich(&self, id: &str, within: Option<ImmichItem>) {
        let Some(session) = self.session() else { return };
        let address = links::web_address(&session.connection.server, &links::asset(id, within));
        gtk::UriLauncher::new(&address).launch(Some(self), gio::Cancellable::NONE, |_| {});
    }

    /// Open an album, a person or a place in Immich's web app.
    pub fn open_item_in_immich(&self, item: ImmichItem) {
        let Some(session) = self.session() else { return };
        gtk::UriLauncher::new(&links::web_address(&session.connection.server, &item)).launch(Some(self), gio::Cancellable::NONE, |_| {});
    }

    pub fn copy_item_link(&self, item: ImmichItem) {
        let Some(session) = self.session() else { return };
        self.clipboard().set_text(&links::web_address(&session.connection.server, &item));
        self.toast(tr("Link copied"));
    }

    pub fn copy_link(&self, id: &str, within: Option<ImmichItem>) {
        let Some(session) = self.session() else { return };
        let address = links::web_address(&session.connection.server, &links::asset(id, within));
        self.clipboard().set_text(&address);
        self.toast(tr("Link copied"));
    }

    // --- Imports ---

    /// Import… and Import Folders…: GTK's file chooser picks files or folders, never both at once. On the page of an
    /// album the account may add to, what is chosen joins the album too, as the chooser's title says.
    fn choose_imports(&self, folders: bool) {
        if self.session().is_none() {
            return;
        }
        let album = self.current_album().filter(|id| self.may_add_to(id));
        let name = album.as_ref().and_then(|id| self.imp().albums.borrow().iter().find(|known| known.id == *id).map(|known| known.name.clone()));
        let title = match name {
            Some(name) => tr("Import into “{album}”").replace("{album}", &name),
            None => tr("Import Photos and Videos").to_owned(),
        };
        let dialog = gtk::FileDialog::builder().title(title).accept_label(tr("Import")).build();
        let window = self.clone();
        let chosen = move |chosen: Result<gio::ListModel, glib::Error>| {
            let Ok(files) = chosen else { return };
            let paths: Vec<PathBuf> = (0..files.n_items()).filter_map(|index| files.item(index).and_downcast::<gio::File>()).filter_map(|file| file.path()).collect();
            window.import(paths, album.clone());
        };
        if folders {
            dialog.select_multiple_folders(Some(self), gio::Cancellable::NONE, chosen);
        } else {
            dialog.open_multiple(Some(self), gio::Cancellable::NONE, chosen);
        }
    }

    /// Import files and folders, then add them to `album` when one is given: the import panel's queue.
    pub fn import(&self, paths: Vec<PathBuf>, album: Option<String>) {
        let imports = self.imp().imports.borrow().clone();
        if let Some(imports) = imports {
            imports.enqueue(paths, album);
        }
    }

    // --- Links from other apps, and the sign-in redirect ---

    /// An address handed to the app: the browser's sign-in redirect, or a link to show (immich-crosslink, or a
    /// web address on the signed-in server).
    pub fn handle_address(&self, address: &str) {
        if address.starts_with("app.immich:") {
            return self.handle_redirect(address);
        }
        let Some(session) = self.session() else {
            self.imp().pending.borrow_mut().push(address.to_owned());
            return;
        };
        let item = verso_core::links::receive(address, &session.connection.server, session.connection.user_id());
        match item {
            Ok(item) => self.show_item(item),
            Err(refusal) => self.toast(&match refusal {
                verso_core::links::Refusal::OtherServer(host) => tr("A link from another app is for {server}, and Verso is signed in to another server.").replace("{server}", &host),
                verso_core::links::Refusal::OtherUser => tr("A link from another app is for another account on this server.").to_owned(),
                verso_core::links::Refusal::CannotShow => tr("A link from another app names something Verso cannot show.").to_owned(),
                verso_core::links::Refusal::Invalid => tr("A link from another app could not be read.").to_owned(),
            }),
        }
    }

    fn show_item(&self, item: ImmichItem) {
        // What a link names shows in front: a photo open in the viewer would hide it.
        self.close_viewer();
        match item {
            ImmichItem::Album(id) => {
                let name = self.imp().albums.borrow().iter().find(|album| album.id == id).map(|album| album.name.clone()).unwrap_or_default();
                self.select_section("albums");
                self.open_album(&id, &name);
            }
            ImmichItem::Person(id) => {
                self.select_section("people");
                self.open_person(&id, "");
            }
            ImmichItem::Country(country) => {
                self.select_section("places");
                self.push_page(&crate::explore::place_page(self, None, Some(country)));
            }
            ImmichItem::City { country, city } => {
                self.select_section("places");
                self.push_page(&crate::explore::place_page(self, Some(city), country));
            }
            ImmichItem::Section(section) => {
                use verso_core::tree::SectionKey;
                let id = match section {
                    SectionKey::Albums => "albums",
                    SectionKey::People => "people",
                    SectionKey::Places => "places",
                    SectionKey::Favorites => "favorites",
                    SectionKey::Archive => "archive",
                    _ => "library",
                };
                self.select_section(id);
            }
            ImmichItem::Asset { within, asset_id } => {
                let within = within.map(|item| *item);
                if let Some(ImmichItem::Album(album)) = &within {
                    let name = self.imp().albums.borrow().iter().find(|candidate| candidate.id == *album).map(|album| album.name.clone()).unwrap_or_default();
                    self.select_section("albums");
                    self.open_album(album, &name);
                }
                let kind = match within {
                    Some(ImmichItem::Album(id)) => Kind::Album { id },
                    Some(ImmichItem::Person(id)) => Kind::Person { id },
                    _ => Kind::Plain,
                };
                let Some(session) = self.session() else { return };
                let client = session.connection.client.clone();
                let window = self.clone();
                crate::tasks::run(async move { client.asset_details(&asset_id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(details) => window.open_viewer(vec![Tile::from(&details)], 0, kind),
                    Err(message) => window.toast(&message),
                });
            }
        }
    }

    pub fn show_preferences(&self, page: Option<&str>) {
        crate::preferences::show(self, page);
    }

    pub fn preferences_window(&self) -> Option<adw::Window> {
        self.imp().preferences.upgrade()
    }

    pub fn set_preferences_window(&self, preferences: &adw::Window) {
        self.imp().preferences.set(Some(preferences));
    }
}

/// A sidebar heading, which cannot be selected.
/// An album section's heading, with its menu: how many albums it lists, and in which order.
fn album_heading_row(title: &str, section: albums::Section) -> gtk::ListBoxRow {
    let name = if section == albums::Section::Mine { "my-albums" } else { "shared-albums" };
    let show = gio::Menu::new();
    for limit in albums::SHOW_COUNTS {
        let (label, target) = match limit {
            None => (tr("All Albums").to_owned(), "all".to_owned()),
            Some(count) => (tr("{count} Albums").replace("{count}", &count.to_string()), count.to_string()),
        };
        show.append(Some(&label), Some(&format!("win.{name}-show::{target}")));
    }
    let sort = gio::Menu::new();
    for (key, label) in sort_labels() {
        sort.append(Some(label), Some(&format!("win.{name}-sort::{}", key.code())));
    }
    let menu = gio::Menu::new();
    menu.append_section(Some(tr("Show")), &show);
    menu.append_section(Some(tr("Sort By")), &sort);
    let button = gtk::MenuButton::builder().icon_name("view-more-horizontal-symbolic").menu_model(&menu).css_classes(["flat", "gallery-sidebar-menu"]).tooltip_text(tr("Show and Sort")).valign(gtk::Align::Center).build();
    let label = gtk::Label::builder().label(title).xalign(0.0).hexpand(true).css_classes(["dim-label", "gallery-sidebar-heading"]).build();
    let content = gtk::Box::builder().build();
    content.append(&label);
    content.append(&button);
    gtk::ListBoxRow::builder().child(&content).selectable(false).activatable(false).focusable(false).build()
}

/// The albums' sort keys with their labels, as Immich names them.
pub fn sort_labels() -> [(albums::SortBy, &'static str); 6] {
    [
        (albums::SortBy::Title, tr("Title")),
        (albums::SortBy::ItemCount, tr("Item Count")),
        (albums::SortBy::DateModified, tr("Date Modified")),
        (albums::SortBy::DateCreated, tr("Date Created")),
        (albums::SortBy::MostRecentPhoto, tr("Most Recent Photo")),
        (albums::SortBy::OldestPhoto, tr("Oldest Photo")),
    ]
}

fn heading_row(title: &str) -> gtk::ListBoxRow {
    let label = gtk::Label::builder().label(title).xalign(0.0).css_classes(["dim-label", "gallery-sidebar-heading"]).build();
    gtk::ListBoxRow::builder().child(&label).selectable(false).activatable(false).focusable(false).build()
}

/// A row of Edit Sidebar: a page (with its icon) or a section, a switch that shows or hides it (none for a page that
/// always shows), and its menu of moves.
fn editing_row(id: &str, title: &str, icon: Option<&str>, shown: Option<bool>, menu: Option<&gio::Menu>) -> gtk::ListBoxRow {
    let content = gtk::Box::builder().spacing(12).build();
    if let Some(icon) = icon {
        content.append(&gtk::Image::from_icon_name(icon));
    }
    let label = gtk::Label::builder().label(title).xalign(0.0).hexpand(true).ellipsize(gtk::pango::EllipsizeMode::End).build();
    if icon.is_none() {
        label.add_css_class("heading");
        label.set_margin_top(9);
    }
    content.append(&label);
    if let Some(shown) = shown {
        let switch = gtk::Switch::builder().active(shown).valign(gtk::Align::Center).tooltip_text(tr("Show in Sidebar")).build();
        let id = id.to_owned();
        switch.connect_active_notify(move |switch| {
            verso_desktop::sidebar::set_hidden(verso_desktop::settings::shared(), &id, !switch.is_active());
        });
        content.append(&switch);
    }
    if let Some(menu) = menu {
        content.append(&gtk::MenuButton::builder().icon_name("view-more-symbolic").menu_model(menu).css_classes(["flat"]).tooltip_text(tr("Move")).valign(gtk::Align::Center).build());
    }
    let row = gtk::ListBoxRow::builder().child(&content).selectable(false).activatable(false).build();
    row.add_css_class(if icon.is_some() { "verso-sidebar-page" } else { "verso-sidebar-section" });
    row
}

/// What a dragged sidebar page carries: this, then its id.
const SIDEBAR_DRAG: &str = "verso-sidebar-page:";

/// The built-in sections, each with its pages, as they first are, and the albums' two sections (which take no pages).
fn sidebar_defaults() -> Vec<(&'static str, Vec<&'static str>)> {
    let mut defaults: Vec<(&'static str, Vec<&'static str>)> = SIDEBAR.iter().map(|(heading, entries)| (*heading, entries.iter().map(|(id, _, _)| *id).collect())).collect();
    defaults.push(("my-albums", Vec::new()));
    defaults.push(("shared-albums", Vec::new()));
    defaults
}

/// The sidebar as Edit Sidebar left it.
fn sidebar_layout() -> verso_desktop::sidebar::Layout {
    let defaults = sidebar_defaults();
    let defaults: Vec<(&str, &[&str])> = defaults.iter().map(|(section, pages)| (*section, pages.as_slice())).collect();
    verso_desktop::sidebar::Layout::load(verso_desktop::settings::shared(), &defaults)
}

/// A page's title and icon, by its id.
fn page_entry(id: &str) -> Option<&'static Entry> {
    SIDEBAR.iter().flat_map(|(_, entries)| entries.iter()).find(|(known, _, _)| *known == id)
}

/// A section's heading: the user's own name, or the built-in one's, in the user's language.
fn section_title(section: &verso_desktop::sidebar::Section) -> String {
    match (section.name.as_deref(), section.id.as_str()) {
        (Some(name), _) => name.to_owned(),
        (None, "my-albums") => tr("My Albums").to_owned(),
        (None, "shared-albums") => tr("Shared Albums").to_owned(),
        (None, id) => tr(id).to_owned(),
    }
}

/// The albums' sections: which albums each lists.
fn album_section_of(id: &str) -> Option<(albums::Section, albums::Filter)> {
    match id {
        "my-albums" => Some((albums::Section::Mine, albums::Filter::Owned)),
        "shared-albums" => Some((albums::Section::Shared, albums::Filter::Shared)),
        _ => None,
    }
}

/// A sidebar page: its icon and title, its id as the row's name.
fn entry_row(id: &str, title: &str, icon: &str) -> gtk::ListBoxRow {
    let content = gtk::Box::builder().spacing(12).build();
    content.append(&gtk::Image::from_icon_name(icon));
    content.append(&gtk::Label::builder().label(title).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build());
    gtk::ListBoxRow::builder().child(&content).name(id).build()
}

/// Whether `user` may add photos to `album`: its owner (or an album whose owner was not listed), or an editor.
fn adds_to(album: &Album, user: Option<&str>) -> bool {
    album.owner().is_none_or(|owner| Some(owner.id.as_str()) == user) || album.members.iter().any(|member| Some(member.user.id.as_str()) == user && member.role == immich_api::AlbumRole::Editor)
}

/// Takes files dropped from other apps (Files, the desktop): `take` gets the target and their paths, and says whether
/// it took them. A drag that starts in the gallery (photos dragged out) is never an import when let go over it again.
fn import_drop_target(take: impl Fn(&gtk::DropTarget, Vec<PathBuf>) -> bool + 'static) -> gtk::DropTarget {
    let target = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    target.connect_accept(|target, drop| drop.drag().is_none() && target.formats().is_some_and(|formats| formats.match_(&drop.formats())));
    target.connect_drop(move |target, value, _, _| {
        let Ok(files) = value.get::<gdk::FileList>() else { return false };
        let paths: Vec<PathBuf> = files.files().iter().filter_map(|file| file.path()).collect();
        !paths.is_empty() && take(target, paths)
    });
    target
}

/// A name for a downloaded file that takes nothing already in the folder: "IMG_1.jpg", then "IMG_1 (2).jpg".
fn free_name(folder: &std::path::Path, name: &str) -> PathBuf {
    let name = std::path::Path::new(name).file_name().map(|name| name.to_string_lossy().into_owned()).filter(|name| !name.is_empty()).unwrap_or_else(|| "photo".to_owned());
    let first = folder.join(&name);
    if !first.exists() {
        return first;
    }
    let (stem, extension) = match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => (stem.to_owned(), format!(".{extension}")),
        _ => (name.clone(), String::new()),
    };
    (2..).map(|number| folder.join(format!("{stem} ({number}){extension}"))).find(|path| !path.exists()).unwrap_or(first)
}

/// A server address's host, with its port: `photos.example.org` for `https://photos.example.org/`.
fn host_of(server: &str) -> String {
    server.trim_start_matches("https://").trim_start_matches("http://").split('/').next().unwrap_or_default().to_owned()
}

/// Make the gallery the handler of `app.immich`, so the browser's redirect comes back to it.
fn claim_redirect() {
    // A Flatpak's exported entry carries the scheme; its sandbox cannot choose the host's default.
    if verso_core::product::current().sandboxed {
        return;
    }
    let desktop_id = format!("{}.desktop", crate::APP_ID);
    if let Some(info) = gio::AppInfo::all().into_iter().find(|info| info.id().as_deref() == Some(desktop_id.as_str())) {
        if let Err(error) = info.set_as_default_for_type("x-scheme-handler/app.immich") {
            eprintln!("could not make {desktop_id} the app.immich handler: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::free_name;

    #[test]
    fn downloads_never_overwrite() {
        let folder = std::env::temp_dir().join(format!("verso-free-name-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        assert_eq!(free_name(&folder, "IMG_1.jpg"), folder.join("IMG_1.jpg"));
        std::fs::write(folder.join("IMG_1.jpg"), b"x").unwrap();
        assert_eq!(free_name(&folder, "IMG_1.jpg"), folder.join("IMG_1 (2).jpg"));
        assert_eq!(free_name(&folder, "../../escape.jpg"), folder.join("escape.jpg"), "a name never leaves the folder");
        std::fs::remove_dir_all(&folder).unwrap();
    }
}
