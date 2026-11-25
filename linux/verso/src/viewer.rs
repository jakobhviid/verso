//! The viewer: one photo or video at a time on the window's colour, in place of the page it opened from, its photo
//! zooming out of its grid square and back (`motion`). The thumbnail shows at once and
//! the 1440 pixel preview replaces it; videos play the server's playback file. Zoom with Ctrl+scroll, a pinch, the
//! keys or a double click, and drag to pan. The info pane beside it shows the photo's details and edits its
//! description and rating.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::asset_info::AssetDetails;
use verso_desktop::actions;
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::library::Tile;
use verso_desktop::{presentation, settings, text};
use verso_linux::i18n::tr;

use crate::grid::Grid;
use crate::pages::Kind;
use crate::window::Window;

const MAX_ZOOM: f64 = 8.0;

/// Where the photo flies from as the viewer opens: its square's picture and place in the window's content, and a still
/// of the page it leaves, to fade (`motion`).
pub struct Opening {
    pub thumbnail: gdk::Paintable,
    pub from: gtk::graphene::Rect,
    pub backdrop: Option<gdk::Paintable>,
}

/// What the viewer lets go of as it starts hiding, for the window to fly back into its square if the grid shows next:
/// the photo and where it was (none when zoomed in, or a video), and a still of the viewer without it.
pub struct Closing {
    pub id: String,
    pub lifted: Option<(gdk::Paintable, gtk::graphene::Rect)>,
    pub backdrop: Option<gdk::Paintable>,
}

pub(crate) struct State {
    pub(crate) window: glib::WeakRef<Window>,
    pub(crate) grid: Option<Grid>,
    pub(crate) kind: Kind,
    pub(crate) tiles: RefCell<Vec<Tile>>,
    pub(crate) index: Cell<usize>,
    /// The texture shown, for its pixel size when zooming.
    pub(crate) texture: RefCell<Option<gdk::Texture>>,
    /// 0 fits the photo to the stage; otherwise screen pixels per photo pixel.
    pub(crate) zoom: Cell<f64>,
    pub(crate) zoom_at_gesture_start: Cell<f64>,
    pub(crate) picture: gtk::Picture,
    pub(crate) scrolled: gtk::ScrolledWindow,
    pub(crate) video: gtk::Video,
    pub(crate) stack: gtk::Stack,
    pub(crate) spinner: adw::Spinner,
    pub(crate) title: adw::WindowTitle,
    pub(crate) favorite: gtk::ToggleButton,
    /// The page scrolls from the photo down to its details, as the Mac gallery's inspector shows them.
    pub(crate) page_scroller: gtk::ScrolledWindow,
    pub(crate) details_box: gtk::Box,
    pub(crate) details_clamp: adw::Clamp,
    pub(crate) details: RefCell<Option<AssetDetails>>,
    pub(crate) previous: gtk::Button,
    pub(crate) next: gtk::Button,
    pub(crate) live: gtk::Button,
    /// The stack the photo heads, when it heads one: opens its photos.
    pub(crate) stack_button: gtk::Button,
    /// A hint that the photo's details are a scroll down: shown while the page is at the photo, a click scrolls there.
    details_hint: gtk::Button,
    /// Bumps with every photo shown, so late answers for an earlier one are dropped.
    pub(crate) shown: Cell<u64>,
    pub(crate) updating_favorite: Cell<bool>,
    /// A rotation is on its way: another waits for it, so two quick turns are never one.
    pub(crate) rotating: Cell<bool>,
    pub(crate) stage: gtk::Overlay,
    pub(crate) toolbar: adw::ToolbarView,
    /// Face Names: the photo's faces, drawn over it while the button is on.
    pub(crate) faces_layer: crate::faces::FaceLayer,
    pub(crate) faces: RefCell<Vec<immich_api::Face>>,
    pub(crate) faces_button: gtk::ToggleButton,
    /// Rotate View Temporarily: quarter turns clockwise, for this photo and only on screen.
    pub(crate) view_turns: Cell<i32>,
    /// Full Screen or the slideshow, while on.
    pub(crate) presentation: RefCell<Option<Rc<crate::slideshow::Presentation>>>,
    /// Where one photo slides out and the next in, over the stage (`motion`).
    pub(crate) slide: crate::motion::SlideLayer,
    /// A touchpad's sideways swipe, while the fingers are down.
    swipe: RefCell<Option<Swipe>>,
}

/// A sideways swipe on the stage: how far the photo has moved with the fingers, how fast they left it, the photo and
/// its place as the swipe began, and the photos either side as far as they are read (previous, next).
struct Swipe {
    offset: f64,
    velocity: f64,
    outgoing: (gdk::Paintable, gtk::graphene::Rect),
    neighbours: [Option<gdk::Paintable>; 2],
}

