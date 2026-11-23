//! Albums and people, as pages of covers and faces that open their photos; and the Locked Folder, which opens with
//! the account's PIN code.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk::{gio, glib};
use immich_api::account::Proof;
use immich_api::TimelineScope;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Source;
use verso_core::grid_options::GridPage;
use verso_desktop::links;
use verso_core::links::ImmichItem;
use verso_linux::i18n::tr;

use crate::pages::{self, Kind, Spec};
use crate::textures::Textures;
use crate::window::Window;

/// A cover or a face with its name under it, for a flow box of them.
pub fn card(textures: &Rc<Textures>, kind: ImageKind, image_id: Option<&str>, title: &str, subtitle: &str, size: i32) -> gtk::Box {
    let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Cover).can_shrink(true).build();
    let frame = SquareFrame::new(size, &picture);
    frame.add_css_class("gallery-card-picture");
    let title_label = gtk::Label::builder().label(title).xalign(if kind == ImageKind::Person { 0.5 } else { 0.0 }).ellipsize(gtk::pango::EllipsizeMode::End).max_width_chars(18).css_classes(["title"]).build();
    let subtitle_label = gtk::Label::builder().label(subtitle).ellipsize(gtk::pango::EllipsizeMode::End).max_width_chars(18).xalign(if kind == ImageKind::Person { 0.5 } else { 0.0 }).css_classes(["dim-label", "caption"]).visible(!subtitle.is_empty()).build();
    let card = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).halign(gtk::Align::Center).css_classes(["gallery-card"]).build();
    if kind == ImageKind::Person {
        card.add_css_class("person");
    }
    card.append(&frame);
    card.append(&title_label);
    card.append(&subtitle_label);
    if let Some(id) = image_id.filter(|id| !id.is_empty()) {
        match textures.cached(kind, id, None) {
            Some(texture) => picture.set_paintable(Some(&texture)),
            None => {
                let weak = picture.downgrade();
                textures.get(kind, id, None, move |texture| {
                    if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                        picture.set_paintable(Some(&texture));
                    }
                });
            }
        }
    }
    card
}

mod frame_imp {
    use std::cell::Cell;

    use gtk::subclass::prelude::*;
    use gtk::{glib, prelude::*};

