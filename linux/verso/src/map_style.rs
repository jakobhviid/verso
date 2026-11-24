//! Every map in the window drawn from the Immich server's map setting (`verso_desktop::map_style`): the setting read
//! once a session, each look's style when a map first wants it, and its renderer shared by the maps; the map light or
//! dark as libadwaita's style is, with its credits at its foot, and a plain message on it when it cannot be drawn.
//! Markers stay where they are through all of it: the viewport always has a source to place them by. The map's tiles
//! are a layer of Verso's own at the bottom, rather than the simple map's base layer, so a map can lose them again.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use shumate::prelude::*;
use verso_desktop::map;
use verso_desktop::map_style::{self, Look, MapStyle, StyleError};
use verso_linux::i18n::tr;

/// The tile size of a vector style, which libshumate takes for every one (the style specification's).
const TILE_SIZE: u32 = 512;
/// The zoom levels a map offers: libshumate draws a vector style's last tiles larger up to 18.
const ZOOM: (u32, u32) = (0, 18);

/// A look's map, ready to draw, or what the map says in its place.
type Drawn = Result<Rc<Drawable>, String>;

/// A style's renderer, which every map of the session in that look draws from, and what the map shows with it.
pub struct Drawable {
    renderer: shumate::VectorRenderer,
    credits: String,
    tiles_host: String,
}

/// What a map does with its look's style once it is read.
type Then = Box<dyn FnOnce(&Drawn)>;

enum Loading {
    /// Being read; these maps want it once it is.
    Waiting(Vec<Then>),
    Done(Drawn),
}

/// What the session's maps draw from.
pub struct Styles {
    client: immich_api::Client,
    /// The server's map setting, once read.
    setting: RefCell<Option<immich_api::ServerConfig>>,
    looks: RefCell<HashMap<Look, Loading>>,
}

impl Styles {
    pub fn new(client: immich_api::Client) -> Rc<Styles> {
        Rc::new(Styles { client, setting: RefCell::default(), looks: RefCell::default() })
    }

    /// The look's map, at once when it is read, or once it is. A failure is tried again by the next map that asks.
    fn with(self: &Rc<Self>, look: Look, then: impl FnOnce(&Drawn) + 'static) {
        let mut looks = self.looks.borrow_mut();
        match looks.get_mut(&look) {
            Some(Loading::Done(Ok(drawable))) => {
                let drawn = Ok(drawable.clone());
                drop(looks);
                then(&drawn);
            }
            Some(Loading::Waiting(waiting)) => waiting.push(Box::new(then)),
            _ => {
                looks.insert(look, Loading::Waiting(vec![Box::new(then)]));
                drop(looks);
                self.load(look);
            }
        }
    }

    fn load(self: &Rc<Self>, look: Look) {
        let (client, known) = (self.client.clone(), self.setting.borrow().clone());
        let weak = Rc::downgrade(self);
        crate::tasks::run(
            async move {
                let setting = match known {
                    Some(setting) => setting,
                    None => match client.server_config().await {
                        Ok(setting) => setting,
                        Err(error) => return (None, Err(StyleError::Setting(verso_desktop::errors::said(&error)))),
                    },
                };
                let style = map_style::load(look.address(&setting)).await;
                (Some(setting), style)
            },
            move |(setting, style)| {
                let Some(styles) = weak.upgrade() else { return };
                let host = setting.as_ref().map(|setting| host_of(look.address(setting))).unwrap_or_default();
                if let Some(setting) = setting {
                    styles.setting.replace(Some(setting));
                }
                let drawn: Drawn = match style {
                    Ok(style) => drawable(look, &style).map(Rc::new).map_err(|reason| StyleError::Unsupported { host, reason }.said()),
                    Err(error) => Err(error.said()),
                };
                let waiting = match styles.looks.borrow_mut().insert(look, Loading::Done(drawn.clone())) {
                    Some(Loading::Waiting(waiting)) => waiting,
                    _ => Vec::new(),
                };
                for then in waiting {
                    then(&drawn);
                }
            },
        );
    }
}