pub fn viewer_page(window: &Window, tiles: Vec<Tile>, index: usize, kind: Kind, grid: Option<Grid>, opening: Option<Opening>) -> adw::NavigationPage {
    let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Contain).can_shrink(true).hexpand(true).vexpand(true).build();
    let scrolled = gtk::ScrolledWindow::builder().child(&picture).hscrollbar_policy(gtk::PolicyType::Never).vscrollbar_policy(gtk::PolicyType::Never).focusable(true).build();
    let video = gtk::Video::builder().autoplay(true).hexpand(true).vexpand(true).build();
    let spinner = adw::Spinner::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).width_request(48).height_request(48).visible(false).build();
    let stack = gtk::Stack::builder().transition_type(gtk::StackTransitionType::None).build();
    stack.add_named(&scrolled, Some("photo"));
    stack.add_named(&video, Some("video"));

    let previous = gtk::Button::builder().icon_name("go-previous-symbolic").tooltip_text(tr("Previous")).halign(gtk::Align::Start).valign(gtk::Align::Center).css_classes(["circular", "osd", "gallery-osd-button"]).build();
    let next = gtk::Button::builder().icon_name("go-next-symbolic").tooltip_text(tr("Next")).halign(gtk::Align::End).valign(gtk::Align::Center).css_classes(["circular", "osd", "gallery-osd-button"]).build();
    let live = gtk::Button::builder().child(&adw::ButtonContent::builder().icon_name("verso-live-symbolic").label(tr("Live")).build()).tooltip_text(tr("Play the Live Photo")).halign(gtk::Align::Start).valign(gtk::Align::Start).css_classes(["osd", "pill", "gallery-osd-button"]).visible(false).build();
    let stack_button = gtk::Button::builder().tooltip_text(tr("Show the Stack's Photos")).halign(gtk::Align::End).valign(gtk::Align::Start).css_classes(["osd", "pill", "gallery-osd-button"]).visible(false).build();
    let stage = gtk::Overlay::builder().child(&stack).css_classes(["gallery-stage"]).build();
    let slide = crate::motion::SlideLayer::default();
    stage.add_overlay(&slide);
    let faces_layer = crate::faces::FaceLayer::new();
    stage.add_overlay(&faces_layer);
    stage.add_overlay(&spinner);
    stage.add_overlay(&previous);
    stage.add_overlay(&next);
    stage.add_overlay(&live);
    stage.add_overlay(&stack_button);
    let details_hint = gtk::Button::builder()
        .icon_name("pan-down-symbolic")
        .tooltip_text(tr("Details"))
        .halign(gtk::Align::Center)
        .valign(gtk::Align::End)
        .css_classes(["circular", "osd", "gallery-osd-button", "verso-details-hint"])
        .build();
    stage.add_overlay(&details_hint);

    // The photo fills the view; its details are below it, a scroll away.
    let details_box = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(24).margin_top(24).margin_bottom(36).margin_start(12).margin_end(12).build();
    let details_clamp = adw::Clamp::builder().maximum_size(720).child(&details_box).build();
    let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    column.append(&stage);
    column.append(&details_clamp);
    let page_scroller = gtk::ScrolledWindow::builder().child(&column).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
    let weak_stage = stage.downgrade();
    page_scroller.vadjustment().connect_page_size_notify(move |adjustment| {
        if let Some(stage) = weak_stage.upgrade() {
            stage.set_size_request(-1, adjustment.page_size() as i32);
        }
    });

    let title = adw::WindowTitle::new("", "");
    let header = adw::HeaderBar::builder().title_widget(&title).build();
    let favorite = gtk::ToggleButton::builder().icon_name("verso-heart-outline-symbolic").tooltip_text(tr("Favorite")).build();
    let info_button = gtk::Button::builder().icon_name("help-about-symbolic").tooltip_text(tr("Info")).build();
    let delete = gtk::Button::builder().icon_name(if kind == Kind::Trash { "edit-undo-symbolic" } else { "user-trash-symbolic" }).build();
    delete.set_tooltip_text(Some(if kind == Kind::Trash { tr("Restore") } else { tr("Move to Trash") }));
    delete.set_action_name(Some(if kind == Kind::Trash { "viewer.restore" } else { "viewer.trash" }));
    let faces_button = gtk::ToggleButton::builder().icon_name("avatar-default-symbolic").tooltip_text(tr("Face Names")).active(settings::shared().get("viewer.showFaces").as_deref() == Some("true")).build();
    let menu = gio::Menu::new();
    let copying = gio::Menu::new();
    copying.append(Some(tr("Copy Image")), Some("viewer.copy"));
    // The Locked Folder's originals stay off the disk.
    if kind != Kind::Locked {
        copying.append(Some(tr("Copy Original Image")), Some("viewer.copy-original"));
        copying.append(Some(tr("Copy as File")), Some("viewer.copy-file"));
    }
    menu.append_section(None, &copying);
    let files = gio::Menu::new();
    files.append(Some(tr("Download Original…")), Some("viewer.download"));
    files.append(Some(tr("Open With…")), Some("viewer.open-with"));
    menu.append_section(None, &files);
    let immich = gio::Menu::new();
    crate::crosslink::append(&immich, "asset", "viewer");
    menu.append_section(None, &immich);
    // What a photo offers depends on where it is: the trash's can only come back or go for good, and the Locked
    // Folder's only leave it (or go to the trash).
    let organise = gio::Menu::new();
    match kind {
        Kind::Trash => organise.append(Some(tr("Delete Forever…")), Some("viewer.delete-forever")),
        Kind::Locked => organise.append(Some(tr("Move Out of the Locked Folder")), Some("viewer.unlock")),
        // A partner's photos are theirs to change.
        Kind::Partner => {}
        _ => {
            organise.append(Some(tr("Rotate Left")), Some("viewer.rotate-left"));
            organise.append(Some(tr("Rotate Right")), Some("viewer.rotate-right"));
            organise.append(Some(tr("Crop…")), Some("viewer.crop"));
            organise.append(Some(tr("Add to Album…")), Some("viewer.add-to-album"));
            if kind.album_id().is_some() {
                organise.append(Some(tr("Use as Album Cover")), Some("viewer.cover"));
                organise.append(Some(tr("Comments and Likes…")), Some("viewer.activity"));
            }
            organise.append(Some(if kind == Kind::Archive { tr("Unarchive") } else { tr("Archive") }), Some("viewer.archive"));
            organise.append(Some(tr("Move to the Locked Folder…")), Some("viewer.lock"));
        }
    }
    let viewing = gio::Menu::new();
    viewing.append(Some(tr("Start Slideshow")), Some("viewer.slideshow"));
    viewing.append(Some(tr("Full Screen")), Some("viewer.full-screen"));
    viewing.append(Some(tr("Rotate View Temporarily Left")), Some("viewer.view-left"));
    viewing.append(Some(tr("Rotate View Temporarily Right")), Some("viewer.view-right"));
    if !matches!(kind, Kind::Library | Kind::Locked | Kind::Partner) {
        viewing.append(Some(tr("Show in All Photos")), Some("viewer.show-in-library"));
    }
    if kind != Kind::Partner {
        viewing.append(Some(tr("Manage Faces…")), Some("viewer.faces"));
    }
    viewing.append(Some(tr("Loop Video")), Some("viewer.loop"));
    menu.append_section(None, &viewing);
    menu.append_section(None, &organise);
    let menu_button = gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(tr("More")).menu_model(&menu).build();
    header.pack_end(&menu_button);
    header.pack_end(&info_button);
    header.pack_end(&faces_button);
    header.pack_end(&delete);
    header.pack_end(&favorite);
    delete.set_visible(kind != Kind::Partner);
    favorite.set_visible(kind != Kind::Partner);

    let toolbar = adw::ToolbarView::builder().top_bar_style(adw::ToolbarStyle::Raised).build();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&page_scroller));
    let page = adw::NavigationPage::builder().title(tr("Photo")).child(&toolbar).tag("viewer").build();

    let state = Rc::new(State {
        window: window.downgrade(),
        grid,
        kind,
        tiles: RefCell::new(tiles),
        index: Cell::new(index),
        texture: RefCell::default(),
        zoom: Cell::new(0.0),
        zoom_at_gesture_start: Cell::new(1.0),
        picture,
        scrolled,
        video,
        stack,
        spinner,
        title,
        favorite,
        page_scroller,
        details_box,
        details_clamp,
        details: RefCell::default(),
        previous,
        next,
        live,
        stack_button,
        details_hint,
        shown: Cell::new(0),
        updating_favorite: Cell::new(false),
        rotating: Cell::new(false),
        stage,
        toolbar,
        faces_layer,
        faces: RefCell::default(),
        faces_button,
        view_turns: Cell::new(0),
        presentation: RefCell::default(),
        slide,
        swipe: RefCell::default(),
    });
    // The details' hint goes once the page scrolls to them, and comes back at the photo; a click scrolls there.
    let weak = Rc::downgrade(&state);
    state.page_scroller.vadjustment().connect_value_changed(move |_| {
        if let Some(state) = weak.upgrade() {
            state.refresh_details_hint();
        }
    });
    let weak = Rc::downgrade(&state);
    state.details_hint.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.toggle_details();
        }
    });
    // The boxes fall on the photo as it shows: fitted, or zoomed and scrolled.
    let weak = Rc::downgrade(&state);
    state.faces_layer.set_boxes(Box::new(move |layer| {
        let Some(state) = weak.upgrade() else { return Vec::new() };
        let showing_photo = state.stack.visible_child_name().as_deref() == Some("photo");
        if !state.faces_button.is_active() || state.view_turns.get() != 0 || !showing_photo || state.faces.borrow().is_empty() {
            return Vec::new();
        }
        let Some(bounds) = state.picture.compute_bounds(layer) else { return Vec::new() };
        let frame = (f64::from(bounds.x()), f64::from(bounds.y()), f64::from(bounds.width()), f64::from(bounds.height()));
        let shown = match state.texture.borrow().as_ref() {
            // Where the photo is drawn in the picture, fitted and zoomed alike: zoomed, it may sit centred in a larger one.
            Some(texture) => presentation::fitted(f64::from(texture.width()), f64::from(texture.height()), frame),
            _ => frame,
        };
        let faces = state.faces.borrow().clone();
        crate::faces::boxes_on(&faces, shown)
    }));
    for adjustment in [state.scrolled.hadjustment(), state.scrolled.vadjustment()] {
        let layer = state.faces_layer.downgrade();
        adjustment.connect_value_changed(move |_| {
            if let Some(layer) = layer.upgrade() {
                layer.queue_draw();
            }
        });
    }
    let weak = Rc::downgrade(&state);
    state.faces_button.connect_toggled(move |button| {
        settings::shared().set("viewer.showFaces", button.is_active().then_some("true"));
        if let Some(state) = weak.upgrade() {
            if button.is_active() {
                state.load_faces();
            }
            state.faces_layer.queue_draw();
        }
    });

    let weak = Rc::downgrade(&state);
    state.previous.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.step(-1);
        }
    });
    let weak = Rc::downgrade(&state);
    state.next.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.step(1);
        }
    });
    let weak = Rc::downgrade(&state);
    state.live.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.play_live();
        }
    });
    let weak = Rc::downgrade(&state);
    state.stack_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.open_stack();
        }
    });
    let weak = Rc::downgrade(&state);
    state.favorite.connect_toggled(move |button| {
        if let Some(state) = weak.upgrade() {
            if !state.updating_favorite.get() {
                state.set_favorite(button.is_active());
            }
        }
    });
    let weak = Rc::downgrade(&state);
    info_button.connect_clicked(move |_| {
        if let Some(state) = weak.upgrade() {
            state.toggle_details();
        }
    });
    install_actions(&page, &state);
    install_gestures(&state);

    // Keys: arrows step, Escape goes back, + - 0 zoom, period favorites, Ctrl+I info, Delete trashes, Space plays a
    // video and otherwise goes back.
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&state);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(state) = weak.upgrade() else { return glib::Propagation::Proceed };
        let Some(window) = state.window.upgrade() else { return glib::Propagation::Proceed };
        if gtk::prelude::RootExt::focus(&window).is_some_and(|focus| focus.is::<gtk::Text>() || focus.ancestor(gtk::Editable::static_type()).is_some()) {
            return glib::Propagation::Proceed;
        }
        let control = modifiers.contains(gdk::ModifierType::CONTROL_MASK);
        match key {
            gdk::Key::Left | gdk::Key::Page_Up => crate::slideshow::step(&state, -1),
            gdk::Key::Right | gdk::Key::Page_Down => crate::slideshow::step(&state, 1),
            // Down to the photo's details and on through them, Up back through them to the photo, so a photo is read
            // from the keys alone; zoomed in, they pan, and Full Screen and the slideshow keep them.
            gdk::Key::Down if state.zoom.get() <= 0.0 && !crate::slideshow::is_on(&state) => state.scroll_page(1),
            gdk::Key::Up if state.zoom.get() <= 0.0 && !crate::slideshow::is_on(&state) => state.scroll_page(-1),
            gdk::Key::Escape => {
                if crate::slideshow::is_on(&state) {
                    crate::slideshow::stop(&state);
                } else if state.zoom.get() > 0.0 {
                    state.set_zoom(0.0);
                } else {
                    window.close_viewer();
                }
            }
            gdk::Key::plus | gdk::Key::equal | gdk::Key::KP_Add => state.zoom_by(1.5),
            gdk::Key::minus | gdk::Key::KP_Subtract => state.zoom_by(1.0 / 1.5),
            gdk::Key::_0 | gdk::Key::KP_0 => state.set_zoom(0.0),
            gdk::Key::period if state.kind != Kind::Partner => state.favorite.set_active(!state.favorite.is_active()),
            gdk::Key::i if control && !crate::slideshow::is_on(&state) => state.toggle_details(),
            gdk::Key::c if control => state.copy_image(),
            gdk::Key::F5 => crate::slideshow::start(&state, true),
            gdk::Key::F11 if crate::slideshow::is_on(&state) => crate::slideshow::stop(&state),
            gdk::Key::F11 => crate::slideshow::start(&state, false),
            // In the trash, Delete does nothing here: Restore and Delete Forever are buttons and menu items, so one
            // key never does two different things in one place.
            gdk::Key::Delete | gdk::Key::KP_Delete if !matches!(state.kind, Kind::Trash | Kind::Partner) => {
                let _ = WidgetExt::activate_action(&state.stack, "viewer.trash", None);
            }
            gdk::Key::space => {
                if let Some(stream) = state.video.media_stream().filter(|_| state.stack.visible_child_name().as_deref() == Some("video")) {
                    stream.set_playing(!stream.is_playing());
                } else if crate::slideshow::is_slideshow(&state) {
                    crate::slideshow::toggle_pause(&state);
                } else if !crate::slideshow::is_on(&state) {
                    // Space opened the photo from the grid, as a quick look; Space again goes back to it.
                    window.close_viewer();
                } else {
                    return glib::Propagation::Proceed;
                }
            }
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    page.add_controller(keys);
    // The stage takes the keys, so the arrows and Escape work at once.
    let weak = Rc::downgrade(&state);
    page.connect_shown(move |_| {
        if let Some(state) = weak.upgrade() {
            state.scrolled.grab_focus();
        }
    });
    let weak = Rc::downgrade(&state);
    page.connect_hiding(move |page| {
        if let Some(state) = weak.upgrade() {
            state.leaving(page);
        }
    });
    let weak = Rc::downgrade(&state);
    page.connect_hidden(move |_| {
        if let Some(state) = weak.upgrade() {
            crate::slideshow::stop(&state);
            if let Some(stream) = state.video.media_stream() {
                stream.set_playing(false);
            }
        }
    });
    // The page owns the viewer's state; everything else holds it weakly, so it goes when the page does.
    let owned = state.clone();
    page.connect_destroy(move |_| {
        let _ = &owned;
    });
    state.show();
    if let Some(opening) = opening {
        state.zoom_in(opening);
    }
    page
}