    #[derive(Default)]
    pub struct SquareFrame {
        pub size: Cell<i32>,
        /// At least this wide, as wide as it is given, and as tall as it is wide; `size` square when not set.
        pub least: Cell<Option<i32>>,
        /// A height other than `size`: a fixed rectangle rather than a square.
        pub height: Cell<Option<i32>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SquareFrame {
        const NAME: &'static str = "ImmichGallerySquareFrame";
        type Type = super::SquareFrame;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for SquareFrame {
        fn dispose(&self) {
            while let Some(child) = self.obj().first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for SquareFrame {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            if self.least.get().is_some() && self.height.get().is_none() { gtk::SizeRequestMode::HeightForWidth } else { gtk::SizeRequestMode::ConstantSize }
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            match (self.least.get(), orientation) {
                // Natural at the least, so a flow box fits as many as it can on a line, then widens them.
                (Some(least), gtk::Orientation::Horizontal) => (least, least, -1, -1),
                // A band: as wide as it is given, and a height of its own.
                (Some(_), _) if self.height.get().is_some() => {
                    let height = self.height.get().unwrap_or_default();
                    (height, height, -1, -1)
                }
                (Some(least), _) => {
                    let side = if for_size > 0 { for_size } else { least };
                    (side, side, -1, -1)
                }
                (None, gtk::Orientation::Vertical) if self.height.get().is_some() => {
                    let height = self.height.get().unwrap_or_default();
                    (height, height, -1, -1)
                }
                (None, _) => {
                    let size = self.size.get();
                    (size, size, -1, -1)
                }
            }
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            if let Some(child) = self.obj().first_child() {
                child.size_allocate(&gtk::Allocation::new(0, 0, width, height), baseline);
            }
        }
    }
}

glib::wrapper! {
    /// A square of one size whatever its picture's shape, so cards line up in a grid.
    pub struct SquareFrame(ObjectSubclass<frame_imp::SquareFrame>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl SquareFrame {
    pub fn new(size: i32, child: &impl IsA<gtk::Widget>) -> SquareFrame {
        let frame: SquareFrame = glib::Object::builder().property("overflow", gtk::Overflow::Hidden).property("halign", gtk::Align::Center).build();
        frame.imp().size.set(size);
        child.set_parent(&frame);
        frame
    }

    /// A fixed rectangle, whatever its picture's shape.
    pub fn sized(width: i32, height: i32, child: &impl IsA<gtk::Widget>) -> SquareFrame {
        let frame = SquareFrame::new(width, child);
        frame.imp().height.set(Some(height));
        frame
    }

    /// Change the least width, and the height of a band (`None` for a square as wide as it is given): the cards'
    /// size, as the zoom changes it.
    pub fn resize(&self, least: i32, height: Option<i32>) {
        self.imp().least.set(Some(least));
        self.imp().height.set(height);
        self.queue_resize();
    }

    /// As wide as it is given, at least `least`, and `height` tall, whatever its picture's shape.
    pub fn band(least: i32, height: i32, child: &impl IsA<gtk::Widget>) -> SquareFrame {
        let frame = SquareFrame::adaptive(least, child);
        frame.imp().height.set(Some(height));
        frame
    }

    /// A square as wide as it is given, at least `least`.
    pub fn adaptive(least: i32, child: &impl IsA<gtk::Widget>) -> SquareFrame {
        let frame = SquareFrame::new(least, child);
        frame.set_halign(gtk::Align::Fill);
        frame.imp().least.set(Some(least));
        frame
    }
}

/// A flow box of cards in a scrolled page, with a search bar that filters them by name.
pub struct CardPage {
    pub page: adw::NavigationPage,
    pub flow: gtk::FlowBox,
    pub header: adw::HeaderBar,
    pub stack: gtk::Stack,
    pub empty: adw::StatusPage,
}

pub fn card_page(title: &str, empty_title: &str, empty_icon: &str) -> CardPage {
    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .activate_on_single_click(true)
        .homogeneous(true)
        .row_spacing(18)
        .column_spacing(18)
        .max_children_per_line(12)
        .valign(gtk::Align::Start)
        .margin_top(18)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    let search = gtk::SearchEntry::builder().placeholder_text(tr("Search")).build();
    let search_bar = gtk::SearchBar::builder().child(&search).build();
    search_bar.connect_entry(&search);
    let query = search.clone();
    flow.set_filter_func(move |child| {
        let wanted = query.text().to_lowercase();
        wanted.is_empty() || child.widget_name().to_lowercase().contains(&wanted)
    });
    let filtered = flow.clone();
    search.connect_search_changed(move |_| filtered.invalidate_filter());
    let header = adw::HeaderBar::new();
    let search_button = gtk::ToggleButton::builder().icon_name("system-search-symbolic").tooltip_text(tr("Search")).build();
    search_button.bind_property("active", &search_bar, "search-mode-enabled").bidirectional().build();
    header.pack_end(&search_button);
    let scrolled = gtk::ScrolledWindow::builder().child(&flow).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
    let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).build();
    let empty = adw::StatusPage::builder().title(empty_title).icon_name(empty_icon).build();
    let stack = gtk::Stack::new();
    stack.add_named(&spinner, Some("loading"));
    stack.add_named(&scrolled, Some("cards"));
    stack.add_named(&empty, Some("empty"));
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    content.append(&search_bar);
    content.append(&stack);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&content));
    let page = adw::NavigationPage::builder().title(title).child(&toolbar).build();
    // Typing starts a search, as in Files.
    search_bar.set_key_capture_widget(Some(&page));
    CardPage { page, flow, header, stack, empty }
}

/// Add a card that runs `open` when activated; its name is what the search matches.
pub fn add_card(flow: &gtk::FlowBox, card: &gtk::Box, name: &str, open: impl Fn() + 'static) {
    let child = gtk::FlowBoxChild::builder().child(card).name(name).build();
    flow.append(&child);
    let open = Rc::new(open);
    flow.connect_child_activated(glib::clone!(
        #[weak]
        child,
        move |_, activated| {
            if activated == &child {
                open();
            }
        }
    ));
}

// --- Albums ---



/// Open in Immich, Copy Immich Link and Show in *app* for an album, a person or a place, as `page` actions; the menu
/// items come from `crosslink::append`.
pub fn item_actions(window: &Window, item: ImmichItem) -> Vec<gio::SimpleAction> {
    let open = gio::SimpleAction::new("open-in-immich", None);
    let (weak_window, shown) = (window.downgrade(), item.clone());
    open.connect_activate(move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        gtk::UriLauncher::new(&links::web_address(&session.connection.server, &shown)).launch(Some(&window), gio::Cancellable::NONE, |_| {});
    });
    let copy = gio::SimpleAction::new("copy-link", None);
    let (weak_window, shown) = (window.downgrade(), item.clone());
    copy.connect_activate(move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        window.clipboard().set_text(&links::web_address(&session.connection.server, &shown));
        window.toast(tr("Link copied"));
    });
    let show_in = gio::SimpleAction::new("show-in", Some(glib::VariantTy::STRING));
    let weak_window = window.downgrade();
    show_in.connect_activate(move |_, target| {
        let (Some(window), Some(app)) = (weak_window.upgrade(), target.and_then(|target| target.get::<String>())) else { return };
        let Some(session) = window.session() else { return };
        let link = links::crosslink(&session.connection.server, session.connection.user_id(), &item);
        crate::crosslink::send(&window, &app, &link);
    });
    vec![open, copy, show_in]
}

