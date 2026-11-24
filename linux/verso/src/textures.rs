//! Pictures as GTK textures: thumbnails and previews from the account's disk cache, decoded off the main thread, the
//! most recent kept in memory; ThumbHash placeholders for what is still on its way.
//!
//! A list view binds far more rows than are on screen, so thumbnails wait in a queue served a few at a time, those on
//! screen first; one whose tile moved on to another photo is dropped before it is fetched. Previews, which the viewer
//! waits for, never queue behind thumbnails.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;

use gtk::{gdk, glib, prelude::*};
use verso_desktop::images::{Cache, Kind, Picture};

/// About 400 thumbnails stay decoded in memory (some 130 MB), a few screens of the grid.
const KEPT: usize = 400;
/// Previews are about forty thumbnails each (up to 11 MB decoded): the viewer keeps the few around the photo shown.
const KEPT_PREVIEWS: usize = 8;
/// Thumbnails fetched or read at once.
const AT_ONCE: usize = 8;

/// A picture: its kind, the photo's id, and its version (the photo's ThumbHash, where known).
type Key = (Kind, String, Option<String>);

/// How much a waiting picture is wanted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Wanted {
    /// Its tile shows something else now.
    No,
    /// Bound, but off screen.
    Later,
    /// On screen.
    Now,
}

struct Waiter {
    then: Box<dyn FnOnce(Option<gdk::Texture>)>,
    wanted: Box<dyn Fn() -> Wanted>,
}

pub struct Textures {
    cache: Cache,
    kept: RefCell<HashMap<Key, gdk::Texture>>,
    order: RefCell<VecDeque<Key>>,
    waiting: RefCell<HashMap<Key, Vec<Waiter>>>,
    queue: RefCell<Vec<Key>>,
    in_flight: Cell<usize>,
    placeholders: RefCell<HashMap<String, gdk::Texture>>,
}

pub fn texture(picture: Picture) -> gdk::Texture {
    let stride = picture.width as usize * 4;
    gdk::MemoryTexture::new(picture.width as i32, picture.height as i32, gdk::MemoryFormat::R8g8b8a8, &glib::Bytes::from_owned(picture.rgba), stride).upcast()
}

impl Textures {
    pub fn new(cache: Cache) -> Rc<Textures> {
        Rc::new(Textures {
            cache,
            kept: RefCell::default(),
            order: RefCell::default(),
            waiting: RefCell::default(),
            queue: RefCell::default(),
            in_flight: Cell::new(0),
            placeholders: RefCell::default(),
        })
    }

    pub fn cache(&self) -> &Cache {
        &self.cache
    }

    /// The texture if it is in memory now.
    pub fn cached(&self, kind: Kind, id: &str, version: Option<&str>) -> Option<gdk::Texture> {
        let key = (kind, id.to_owned(), version.map(str::to_owned));
        let texture = self.kept.borrow().get(&key).cloned()?;
        let mut order = self.order.borrow_mut();
        if let Some(position) = order.iter().position(|kept| *kept == key) {
            order.remove(position);
        }
        order.push_back(key);
        Some(texture)
    }

    /// The texture, now if kept, else once fetched and decoded; `None` when it cannot be had.
    pub fn get(self: &Rc<Self>, kind: Kind, id: &str, version: Option<&str>, then: impl FnOnce(Option<gdk::Texture>) + 'static) {
        self.get_while(kind, id, version, || Wanted::Now, then);
    }

    /// [`Textures::get`] for a tile: `wanted` says whether it is still wanted, and whether it is on screen.
    pub fn get_while(
        self: &Rc<Self>,
        kind: Kind,
        id: &str,
        version: Option<&str>,
        wanted: impl Fn() -> Wanted + 'static,
        then: impl FnOnce(Option<gdk::Texture>) + 'static,
    ) {
        if let Some(texture) = self.cached(kind, id, version) {
            return then(Some(texture));
        }
        let key = (kind, id.to_owned(), version.map(str::to_owned));
        let waiter = Waiter { then: Box::new(then), wanted: Box::new(wanted) };
        let mut waiting = self.waiting.borrow_mut();
        if let Some(waiters) = waiting.get_mut(&key) {
            waiters.push(waiter);
            return;
        }
        waiting.insert(key.clone(), vec![waiter]);
        drop(waiting);
        if kind == Kind::Preview {
            // The viewer is waiting for it: fetch it now.
            self.fetch(key, false);
        } else {
            self.queue.borrow_mut().push(key);
            self.pump_soon();
        }
    }