/// The host in a style's address, as a message names it.
fn host_of(address: &str) -> String {
    let rest = address.split_once("://").map_or(address, |(_, rest)| rest);
    rest.split(['/', '?', '#']).next().unwrap_or(rest).to_owned()
}

/// The renderer for a style. A layer libshumate refuses (an expression it does not know) is left out and the rest
/// drawn; a style it refuses as a whole says why.
fn drawable(look: Look, style: &MapStyle) -> Result<Drawable, String> {
    let id = match look {
        Look::Light => "immich-light",
        Look::Dark => "immich-dark",
    };
    let mut json = style.json.clone();
    let renderer = loop {
        match shumate::VectorRenderer::new(id, &json) {
            Ok(renderer) => break renderer,
            Err(error) => match map_style::refused_layer(error.message()).and_then(|layer| map_style::without_layer(&json, layer)) {
                Some(fewer) => json = fewer,
                None => return Err(error.message().to_owned()),
            },
        }
    };
    if !style.sprites.is_empty() {
        let sheet = shumate::VectorSpriteSheet::new();
        for page in &style.sprites {
            if let Ok(texture) = gdk::Texture::from_bytes(&glib::Bytes::from(&page.picture)) {
                let _ = sheet.add_page(&texture, &page.index, page.scale);
            }
        }
        renderer.set_sprite_sheet(&sheet);
    }
    Ok(Drawable { renderer, credits: style.credits.clone(), tiles_host: style.tiles_host.clone() })
}

/// The size of the tiles the map is laid out in, for its arithmetic (`verso_desktop::map`).
pub fn tile_size(viewport: &shumate::Viewport) -> f64 {
    f64::from(viewport.reference_map_source().map_or(TILE_SIZE, |source| source.tile_size()))
}

/// The zoom level at which a map of vector tiles shows what one of 256 pixel tiles shows at `raster_zoom`, the scale
/// web maps' zoom levels are usually given in.
pub fn zoom(raster_zoom: f64) -> f64 {
    raster_zoom - (f64::from(TILE_SIZE) / 256.0).log2()
}

/// `simple` drawn from the server's map setting: the map in an overlay with its credits and its messages, which is
/// what to show. `compact` is a small map, whose message is a line rather than a page.
pub fn styled(window: &crate::window::Window, simple: &shumate::SimpleMap, compact: bool) -> gtk::Overlay {
    // Until the style is drawn, and when it cannot be, the map is laid out by a source of no tiles, which no layer
    // draws: markers stand by it, on the plain view.
    let empty = NoTiles::new();
    if let Some(map) = simple.map() {
        map.set_map_source(&empty);
    }
    if let Some(license) = simple.license() {
        license.set_visible(false);
    }
    let credits = gtk::Label::builder().use_markup(true).wrap(true).xalign(1.0).halign(gtk::Align::End).valign(gtk::Align::End).css_classes(["gallery-map-credits"]).visible(false).build();
    // A line along the map's top, above its pin: the small map's message, and the tiles that could not be loaded.
    let line = || {
        gtk::Label::builder()
            .wrap(true)
            .justify(gtk::Justification::Center)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Start)
            .margin_top(12)
            .margin_start(18)
            .margin_end(18)
            .max_width_chars(52)
            .css_classes(["gallery-map-status", "caption"])
            .visible(false)
            .build()
    };
    let (status, trouble) = (line(), line());
    let page = adw::StatusPage::builder().icon_name("find-location-symbolic").title(tr("Map Unavailable")).css_classes(["compact"]).visible(false).build();
    // The messages are words over the map: clicks go through them to the map and its markers.
    for message in [status.upcast_ref::<gtk::Widget>(), page.upcast_ref(), trouble.upcast_ref()] {
        message.set_can_target(false);
    }
    let overlay = gtk::Overlay::builder().child(simple).build();
    let message: &gtk::Widget = if compact { status.upcast_ref() } else { page.upcast_ref() };
    for child in [credits.upcast_ref::<gtk::Widget>(), message, trouble.upcast_ref()] {
        overlay.add_overlay(child);
        overlay.set_clip_overlay(child, true);
    }
    let Some(session) = window.session() else { return overlay };
    let shown = Rc::new(Shown { simple: simple.downgrade(), empty, tiles: RefCell::default(), credits, status, page, trouble, compact, wanted: Cell::new(None), moved: Cell::new(0), failed: RefCell::default() });
    if let Some(viewport) = simple.viewport() {
        for property in ["zoom-level", "latitude", "longitude"] {
            let weak = Rc::downgrade(&shown);
            viewport.connect_notify_local(Some(property), move |_, _| {
                if let Some(shown) = weak.upgrade() {
                    shown.settle_soon();
                }
            });
        }
    }
    let styles = session.maps.clone();
    let follow = {
        let (weak, styles) = (Rc::downgrade(&shown), Rc::downgrade(&styles));
        move |dark: bool| {
            let (Some(shown), Some(styles)) = (weak.upgrade(), styles.upgrade()) else { return };
            let look = Look::of(dark);
            if shown.wanted.replace(Some(look)) == Some(look) {
                return;
            }
            let weak = Rc::downgrade(&shown);
            styles.with(look, move |drawn| {
                if let Some(shown) = weak.upgrade().filter(|shown| shown.wanted.get() == Some(look)) {
                    shown.show(drawn);
                }
            });
        }
    };
    let manager = adw::StyleManager::default();
    follow(manager.is_dark());
    let following = manager.connect_dark_notify(move |manager| follow(manager.is_dark()));
    // The map owns its parts, whose callbacks hold them weakly; the style manager outlives the map, and its handler
    // goes with the map.
    let owned = RefCell::new(Some((shown, following)));
    overlay.connect_destroy(move |_| {
        if let Some((_, following)) = owned.take() {
            adw::StyleManager::default().disconnect(following);
        }
    });
    overlay
}