impl State {
    /// The zoom out of the grid square as the viewer opens: the photo on the stage stays hidden until it has landed.
    fn zoom_in(&self, opening: Opening) {
        let Some(window) = self.window.upgrade() else { return };
        let (layer, overlay) = window.flight_layer();
        let ratio = self.tile().map_or(1.0, |tile| tile.ratio);
        let (picture, scrolled, thumbnail) = (self.picture.downgrade(), self.scrolled.downgrade(), opening.thumbnail);
        let shown = picture.clone();
        // The sharper of the square's thumbnail and what the stage shows, which may at first be only the photo's
        // blurred placeholder (on GNOME 50), and later its preview.
        let photo = Box::new(move || match shown.upgrade().and_then(|picture| picture.paintable()) {
            Some(paintable) if paintable.intrinsic_width() > thumbnail.intrinsic_width() => Some(paintable),
            _ => Some(thumbnail.clone()),
        });
        let to = Box::new(move || {
            let scrolled = scrolled.upgrade().filter(|scrolled| scrolled.is_mapped() && scrolled.width() > 1)?;
            let area = scrolled.compute_bounds(&overlay)?;
            let ratio = picture.upgrade().and_then(|picture| picture.paintable()).and_then(|paintable| crate::motion::ratio_of(&paintable)).unwrap_or(ratio);
            Some(crate::motion::contain(ratio, &area))
        });
        self.stack.set_opacity(0.0);
        let stack = self.stack.downgrade();
        let done = Box::new(move || {
            if let Some(stack) = stack.upgrade() {
                stack.set_opacity(1.0);
            }
        });
        layer.fly(crate::motion::Flight { backdrop: opening.backdrop, photo, from: opening.from, to, done });
    }

    /// As the viewer starts hiding: let go of the photo, and a still of the viewer without it (`Closing`).
    fn leaving(&self, page: &adw::NavigationPage) {
        let (Some(window), Some(tile)) = (self.window.upgrade(), self.tile()) else { return };
        let (_, overlay) = window.flight_layer();
        let as_photo = self.stack.visible_child_name().is_some_and(|name| name == "photo") && self.zoom.get() <= 0.0;
        let lifted = as_photo
            .then(|| {
                let paintable = self.picture.paintable()?;
                let area = self.scrolled.compute_bounds(&overlay)?;
                let place = crate::motion::contain(crate::motion::ratio_of(&paintable).unwrap_or(tile.ratio), &area);
                Some((paintable, place))
            })
            .flatten();
        if lifted.is_some() {
            self.stack.set_opacity(0.0);
        }
        let backdrop = crate::motion::still(page);
        self.stack.set_opacity(1.0);
        window.viewer_leaving(Closing { id: tile.id, lifted, backdrop });
    }

    pub(crate) fn tile(&self) -> Option<Tile> {
        self.tiles.borrow().get(self.index.get()).cloned()
    }

    pub(crate) fn step(self: &Rc<Self>, by: i32) {
        let count = self.tiles.borrow().len() as i32;
        let index = self.index.get() as i32 + by;
        if (0..count).contains(&index) {
            // A slide still running lands first; the photo shown then slides out, the next in.
            self.slide.end();
            let outgoing = self.placed_photo();
            self.index.set(index as usize);
            self.show();
            if let Some(outgoing) = outgoing {
                self.slide_in(outgoing, by.signum() as f32);
            }
        }
    }

    /// The photo on the stage and its place over it, when it can slide: a photo, fitted, outside Full Screen and the
    /// slideshow (which fade).
    fn placed_photo(&self) -> Option<(gdk::Paintable, gtk::graphene::Rect)> {
        let as_photo = self.stack.visible_child_name().is_some_and(|name| name == "photo");
        if !as_photo || self.zoom.get() > 0.0 || self.view_turns.get() != 0 || self.presentation.borrow().is_some() || !self.stage.is_mapped() {
            return None;
        }
        let paintable = self.picture.paintable()?;
        // In the stage's own space, which the slide layer covers whole (it is hidden, and unplaced, between slides).
        let area = self.scrolled.compute_bounds(&self.stage)?;
        let place = crate::motion::contain(crate::motion::ratio_of(&paintable)?, &area);
        Some((paintable, place))
    }