// --- People ---



/// Merge this person into another: their faces become the other's, and this person goes.
pub fn merge_person(window: &Window, id: String, name: String) {
    let Some(session) = window.session() else { return };
    let client = session.connection.client.clone();
    let shown = window.clone();
    crate::tasks::run(async move { client.people().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let people = match outcome {
            Ok(people) => people,
            Err(message) => return shown.toast(&message),
        };
        let choices: Vec<(String, String)> = people.into_iter().filter(|person| person.id != id && !person.name.is_empty()).map(|person| (person.id, person.name)).collect();
        let (weak_window, merged) = (shown.downgrade(), id.clone());
        crate::dialogs::choose_item(&shown, tr("Merge With"), tr("Search people"), choices, move |target, target_name| {
            let Some(window) = weak_window.upgrade() else { return };
            let body = tr("“{from}” becomes part of “{into}”: their faces and photos join, and “{from}” goes.").replace("{from}", &name).replace("{into}", &target_name);
            let (weak_window, merged) = (window.downgrade(), merged.clone());
            crate::dialogs::confirm(&window, tr("Merge the People?"), &body, tr("Merge"), true, move || {
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, into, target, target_name, merged, shown) = (session.connection.client.clone(), target.clone(), target.clone(), target_name.clone(), merged.clone(), window.clone());
                crate::tasks::run(async move { client.merge_people(&into, &[merged]).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                    Ok(_) => {
                        shown.toast(tr("Merged"));
                        shown.select_section("people");
                        shown.open_person(&target, &target_name);
                    }
                    Err(message) => shown.toast(&message),
                });
            });
        });
    });
}

// --- The Locked Folder ---

/// The Locked Folder: opened with the PIN code, which elevates the session for a while; Lock closes it again.
pub fn locked_page(window: &Window) -> adw::NavigationPage {
    let status = adw::StatusPage::builder().icon_name("system-lock-screen-symbolic").title(tr("Locked Folder")).build();
    let unlock = gtk::Button::builder().label(tr("_Unlock…")).use_underline(true).halign(gtk::Align::Center).css_classes(["pill", "suggested-action"]).visible(false).build();
    status.set_child(Some(&unlock));
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&status));
    let page = adw::NavigationPage::builder().title(tr("Locked Folder")).child(&toolbar).build();
    let Some(session) = window.session() else { return page };
    if session.connection.with_api_key {
        status.set_description(Some(tr("The Locked Folder opens only with a sign-in by password or single sign-on.")));
        return page;
    }
    let client = session.connection.client.clone();
    let (weak_window, weak_status, weak_unlock) = (window.downgrade(), status.downgrade(), unlock.downgrade());
    crate::tasks::run(async move { client.auth_status().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let (Some(window), Some(status), Some(unlock)) = (weak_window.upgrade(), weak_status.upgrade(), weak_unlock.upgrade()) else { return };
        match outcome {
            Ok(auth) if !auth.pin_code => {
                status.set_description(Some(tr("Its photos and videos stay out of the library, albums and searches. Set a PIN code to use it.")));
                unlock.set_label(tr("_Set Up…"));
                unlock.set_widget_name("set-up");
                unlock.set_visible(true);
            }
            Ok(auth) if auth.is_elevated => {
                if window.shown_section() == "locked" {
                    show_locked_photos(&window);
                }
            }
            Ok(_) => {
                status.set_description(Some(tr("Its photos and videos stay out of the library, albums and searches. Unlock it with your PIN code.")));
                unlock.set_visible(true);
            }
            Err(message) => status.set_description(Some(&message)),
        }
    });
    let weak_window = window.downgrade();
    unlock.connect_clicked(move |button| {
        let Some(window) = weak_window.upgrade() else { return };
        if button.widget_name() == "set-up" {
            let weak_window = window.downgrade();
            crate::dialogs::ask_new_pin(&window, move |pin| {
                let Some(window) = weak_window.upgrade() else { return };
                let Some(session) = window.session() else { return };
                let (client, shown) = (session.connection.client.clone(), window.clone());
                crate::tasks::run(
                    async move {
                        client.set_pin_code(&pin).await.map_err(|error| verso_desktop::errors::said(&error))?;
                        client.unlock_session(&Proof::PinCode(pin)).await.map_err(|error| verso_desktop::errors::said(&error))
                    },
                    move |outcome| match outcome {
                        Ok(()) => {
                            if shown.shown_section() == "locked" {
                                show_locked_photos(&shown);
                            }
                        }
                        Err(message) => shown.toast(&message),
                    },
                );
            });
            return;
        }
        let weak_window = window.downgrade();
        crate::dialogs::ask_pin(&window, move |pin| {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let client = session.connection.client.clone();
            let shown = window.clone();
            crate::tasks::run(async move { client.unlock_session(&Proof::PinCode(pin)).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => {
                    // Only where the Locked Folder is still the page shown: another section may have been chosen.
                    if shown.shown_section() == "locked" {
                        show_locked_photos(&shown);
                    }
                }
                Err(_) => shown.toast(tr("That PIN code did not unlock the Locked Folder")),
            });
        });
    });
    page
}