/// A styled map's parts, which its look changes.
struct Shown {
    simple: glib::WeakRef<shumate::SimpleMap>,
    empty: NoTiles,
    /// The layer drawing the style's tiles, when it is drawn.
    tiles: RefCell<Option<shumate::MapLayer>>,
    credits: gtk::Label,
    /// The small map's message.
    status: gtk::Label,
    /// The large map's message.
    page: adw::StatusPage,
    /// Tiles that could not be loaded, along the map's top.
    trouble: gtk::Label,
    compact: bool,
    wanted: Cell<Option<Look>>,
    /// Bumps with each move, so only the last of a quick run of moves settles the tiles.
    moved: Cell<u64>,
    /// The tiles in view that could not be loaded. libshumate asks for a failed tile again only once it has left the
    /// view and come back, so the message about them stays while one is in view.
    failed: RefCell<Vec<map::TilePosition>>,
}

impl Shown {
    /// Once the map comes to rest: look for the view's tiles again, and keep the message about failed tiles only
    /// while one of them is in view. libshumate's map layer (1.6) holds back loading while the view jumps, and looks
    /// again on the next frame; a map placed as it is shown (a photo's place, Assign Location's start) could be left
    /// without tiles until it moved again, so the layer is laid out once more.
    fn settle_soon(self: &Rc<Self>) {
        let moved = self.moved.get() + 1;
        self.moved.set(moved);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
            let Some(shown) = weak.upgrade().filter(|shown| shown.moved.get() == moved) else { return };
            let Some(simple) = shown.simple.upgrade() else { return };
            if let (Some(map_widget), Some(viewport)) = (simple.map(), simple.viewport()) {
                let in_view = map::tiles_in_view(
                    viewport.latitude(),
                    viewport.longitude(),
                    viewport.zoom_level(),
                    f64::from(map_widget.width()),
                    f64::from(map_widget.height()),
                    tile_size(&viewport),
                );
                let mut failed = shown.failed.borrow_mut();
                failed.retain(|tile| in_view.contains(tile));
                shown.trouble.set_visible(!failed.is_empty());
            }
            let tiles = shown.tiles.borrow().clone();
            if let Some(tiles) = tiles {
                tiles.queue_allocate();
            }
        });
    }

    fn show(self: &Rc<Self>, drawn: &Drawn) {
        let (Some(map), Some(viewport)) = (self.simple.upgrade().and_then(|simple| simple.map()), self.simple.upgrade().and_then(|simple| simple.viewport())) else { return };
        self.trouble.set_visible(false);
        self.failed.borrow_mut().clear();
        if let Some(earlier) = self.tiles.take() {
            map.remove_layer(&earlier);
        }
        match drawn {
            Ok(drawable) => {
                let layer = shumate::MapLayer::new(&drawable.renderer, &viewport);
                map.insert_layer_above(&layer, None::<&shumate::Layer>);
                map.set_map_source(&drawable.renderer);
                let (weak, host) = (Rc::downgrade(self), drawable.tiles_host.clone());
                layer.connect_tile_error(move |_, tile, error| {
                    let Some(shown) = weak.upgrade() else { return };
                    let position = (u64::from(tile.x()), u64::from(tile.y()), tile.zoom_level());
                    let mut failed = shown.failed.borrow_mut();
                    if !failed.contains(&position) {
                        failed.push(position);
                    }
                    shown.trouble.set_label(&map_style::tiles_failed(&host, error.message()));
                    shown.trouble.set_visible(true);
                });
                let weak = Rc::downgrade(self);
                layer.connect_map(move |_| {
                    if let Some(shown) = weak.upgrade() {
                        shown.settle_soon();
                    }
                });
                self.tiles.replace(Some(layer));
                self.credits.set_markup(&drawable.credits);
                self.credits.set_visible(!drawable.credits.is_empty());
                self.status.set_visible(false);
                self.page.set_visible(false);
                // A map already on screen gets its tiles with no move or map to settle them.
                self.settle_soon();
            }
            Err(message) => {
                map.set_map_source(&self.empty);
                self.credits.set_visible(false);
                if self.compact {
                    self.status.set_label(message);
                    self.status.set_visible(true);
                } else {
                    self.page.set_description(Some(&glib::markup_escape_text(message)));
                    self.page.set_visible(true);
                }
            }
        }
    }
}