    /// Hide the stage's photo while the slide layer shows `slide` at `progress`; it shows again when the slide ends.
    fn hold_slide(&self, slide: crate::motion::Slide, progress: f64) {
        self.stack.set_opacity(0.0);
        let stack = self.stack.downgrade();
        self.slide.hold(
            slide,
            progress,
            Box::new(move || {
                if let Some(stack) = stack.upgrade() {
                    stack.set_opacity(1.0);
                }
            }),
        );
    }

    /// Slide `outgoing` out and the photo now shown in, from the right going forward (`direction` 1).
    fn slide_in(&self, outgoing: (gdk::Paintable, gtk::graphene::Rect), direction: f32) {
        let (picture, scrolled, stage) = (self.picture.downgrade(), self.scrolled.downgrade(), self.stage.downgrade());
        let incoming = Box::new(move || {
            let paintable = picture.upgrade()?.paintable()?;
            let area = scrolled.upgrade()?.compute_bounds(&stage.upgrade()?)?;
            let place = crate::motion::contain(crate::motion::ratio_of(&paintable)?, &area);
            Some((paintable, place))
        });
        self.hold_slide(crate::motion::Slide { outgoing: Some(outgoing), incoming, direction }, 0.0);
        self.slide.run(1.0, crate::motion::SLIDE_MS);
    }

    /// A touchpad swipe starts: the photo and the ones either side, as far as they are read.
    fn swipe_begin(&self) {
        self.slide.end();
        let Some(outgoing) = self.placed_photo() else {
            self.swipe.replace(None);
            return;
        };
        let session = self.window.upgrade().and_then(|window| window.session());
        let tiles = self.tiles.borrow();
        let neighbour = |index: Option<usize>| -> Option<gdk::Paintable> {
            let tile = tiles.get(index?)?;
            let textures = &session.as_ref()?.textures;
            let hash = tile.thumbhash.as_deref();
            let texture = textures.cached(ImageKind::Preview, &tile.id, hash).or_else(|| textures.cached(ImageKind::Thumbnail, &tile.id, hash)).or_else(|| hash.and_then(|hash| textures.placeholder(hash)))?;
            Some(texture.upcast())
        };
        let index = self.index.get();
        let neighbours = [neighbour(index.checked_sub(1)), neighbour(Some(index + 1))];
        drop(tiles);
        self.swipe.replace(Some(Swipe { offset: 0.0, velocity: 0.0, outgoing, neighbours }));
    }

    /// The fingers moved by `dx`: the photo follows them, the next or previous coming in beside it; past the first or
    /// the last photo, it gives a little. Whether the swipe took the move.
    fn swipe_by(&self, dx: f64) -> bool {
        let mut swipe = self.swipe.borrow_mut();
        let Some(swipe) = swipe.as_mut() else { return false };
        if dx == 0.0 {
            return self.slide.is_sliding();
        }
        swipe.offset -= dx;
        let width = f64::from(self.stage.width().max(1));
        let direction: f32 = if swipe.offset < 0.0 { 1.0 } else { -1.0 };
        let neighbour = swipe.neighbours[usize::from(direction > 0.0)].clone();
        let reach = if neighbour.is_some() { 1.0 } else { 0.2 };
        let progress = (swipe.offset.abs() / width).min(1.0) * reach;
        let (scrolled, stage) = (self.scrolled.downgrade(), self.stage.downgrade());
        let incoming = Box::new(move || {
            let paintable = neighbour.clone()?;
            let area = scrolled.upgrade()?.compute_bounds(&stage.upgrade()?)?;
            let place = crate::motion::contain(crate::motion::ratio_of(&paintable)?, &area);
            Some((paintable, place))
        });
        self.hold_slide(crate::motion::Slide { outgoing: Some(swipe.outgoing.clone()), incoming, direction }, progress);
        true
    }

    /// The fingers left: on to the next or previous photo when the swipe went far or fast enough, else back.
    fn swipe_end(self: &Rc<Self>) {
        let Some(swipe) = self.swipe.take() else { return };
        if !self.slide.is_sliding() {
            return;
        }
        let width = f64::from(self.stage.width().max(1));
        let forward = swipe.offset < 0.0;
        let has_neighbour = swipe.neighbours[usize::from(forward)].is_some();
        // The photo moves against the scroll; flung its own way fast, it goes on even from a short swipe.
        let flung = -swipe.velocity * swipe.offset.signum() > 600.0;
        let progress = self.slide.progress();
        if has_neighbour && (swipe.offset.abs() > width * 0.25 || flung) {
            self.index.set(if forward { self.index.get() + 1 } else { self.index.get() - 1 });
            self.show();
            self.slide.run(1.0, ((1.0 - progress) * f64::from(crate::motion::SWIPE_MS)).max(150.0) as u32);
        } else {
            self.slide.run(0.0, (progress * f64::from(crate::motion::SWIPE_MS)).max(150.0) as u32);
        }
    }