    /// Start more fetches once the main loop is idle, after the rows being bound now have asked for theirs.
    fn pump_soon(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(textures) = weak.upgrade() {
                textures.pump();
            }
        });
    }

    /// Start fetches while there is room: on-screen tiles first, in the order asked; drop what nobody wants now.
    fn pump(self: &Rc<Self>) {
        while self.in_flight.get() < AT_ONCE {
            let next = {
                let mut queue = self.queue.borrow_mut();
                let mut waiting = self.waiting.borrow_mut();
                let mut best: Option<(usize, Wanted)> = None;
                let mut dropped = Vec::new();
                for (position, key) in queue.iter().enumerate() {
                    let wanted = waiting.get(key).map_or(Wanted::No, |waiters| waiters.iter().map(|waiter| (waiter.wanted)()).max().unwrap_or(Wanted::No));
                    if wanted == Wanted::No {
                        dropped.push(position);
                        continue;
                    }
                    if best.is_none_or(|(_, best_wanted)| wanted > best_wanted) {
                        best = Some((position, wanted));
                        if wanted == Wanted::Now {
                            break;
                        }
                    }
                }
                let chosen = best.map(|(position, _)| queue[position].clone());
                for position in dropped.into_iter().rev() {
                    let key = queue.remove(position);
                    waiting.remove(&key);
                }
                if let Some(key) = &chosen {
                    queue.retain(|queued| queued != key);
                }
                chosen
            };
            let Some(key) = next else { return };
            self.fetch(key, true);
        }
    }

    fn fetch(self: &Rc<Self>, key: Key, counted: bool) {
        if counted {
            self.in_flight.set(self.in_flight.get() + 1);
        }
        let cache = self.cache.clone();
        let textures = Rc::downgrade(self);
        let (kind, id, version) = key.clone();
        crate::tasks::run(async move { cache.picture(kind, &id, version.as_deref(), None).await }, move |outcome| {
            let Some(textures) = textures.upgrade() else { return };
            if counted {
                textures.in_flight.set(textures.in_flight.get() - 1);
            }
            let texture = outcome.ok().map(texture);
            if let Some(texture) = &texture {
                textures.keep(key.clone(), texture.clone());
            }
            let waiters = textures.waiting.borrow_mut().remove(&key).unwrap_or_default();
            for waiter in waiters {
                (waiter.then)(texture.clone());
            }
            textures.pump();
        });
    }

    fn keep(&self, key: Key, texture: gdk::Texture) {
        let budget = if key.0 == Kind::Preview { KEPT_PREVIEWS } else { KEPT };
        let kind = key.0;
        self.kept.borrow_mut().insert(key.clone(), texture);
        let mut order = self.order.borrow_mut();
        order.push_back(key);
        let mut kept = self.kept.borrow_mut();
        // Each kind keeps its own budget: a preview is about forty thumbnails.
        while order.iter().filter(|(kept_kind, _, _)| *kept_kind == kind).count() > budget {
            let Some(position) = order.iter().position(|(kept_kind, _, _)| *kept_kind == kind) else { break };
            if let Some(oldest) = order.remove(position) {
                kept.remove(&oldest);
            }
        }
    }

    /// Forget a photo's pictures in memory, so they are read again (after it was turned, say).
    pub fn forget(&self, id: &str) {
        let mut kept = self.kept.borrow_mut();
        kept.retain(|(_, kept_id, _), _| kept_id != id);
        self.order.borrow_mut().retain(|(_, kept_id, _)| kept_id != id);
    }

    /// The blurred placeholder for a ThumbHash.
    pub fn placeholder(&self, hash: &str) -> Option<gdk::Texture> {
        if let Some(texture) = self.placeholders.borrow().get(hash) {
            return Some(texture.clone());
        }
        let texture = texture(verso_desktop::thumbhash::from_base64(hash)?);
        let mut placeholders = self.placeholders.borrow_mut();
        if placeholders.len() > 4000 {
            placeholders.clear();
        }
        placeholders.insert(hash.to_owned(), texture.clone());
        Some(texture)
    }
}