mod imp {
    use super::*;
    use shumate::subclass::prelude::*;

    #[derive(Default)]
    pub struct NoTiles;

    #[glib::object_subclass]
    impl ObjectSubclass for NoTiles {
        const NAME: &'static str = "VersoNoTiles";
        type Type = super::NoTiles;
        type ParentType = shumate::MapSource;
    }

    impl ObjectImpl for NoTiles {}

    impl MapSourceImpl for NoTiles {
        /// Never asked: no layer draws this source, which only lays the map out.
        fn fill_tile_future(&self, _tile: &shumate::Tile) -> Pin<Box<dyn Future<Output = Result<(), glib::Error>> + 'static>> {
            Box::pin(std::future::ready(Err(glib::Error::new(gio::IOErrorEnum::Cancelled, "no tiles"))))
        }
    }
}

glib::wrapper! {
    /// A map source with no tiles, laid out as a vector style is, for a map whose style is not drawn. libshumate's
    /// Rust bindings finish a subclass's tile with no source object, which its map layer cannot take, so no layer is
    /// ever made of it.
    pub struct NoTiles(ObjectSubclass<imp::NoTiles>) @extends shumate::MapSource;
}

impl NoTiles {
    fn new() -> NoTiles {
        let source: NoTiles = glib::Object::builder().property("id", "no-tiles").build();
        source.set_tile_size(TILE_SIZE);
        source.set_min_zoom_level(ZOOM.0);
        source.set_max_zoom_level(ZOOM.1);
        source
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_messages_host_is_the_addresss() {
        assert_eq!(host_of("https://tiles.immich.cloud/v1/style/light.json"), "tiles.immich.cloud");
        assert_eq!(host_of("https://tiles.immich.cloud/v1/{z}/{x}/{y}.mvt?v=1"), "tiles.immich.cloud");
        assert_eq!(host_of("maps.example.org"), "maps.example.org");
    }

    #[test]
    fn a_vector_zoom_shows_what_a_raster_one_did() {
        assert_eq!(zoom(12.0), 11.0);
    }
}