    pub(crate) fn show(self: &Rc<Self>) {
        let Some(tile) = self.tile() else { return };
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        self.shown.set(self.shown.get() + 1);
        let shown = self.shown.get();
        self.details.replace(None);
        let count = self.tiles.borrow().len();
        self.title.set_title(&text::taken(tile.taken));
        self.title.set_subtitle(&tr("{index} of {count}").replace("{index}", &(self.index.get() + 1).to_string()).replace("{count}", &count.to_string()));
        self.refresh_steps();
        self.live.set_visible(tile.is_live);
        self.view_turns.set(0);
        self.stack_button.set_visible(tile.stack.is_some());
        if let Some((_, count)) = &tile.stack {
            self.stack_button.set_label(&tr("Stack of {count}").replace("{count}", &count.to_string()));
        }
        self.updating_favorite.set(true);
        self.favorite.set_active(tile.is_favorite);
        self.favorite.set_icon_name(if tile.is_favorite { "verso-heart-symbolic" } else { "verso-heart-outline-symbolic" });
        self.updating_favorite.set(false);
        if let Some(stream) = self.video.media_stream() {
            stream.set_playing(false);
        }
        self.video.set_media_stream(gtk::MediaStream::NONE);
        self.set_zoom(0.0);
        self.stack.set_visible_child_name("photo");
        // The thumbnail (or its placeholder) at once, the preview when it comes.
        let quick = session.textures.cached(ImageKind::Thumbnail, &tile.id, tile.thumbhash.as_deref()).or_else(|| tile.thumbhash.as_deref().and_then(|hash| session.textures.placeholder(hash)));
        self.set_texture(quick);
        self.spinner.set_visible(true);
        let weak = Rc::downgrade(self);
        session.textures.get(ImageKind::Preview, &tile.id, tile.thumbhash.as_deref(), move |texture| {
            let Some(state) = weak.upgrade() else { return };
            if state.shown.get() != shown {
                return;
            }
            if texture.is_some() {
                state.set_texture(texture);
            }
            if !state.stack.visible_child_name().is_some_and(|name| name == "video") || texture_is_none(&state) {
                state.spinner.set_visible(false);
            }
        });
        if tile.is_video {
            self.play_video(&tile.id, shown);
        }
        // Read the neighbours' previews ahead, so stepping is instant.
        for neighbour in [self.index.get() + 1, self.index.get().wrapping_sub(1)] {
            if let Some(next) = self.tiles.borrow().get(neighbour) {
                session.textures.get(ImageKind::Preview, &next.id, next.thumbhash.as_deref(), |_| {});
            }
        }
        // The details below, once the photo has shown a moment: stepping fast reads none on the way.
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
            if let Some(state) = weak.upgrade().filter(|state| state.shown.get() == shown) {
                state.load_details();
            }
        });
        self.faces.borrow_mut().clear();
        if self.faces_button.is_active() {
            self.load_faces();
        }
        self.faces_layer.queue_draw();
        crate::slideshow::shown(self);
    }

    /// Previous and Next beside the photo, where there is one (the presentation has its own).
    pub(crate) fn refresh_steps(&self) {
        let presenting = self.presentation.borrow().is_some();
        let count = self.tiles.borrow().len();
        self.previous.set_visible(!presenting && self.index.get() > 0);
        self.next.set_visible(!presenting && self.index.get() + 1 < count);
        self.refresh_details_hint();
    }

    /// The details' hint, while the page shows the photo and not Full Screen or the slideshow.
    fn refresh_details_hint(&self) {
        let at_photo = self.page_scroller.vadjustment().value() < 1.0;
        self.details_hint.set_visible(at_photo && self.presentation.borrow().is_none());
    }

    /// The photo's faces, for Face Names. Immich measures them on the unedited photo, so an edited one shows none.
    fn load_faces(self: &Rc<Self>) {
        let Some(tile) = self.tile().filter(|tile| !tile.is_video) else { return };
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let (client, id, shown, weak) = (session.connection.client.clone(), tile.id.clone(), self.shown.get(), Rc::downgrade(self));
        crate::tasks::run(
            async move {
                if client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?.is_edited {
                    return Ok(Vec::new());
                }
                client.faces(&id).await.map_err(|error| verso_desktop::errors::said(&error))
            },
            move |outcome| {
                let Some(state) = weak.upgrade().filter(|state| state.shown.get() == shown) else { return };
                match outcome {
                    Ok(faces) => {
                        state.faces.replace(faces);
                        state.faces_layer.queue_draw();
                    }
                    Err(message) => {
                        if let Some(window) = state.window.upgrade() {
                            window.toast(&message);
                        }
                    }
                }
            },
        );
    }

    /// Rotate View Temporarily: the picture turns on screen, until another photo shows.
    fn turn_view(&self, by: i32) {
        if self.tile().is_none_or(|tile| tile.is_video) {
            return;
        }
        self.view_turns.set((self.view_turns.get() + by).rem_euclid(4));
        let Some(texture) = self.texture.borrow().clone() else { return };
        let turned = turned(&texture, by);
        self.picture.set_paintable(Some(&turned));
        self.texture.replace(Some(turned));
        self.set_zoom(0.0);
        self.faces_layer.queue_draw();
    }

    /// Copy Image: the picture shown, as a picture.
    fn copy_image(&self) {
        let (Some(window), Some(tile)) = (self.window.upgrade(), self.tile()) else { return };
        if tile.is_video {
            return;
        }
        if let Some(texture) = self.texture.borrow().as_ref() {
            window.clipboard().set_texture(texture);
            window.toast(tr("Image copied"));
        }
    }

    /// Copy Original Image or Copy as File: the original, downloaded into the cache's clipboard folder (the last
    /// copied only), then copied as a picture or as the file itself.
    fn copy_original(&self, as_file: bool) {
        let (Some(window), Some(tile)) = (self.window.upgrade(), self.tile()) else { return };
        if !as_file && tile.is_video {
            return;
        }
        let Some(session) = window.session() else { return };
        let clipboard = session.connection.cache_directory().join("clipboard");
        let (client, id) = (session.connection.client.clone(), tile.id.clone());
        window.toast(tr("Copying the original…"));
        crate::tasks::run(
            async move {
                if let Ok(mut entries) = tokio::fs::read_dir(&clipboard).await {
                    while let Ok(Some(entry)) = entries.next_entry().await {
                        if entry.file_name().to_string_lossy() != id {
                            let _ = tokio::fs::remove_dir_all(entry.path()).await;
                        }
                    }
                }
                let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let name = std::path::Path::new(&details.original_file_name).file_name().map_or_else(|| id.clone(), |name| name.to_string_lossy().into_owned());
                let folder = clipboard.join(&id);
                tokio::fs::create_dir_all(&folder).await.map_err(|error| error.to_string())?;
                let path = folder.join(name);
                if !path.exists() {
                    let partial = verso_desktop::images::partial_path(&path);
                    if let Err(error) = client.download_original(&id, &partial).await {
                        let _ = tokio::fs::remove_file(&partial).await;
                        return Err(error.to_string());
                    }
                    verso_desktop::images::settle(&partial, &path).map_err(|error| error.to_string())?;
                }
                Ok::<PathBuf, String>(path)
            },
            move |outcome| match outcome {
                Ok(path) if as_file => {
                    let files = gdk::FileList::from_array(&[gio::File::for_path(&path)]);
                    if let Err(error) = window.clipboard().set_content(Some(&gdk::ContentProvider::for_value(&files.to_value()))) {
                        return window.toast(&error.to_string());
                    }
                    window.toast(tr("Copied as a file"));
                }
                Ok(path) => match gdk::Texture::from_filename(&path) {
                    Ok(texture) => {
                        window.clipboard().set_texture(&texture);
                        window.toast(tr("Original copied"));
                    }
                    Err(_) => window.toast(tr("This original cannot be read as a picture here; Copy as File copies it whole.")),
                },
                Err(message) => window.toast(&message),
            },
        );
    }

    fn set_texture(&self, texture: Option<gdk::Texture>) {
        let texture = match texture {
            Some(texture) if self.view_turns.get() != 0 => Some(turned(&texture, self.view_turns.get())),
            other => other,
        };
        // Zoom counts the texture's pixels: when a sharper one replaces it, scale the zoom so the photo stays put.
        if let (Some(old), Some(new)) = (self.texture.borrow().as_ref(), texture.as_ref()) {
            if self.zoom.get() > 0.0 && new.width() > 0 {
                self.zoom.set((self.zoom.get() * f64::from(old.width()) / f64::from(new.width())).clamp(0.01, MAX_ZOOM));
            }
        }
        self.picture.set_paintable(texture.as_ref());
        self.texture.replace(texture);
        if self.zoom.get() > 0.0 {
            self.apply_zoom();
        }
        self.faces_layer.queue_draw();
    }

    /// Where a video's playback file is kept: the account's cache, once per video.
    fn video_path(&self, id: &str) -> Option<PathBuf> {
        let session = self.window.upgrade()?.session()?;
        Some(session.connection.cache_directory().join(verso_desktop::images::VIDEOS).join(format!("{id}.mp4")))
    }

    fn play_video(self: &Rc<Self>, id: &str, shown: u64) {
        let (Some(path), Some(session)) = (self.video_path(id), self.window.upgrade().and_then(|window| window.session())) else { return };
        let client = session.connection.client.clone();
        let id = id.to_owned();
        self.spinner.set_visible(true);
        let weak = Rc::downgrade(self);
        crate::tasks::run(
            async move {
                if !path.exists() {
                    if let Some(folder) = path.parent() {
                        tokio::fs::create_dir_all(folder).await.map_err(|error| error.to_string())?;
                    }
                    let partial = verso_desktop::images::partial_path(&path);
                    if let Err(error) = client.download_video_playback(&id, &partial).await {
                        let _ = tokio::fs::remove_file(&partial).await;
                        return Err(error.to_string());
                    }
                    verso_desktop::images::settle(&partial, &path).map_err(|error| error.to_string())?;
                }
                Ok::<PathBuf, String>(path)
            },
            move |outcome| {
                let Some(state) = weak.upgrade() else { return };
                if state.shown.get() != shown {
                    return;
                }
                state.spinner.set_visible(false);
                match outcome {
                    Ok(path) => {
                        let media = gtk::MediaFile::for_filename(&path);
                        media.set_loop(settings::shared().get("viewer.videoLoop").as_deref() == Some("true") && !crate::slideshow::is_on(&state));
                        // Without the codec (GStreamer's H.264 decoder, say) the video stays black: show the still
                        // instead, and say how else to play it.
                        let weak = Rc::downgrade(&state);
                        media.connect_error_notify(move |media| {
                            let (Some(state), Some(error)) = (weak.upgrade(), media.error()) else { return };
                            if state.shown.get() != shown {
                                return;
                            }
                            state.stack.set_visible_child_name("photo");
                            if let Some(window) = state.window.upgrade() {
                                window.toast(&tr("This video cannot be played here ({error}). Open With plays it in another app.").replace("{error}", error.message()));
                            }
                        });
                        state.video.set_media_stream(Some(&media));
                        media.play();
                        state.stack.set_visible_child_name("video");
                    }
                    Err(message) => {
                        if let Some(window) = state.window.upgrade() {
                            window.toast(&tr("The video could not be played: {error}").replace("{error}", &message));
                        }
                    }
                }
            },
        );
    }

    /// The stack's photos, in a page of their own.
    fn open_stack(self: &Rc<Self>) {
        let Some((stack_id, _)) = self.tile().and_then(|tile| tile.stack) else { return };
        let Some(window) = self.window.upgrade() else { return };
        window.close_viewer();
        crate::stacks::show_stack(&window, &stack_id);
    }

    /// Play a Live Photo's video once, then show the still again.
    fn play_live(self: &Rc<Self>) {
        let Some(tile) = self.tile() else { return };
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let client = session.connection.client.clone();
        let shown = self.shown.get();
        let weak = Rc::downgrade(self);
        self.spinner.set_visible(true);
        let id = tile.id.clone();
        crate::tasks::run(async move { client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            let Some(state) = weak.upgrade() else { return };
            state.spinner.set_visible(false);
            let Some(video_id) = outcome.ok().and_then(|details| details.live_photo_video_id) else { return };
            state.play_video(&video_id, shown);
            let weak = Rc::downgrade(&state);
            glib::timeout_add_local(std::time::Duration::from_millis(250), move || {
                let Some(state) = weak.upgrade() else { return glib::ControlFlow::Break };
                if state.shown.get() != shown {
                    return glib::ControlFlow::Break;
                }
                match state.video.media_stream() {
                    Some(stream) if stream.is_ended() => {
                        state.stack.set_visible_child_name("photo");
                        glib::ControlFlow::Break
                    }
                    _ => glib::ControlFlow::Continue,
                }
            });
        });
    }

    fn set_favorite(self: &Rc<Self>, favorite: bool) {
        let Some(tile) = self.tile() else { return };
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        self.favorite.set_icon_name(if favorite { "verso-heart-symbolic" } else { "verso-heart-outline-symbolic" });
        let client = session.connection.client.clone();
        let id = tile.id.clone();
        let weak = Rc::downgrade(self);
        crate::tasks::run(async move { actions::set_favorite(&client, vec![id], favorite).await }, move |outcome| {
            let Some(state) = weak.upgrade() else { return };
            match outcome {
                Ok(()) => {
                    if let Some(changed) = state.tiles.borrow_mut().iter_mut().find(|candidate| candidate.id == tile.id) {
                        changed.is_favorite = favorite;
                    }
                    if let Some(grid) = &state.grid {
                        grid.update(std::slice::from_ref(&tile.id), |changed| changed.is_favorite = favorite);
                    }
                }
                Err(message) => {
                    if let Some(window) = state.window.upgrade() {
                        window.toast(&message);
                    }
                    state.updating_favorite.set(true);
                    state.favorite.set_active(!favorite);
                    state.updating_favorite.set(false);
                }
            }
        });
    }

    /// The photo left this view (deleted, archived, restored): show the next, or go back when none is left.
    /// A photo left this view (deleted, archived, restored): take out that one, by id, whichever is shown by the
    /// time Immich answers; show the next when it was the one shown, or go back when none is left.
    fn drop_photo(self: &Rc<Self>, id: &str) {
        if let Some(grid) = &self.grid {
            grid.remove(&[id.to_owned()]);
        }
        let mut tiles = self.tiles.borrow_mut();
        let Some(position) = tiles.iter().position(|tile| tile.id == id) else { return };
        tiles.remove(position);
        let index = self.index.get();
        let was_shown = position == index;
        if position < index || index >= tiles.len() {
            self.index.set(index.saturating_sub(1).min(tiles.len().saturating_sub(1)));
        }
        let empty = tiles.is_empty();
        drop(tiles);
        if empty {
            if let Some(window) = self.window.upgrade() {
                window.close_viewer();
            }
        } else if was_shown {
            self.show();
        } else {
            self.refresh_title();
        }
    }

    fn refresh_title(&self) {
        let count = self.tiles.borrow().len();
        self.title.set_subtitle(&tr("{index} of {count}").replace("{index}", &(self.index.get() + 1).to_string()).replace("{count}", &count.to_string()));
        self.previous.set_visible(self.index.get() > 0);
        self.next.set_visible(self.index.get() + 1 < count);
    }

    /// Turn the photo shown, then show it again once Immich has made its pictures anew.
    fn rotate(self: &Rc<Self>, quarter_turns: i32) {
        let Some(tile) = self.tile() else { return };
        if self.rotating.replace(true) {
            return;
        }
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let (client, id) = (session.connection.client.clone(), tile.id.clone());
        let weak = Rc::downgrade(self);
        crate::tasks::run(async move { verso_desktop::actions::rotate(&client, id, quarter_turns).await }, move |outcome| {
            let Some(state) = weak.upgrade() else { return };
            state.rotating.set(false);
            let Some(window) = state.window.upgrade() else { return };
            if let Err(message) = outcome {
                return window.toast(&message);
            }
            // The turned thumbnail and preview come a few seconds later: forget the old ones, then read again.
            let Some(session) = window.session() else { return };
            let forget = |session: &crate::window::Session, id: &str| {
                session.textures.forget(id);
                session.textures.cache().forget_pictures(&[id.to_owned()]);
            };
            forget(&session, &tile.id);
            if let Some(changed) = state.tiles.borrow_mut().iter_mut().find(|candidate| candidate.id == tile.id) {
                if quarter_turns % 2 != 0 {
                    changed.ratio = 1.0 / changed.ratio.max(0.01);
                }
            }
            let (weak, id) = (Rc::downgrade(&state), tile.id.clone());
            glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
                let Some(state) = weak.upgrade() else { return };
                if let Some(session) = state.window.upgrade().and_then(|window| window.session()) {
                    forget(&session, &id);
                }
                if let Some(grid) = &state.grid {
                    grid.turned(&id, quarter_turns);
                }
                if state.tile().is_some_and(|shown| shown.id == id) {
                    state.show();
                }
            });
        });
    }

    /// After a crop: forget the photo's pictures, and once Immich has made them anew, show it again; the crop changes
    /// its shape, so the grids read it again too.
    fn cropped(self: &Rc<Self>, id: String) {
        let forget = |window: &crate::window::Window, id: &str| {
            if let Some(session) = window.session() {
                session.textures.forget(id);
                session.textures.cache().forget_pictures(&[id.to_owned()]);
            }
        };
        let Some(window) = self.window.upgrade() else { return };
        forget(&window, &id);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
            let Some(state) = weak.upgrade() else { return };
            let Some(window) = state.window.upgrade() else { return };
            forget(&window, &id);
            window.reload_grids();
            if state.tile().is_some_and(|shown| shown.id == id) {
                state.show();
            }
        });
    }

    fn zoom_by(&self, factor: f64) {
        let current = if self.zoom.get() > 0.0 { self.zoom.get() } else { self.fit_zoom() };
        self.set_zoom((current * factor).clamp(0.05, MAX_ZOOM));
    }

    /// The zoom at which the photo fits the stage.
    fn fit_zoom(&self) -> f64 {
        let Some(texture) = self.texture.borrow().clone() else { return 1.0 };
        let (width, height) = (self.scrolled.width().max(1) as f64, self.scrolled.height().max(1) as f64);
        (width / texture.width().max(1) as f64).min(height / texture.height().max(1) as f64)
    }

    fn set_zoom(&self, zoom: f64) {
        let zoom = if zoom > 0.0 && zoom <= self.fit_zoom() * 1.001 { 0.0 } else { zoom };
        self.zoom.set(zoom);
        self.apply_zoom();
    }

    fn apply_zoom(&self) {
        self.faces_layer.queue_draw();
        let zoom = self.zoom.get();
        if zoom <= 0.0 {
            self.scrolled.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Never);
            self.picture.set_size_request(-1, -1);
            self.picture.set_content_fit(gtk::ContentFit::Contain);
            return;
        }
        let Some(texture) = self.texture.borrow().clone() else { return };
        let (h_adjustment, v_adjustment) = (self.scrolled.hadjustment(), self.scrolled.vadjustment());
        // Keep the middle of what is on screen in the middle.
        let centre = |adjustment: &gtk::Adjustment| {
            let upper = adjustment.upper().max(1.0);
            (adjustment.value() + adjustment.page_size() / 2.0) / upper
        };
        let (centre_x, centre_y) = if self.scrolled.hscrollbar_policy() == gtk::PolicyType::Never { (0.5, 0.5) } else { (centre(&h_adjustment), centre(&v_adjustment)) };
        self.scrolled.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Automatic);
        // Contain, not Fill: the picture expands to the stage wherever the zoomed photo is still smaller than it, and
        // filling that stretched the photo (issue #5); contained, it keeps its proportions, centred there.
        self.picture.set_content_fit(gtk::ContentFit::Contain);
        let (width, height) = ((texture.width() as f64 * zoom) as i32, (texture.height() as f64 * zoom) as i32);
        self.picture.set_size_request(width, height);
        let (h_adjustment, v_adjustment) = (h_adjustment.clone(), v_adjustment.clone());
        glib::idle_add_local_once(move || {
            h_adjustment.set_value(centre_x * h_adjustment.upper() - h_adjustment.page_size() / 2.0);
            v_adjustment.set_value(centre_y * v_adjustment.upper() - v_adjustment.page_size() / 2.0);
        });
    }

    /// Read the details again after a change, and show them.
    fn reload_details(self: &Rc<Self>) {
        self.details.replace(None);
        self.load_details();
        // Immich writes a new date or place a moment after it answers, and names the place then: read it again.
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(2500), move || {
            if let Some(state) = weak.upgrade() {
                state.details.replace(None);
                state.load_details();
            }
        });
    }

    fn load_details(self: &Rc<Self>) {
        let Some(tile) = self.tile() else { return };
        if self.details.borrow().as_ref().is_some_and(|details| details.id == tile.id) {
            return;
        }
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let client = session.connection.client.clone();
        let shown = self.shown.get();
        let weak = Rc::downgrade(self);
        let id = tile.id.clone();
        crate::tasks::run(
            async move {
                let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let filter = immich_api::AlbumFilter { containing_asset: Some(id.clone()), ..immich_api::AlbumFilter::default() };
                let albums = client.albums_where(&filter).await.unwrap_or_default();
                Ok::<_, String>((details, albums))
            },
            move |outcome| {
                let Some(state) = weak.upgrade() else { return };
                if state.shown.get() != shown {
                    return;
                }
                match outcome {
                    Ok((details, albums)) => {
                        while let Some(child) = state.details_box.first_child() {
                            state.details_box.remove(&child);
                        }
                        for group in state.info(&details, &albums) {
                            state.details_box.append(&group);
                        }
                        state.details.replace(Some(details));
                    }
                    Err(message) => {
                        if let Some(window) = state.window.upgrade() {
                            window.toast(&message);
                        }
                    }
                }
            },
        );
    }

    /// Down to the details below the photo, or back up to the photo.
    pub(crate) fn toggle_details(&self) {
        let adjustment = self.page_scroller.vadjustment();
        let photo_height = adjustment.page_size();
        let target = if adjustment.value() < photo_height / 2.0 { photo_height.min(adjustment.upper() - adjustment.page_size()) } else { 0.0 };
        self.scroll_page_to(target);
    }

    /// Down (1) from the photo to its details' top, then on through them a part of a page at a time; Up (-1) back
    /// through them to their top, then to the photo.
    fn scroll_page(&self, by: i32) {
        let adjustment = self.page_scroller.vadjustment();
        let (now, photo_height) = (adjustment.value(), adjustment.page_size());
        let last = (adjustment.upper() - adjustment.page_size()).max(0.0);
        let step = photo_height * 0.4;
        let target = match by {
            1 if now < photo_height - 1.0 => photo_height,
            1 => now + step,
            _ if now > photo_height + 1.0 => (now - step).max(photo_height),
            _ => 0.0,
        };
        self.scroll_page_to(target.clamp(0.0, last));
    }

    fn scroll_page_to(&self, target: f64) {
        let adjustment = self.page_scroller.vadjustment();
        let animation = adw::TimedAnimation::builder().widget(&self.page_scroller).value_from(adjustment.value()).value_to(target).duration(300).target(&adw::PropertyAnimationTarget::new(&adjustment, "value")).build();
        animation.play();
    }

    /// The details of a photo read whole, as groups.
    fn info(self: &Rc<Self>, details: &AssetDetails, albums: &[immich_api::Album]) -> Vec<adw::PreferencesGroup> {
        let Some(window) = self.window.upgrade() else { return Vec::new() };
        let weak = Rc::downgrade(self);
        crate::info::info_groups(&window, details, albums, true, Rc::new(move || {
            if let Some(state) = weak.upgrade() {
                state.reload_details();
            }
        }))
    }
}