/// Lock the folder again: the session needs the PIN once more, and the folder's photos leave this computer, from
/// memory and from the disk (pictures, videos and originals).
fn lock_folder(window: &Window, ids: Vec<String>, then: impl FnOnce(Result<(), String>) + 'static) {
    let Some(session) = window.session() else { return };
    for id in &ids {
        session.textures.forget(id);
    }
    let cache = session.textures.cache().clone();
    crate::tasks::runtime().spawn_blocking(move || cache.forget(&ids));
    let client = session.connection.client.clone();
    crate::tasks::run(async move { client.lock_session().await.map_err(|error| verso_desktop::errors::said(&error)) }, then);
}

/// The Locked Folder's photos, with Lock in the menu. Leaving the page locks it too.
fn show_locked_photos(window: &Window) {
    let mut spec = Spec::new(tr("Locked Folder"), Source::Timeline(TimelineScope::Locked), Kind::Locked).arranged(GridPage::Locked).empty(tr("The Locked Folder Is Empty"), "system-lock-screen-symbolic");
    let menu = gio::Menu::new();
    menu.append(Some(tr("Lock")), Some("page.lock"));
    spec.menu = Some(menu);
    let lock = gio::SimpleAction::new("lock", None);
    let weak_window = window.downgrade();
    let shown_grid: Rc<RefCell<Option<crate::grid::WeakGrid>>> = Rc::default();
    let locked = Rc::new(Cell::new(false));
    let shown_ids = {
        let shown_grid = shown_grid.clone();
        move || shown_grid.borrow().as_ref().and_then(crate::grid::WeakGrid::upgrade).map(|grid| grid.tiles().into_iter().map(|tile| tile.id).collect()).unwrap_or_default()
    };
    let (ids_for_lock, locked_by_hand) = (shown_ids.clone(), locked.clone());
    lock.connect_activate(move |_, _| {
        let Some(window) = weak_window.upgrade() else { return };
        locked_by_hand.set(true);
        let shown = window.clone();
        lock_folder(&window, ids_for_lock(), move |outcome| {
            if let Err(message) = outcome {
                shown.toast(&message);
            }
            shown.select_section("library");
        });
    });
    spec.actions.push(lock);
    let (page, grid) = pages::grid_page(window, spec);
    shown_grid.replace(grid.as_ref().map(crate::grid::Grid::downgrade));
    // Another section chosen, the folder locks as it does with Lock; the viewer, over the whole window, leaves it open.
    let weak_window = window.downgrade();
    page.connect_hidden(move |page| {
        let (weak_window, weak_page, locked, shown_ids) = (weak_window.clone(), page.downgrade(), locked.clone(), shown_ids.clone());
        glib::idle_add_local_once(move || {
            let Some(window) = weak_window.upgrade() else { return };
            if locked.get() || weak_page.upgrade().is_some_and(|page| window.holds_page(&page)) {
                return;
            }
            locked.set(true);
            let shown = window.clone();
            lock_folder(&window, shown_ids(), move |outcome| {
                if let Err(message) = outcome {
                    shown.toast(&message);
                }
            });
        });
    });
    window.replace_section_page(&page);
}