/// The picture turned by quarter turns clockwise, for the view alone.
fn turned(texture: &gdk::Texture, quarter_turns: i32) -> gdk::Texture {
    let mut downloader = gdk::TextureDownloader::new(texture);
    downloader.set_format(gdk::MemoryFormat::R8g8b8a8);
    let (bytes, stride) = downloader.download_bytes();
    let (width, height) = (texture.width() as usize, texture.height() as usize);
    let (pixels, new_width, new_height) = presentation::rotate_rgba(&bytes, width, height, stride, quarter_turns);
    gdk::MemoryTexture::new(new_width as i32, new_height as i32, gdk::MemoryFormat::R8g8b8a8, &glib::Bytes::from_owned(pixels), new_width * 4).upcast()
}

fn texture_is_none(state: &State) -> bool {
    state.texture.borrow().is_none()
}

/// Move the photo `id` out of this view (`name`: trash, restore, delete-forever, archive, lock, unlock), asking first
/// where that cannot be undone at once, then take that photo out of the view.
fn leave(state: &Rc<State>, window: &Window, id: String, name: &'static str) {
    let Some(session) = window.session() else { return };
    let client = session.connection.client.clone();
    let weak = Rc::downgrade(state);
    let archived = state.kind == Kind::Archive;
    let run = move || {
        let (client, id, weak) = (client.clone(), id.clone(), weak.clone());
        let acted_on = id.clone();
        crate::tasks::run(
            async move {
                match name {
                    "trash" => actions::trash(&client, vec![id]).await.map(|()| tr("Moved to the trash").to_owned()),
                    "restore" => actions::restore(&client, vec![id]).await.map(|_| tr("Restored").to_owned()),
                    "delete-forever" => actions::delete_forever(&client, vec![id]).await.map(|()| tr("Deleted for good").to_owned()),
                    "archive" => actions::set_archived(&client, vec![id], !archived).await.map(|()| if archived { tr("Unarchived") } else { tr("Archived") }.to_owned()),
                    "unlock" => actions::set_locked(&client, vec![id], false).await.map(|()| tr("Moved out of the Locked Folder").to_owned()),
                    _ => actions::set_locked(&client, vec![id], true).await.map(|()| tr("Moved to the Locked Folder").to_owned()),
                }
            },
            move |outcome| {
                let Some(state) = weak.upgrade() else { return };
                let Some(window) = state.window.upgrade() else { return };
                match outcome {
                    Ok(message) => {
                        window.toast(&message);
                        state.drop_photo(&acted_on);
                    }
                    Err(message) => window.toast(&message),
                }
            },
        );
    };
    match name {
        "trash" => crate::dialogs::confirm(window, tr("Move to Trash?"), tr("It goes to Recently Deleted, where it can be restored until the trash is emptied."), tr("Move to Trash"), true, run),
        "delete-forever" => crate::dialogs::confirm(window, tr("Delete Forever?"), tr("It is deleted from Immich for good. This cannot be undone."), tr("Delete Forever"), true, run),
        "lock" => crate::dialogs::confirm(window, tr("Move to the Locked Folder?"), tr("It leaves the library, albums and searches, and shows only in the Locked Folder, opened with your PIN code."), tr("Move"), false, run),
        _ => run(),
    }
}

fn install_gestures(state: &Rc<State>) {
    // Ctrl+scroll zooms; a plain scroll pans when zoomed.
    // A touchpad's sideways swipe moves the photo with the fingers, onto the next or back (`motion`); not zoomed in,
    // where it pans.
    let swipe = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::HORIZONTAL | gtk::EventControllerScrollFlags::KINETIC);
    let weak = Rc::downgrade(state);
    swipe.connect_scroll_begin(move |_| {
        if let Some(state) = weak.upgrade() {
            state.swipe_begin();
        }
    });
    let weak = Rc::downgrade(state);
    swipe.connect_scroll(move |controller, dx, _| {
        let fingers = controller.unit() == gdk::ScrollUnit::Surface;
        match weak.upgrade() {
            Some(state) if fingers && state.swipe_by(dx) => glib::Propagation::Stop,
            _ => glib::Propagation::Proceed,
        }
    });
    let weak = Rc::downgrade(state);
    swipe.connect_decelerate(move |_, velocity, _| {
        if let Some(state) = weak.upgrade() {
            if let Some(swipe) = state.swipe.borrow_mut().as_mut() {
                swipe.velocity = velocity;
            }
        }
    });
    // Decided once the fingers' speed is in: GTK reports it next to the swipe's end.
    let weak = Rc::downgrade(state);
    swipe.connect_scroll_end(move |_| {
        let weak = weak.clone();
        glib::idle_add_local_once(move || {
            if let Some(state) = weak.upgrade() {
                state.swipe_end();
            }
        });
    });
    state.scrolled.add_controller(swipe);
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
    let weak = Rc::downgrade(state);
    scroll.connect_scroll(move |controller, _, delta_y| {
        let Some(state) = weak.upgrade() else { return glib::Propagation::Proceed };
        if controller.current_event_state().contains(gdk::ModifierType::CONTROL_MASK) {
            state.zoom_by(if delta_y < 0.0 { 1.25 } else { 0.8 });
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    state.scrolled.add_controller(scroll);
    let pinch = gtk::GestureZoom::new();
    let weak = Rc::downgrade(state);
    pinch.connect_begin(move |_, _| {
        if let Some(state) = weak.upgrade() {
            state.zoom_at_gesture_start.set(if state.zoom.get() > 0.0 { state.zoom.get() } else { state.fit_zoom() });
        }
    });
    let weak = Rc::downgrade(state);
    pinch.connect_scale_changed(move |_, scale| {
        if let Some(state) = weak.upgrade() {
            state.set_zoom((state.zoom_at_gesture_start.get() * scale).clamp(0.05, MAX_ZOOM));
        }
    });
    state.scrolled.add_controller(pinch);
    // A double click zooms to the photo's own pixels, or back to fit.
    let double = gtk::GestureClick::new();
    let weak = Rc::downgrade(state);
    double.connect_pressed(move |_, presses, _, _| {
        if presses == 2 {
            if let Some(state) = weak.upgrade() {
                if state.zoom.get() > 0.0 {
                    state.set_zoom(0.0);
                } else {
                    state.set_zoom((state.fit_zoom() * 2.5).clamp(1.0, MAX_ZOOM));
                }
            }
        }
    });
    state.scrolled.add_controller(double);
    // Drag to pan a zoomed photo.
    let drag = gtk::GestureDrag::new();
    let start: Rc<Cell<(f64, f64)>> = Rc::default();
    let (weak, origin) = (Rc::downgrade(state), start.clone());
    drag.connect_drag_begin(move |_, _, _| {
        if let Some(state) = weak.upgrade() {
            origin.set((state.scrolled.hadjustment().value(), state.scrolled.vadjustment().value()));
        }
    });
    let weak = Rc::downgrade(state);
    drag.connect_drag_update(move |_, offset_x, offset_y| {
        if let Some(state) = weak.upgrade() {
            if state.zoom.get() > 0.0 {
                let (x, y) = start.get();
                state.scrolled.hadjustment().set_value(x - offset_x);
                state.scrolled.vadjustment().set_value(y - offset_y);
            }
        }
    });
    state.scrolled.add_controller(drag);
}

fn install_actions(page: &adw::NavigationPage, state: &Rc<State>) {
    let group = gio::SimpleActionGroup::new();
    let add = |name: &str, run: fn(&Rc<State>, &Window, Tile)| {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(state);
        action.connect_activate(move |_, _| {
            let Some(state) = weak.upgrade() else { return };
            let (Some(window), Some(tile)) = (state.window.upgrade(), state.tile()) else { return };
            run(&state, &window, tile);
        });
        group.add_action(&action);
    };
    add("download", |_, window, tile| window.download(vec![tile.id]));
    add("copy", |state, _, _| state.copy_image());
    add("copy-original", |state, _, _| state.copy_original(false));
    add("copy-file", |state, _, _| state.copy_original(true));
    add("slideshow", |state, _, _| crate::slideshow::start(state, true));
    add("full-screen", |state, _, _| crate::slideshow::start(state, false));
    add("view-left", |state, _, _| state.turn_view(-1));
    add("view-right", |state, _, _| state.turn_view(1));
    add("show-in-library", |state, window, tile| {
        crate::slideshow::stop(state);
        window.close_viewer();
        window.show_in_library(&tile);
    });
    add("faces", |state, window, tile| {
        let weak = Rc::downgrade(state);
        crate::faces::manage_faces(
            window,
            &tile.id,
            Rc::new(move || {
                if let Some(state) = weak.upgrade() {
                    state.load_faces();
                }
            }),
        );
    });
    let looping = gio::SimpleAction::new_stateful("loop", None, &(settings::shared().get("viewer.videoLoop").as_deref() == Some("true")).to_variant());
    let weak = Rc::downgrade(state);
    looping.connect_change_state(move |action, value| {
        let Some(on) = value.and_then(|value| value.get::<bool>()) else { return };
        action.set_state(&on.to_variant());
        settings::shared().set("viewer.videoLoop", on.then_some("true"));
        if let Some(stream) = weak.upgrade().and_then(|state| state.video.media_stream()) {
            stream.set_loop(on);
        }
    });
    group.add_action(&looping);
    add("open-with", |state, window, tile| window.open_with(&tile.id, state.kind.within()));
    // Show in *app*: the participant's id as the target.
    let show_in = gio::SimpleAction::new("show-in", Some(glib::VariantTy::STRING));
    let weak = Rc::downgrade(state);
    show_in.connect_activate(move |_, target| {
        let Some(state) = weak.upgrade() else { return };
        let (Some(window), Some(tile), Some(app)) = (state.window.upgrade(), state.tile(), target.and_then(|target| target.get::<String>())) else { return };
        window.show_in(&app, &tile.id, state.kind.within());
    });
    group.add_action(&show_in);
    add("open-in-immich", |state, window, tile| window.open_in_immich(&tile.id, state.kind.within()));
    add("copy-link", |state, window, tile| window.copy_link(&tile.id, state.kind.within()));
    add("add-to-album", |_, window, tile| crate::pages::add_to_album(window, vec![tile.id], None));
    add("activity", |state, window, tile| {
        if let Some(album_id) = state.kind.album_id() {
            crate::activity::activity_dialog(window, album_id, Some(tile.id));
        }
    });
    add("cover", |state, window, tile| {
        let Some(album_id) = state.kind.album_id().map(str::to_owned) else { return };
        let Some(session) = window.session() else { return };
        let client = session.connection.client.clone();
        let weak_window = window.downgrade();
        crate::tasks::run(async move { actions::set_album_cover(&client, album_id, tile.id).await }, move |outcome| {
            if let Some(window) = weak_window.upgrade() {
                window.toast(&outcome.map(|()| tr("Album cover changed").to_owned()).unwrap_or_else(|message| message));
                window.refresh_albums();
            }
        });
    });
    for (name, quarter_turns) in [("rotate-left", -1), ("rotate-right", 1)] {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(state);
        action.connect_activate(move |_, _| {
            if let Some(state) = weak.upgrade() {
                state.rotate(quarter_turns);
            }
        });
        group.add_action(&action);
    }
    let crop = gio::SimpleAction::new("crop", None);
    let weak = Rc::downgrade(state);
    crop.connect_activate(move |_, _| {
        let Some(state) = weak.upgrade() else { return };
        let (Some(window), Some(tile)) = (state.window.upgrade(), state.tile()) else { return };
        let (weak, id) = (Rc::downgrade(&state), tile.id.clone());
        crate::crop::crop_dialog(&window, &tile.id, move || {
            if let Some(state) = weak.upgrade() {
                state.cropped(id.clone());
            }
        });
    });
    group.add_action(&crop);
    for name in ["trash", "restore", "delete-forever", "archive", "lock", "unlock"] {
        let action = gio::SimpleAction::new(name, None);
        let weak = Rc::downgrade(state);
        action.connect_activate(move |_, _| {
            let Some(state) = weak.upgrade() else { return };
            let (Some(window), Some(tile)) = (state.window.upgrade(), state.tile()) else { return };
            if matches!(name, "lock" | "unlock") && window.session().is_some_and(|session| session.connection.with_api_key) {
                return window.toast(tr("The Locked Folder needs a sign-in with a password or single sign-on."));
            }
            leave(&state, &window, tile.id, name);
        });
        group.add_action(&action);
    }
    page.insert_action_group("viewer", Some(&group));
}
