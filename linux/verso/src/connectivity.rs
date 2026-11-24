//! Whether the Immich server can be reached, as the window sees it (ARCHITECTURE.md, "When the server cannot
//! be reached"). While it cannot, the client is told (`Client::set_reachable`), so requests fail at once rather than
//! wait out their timeouts and those waiting give up; a banner under each page's header says so, with Try Now; and
//! what failed to load in the meantime loads again once the server answers.
//!
//! The server is asked (`Client::ping`) when something suggests it went away or came back: a request failing because
//! it could not be reached, a request waiting long (a network dropped without a word), a change of network (GLib's
//! network monitor), the service's own state changing (`StateChanged` on its D-Bus interface), and Try Now; while it
//! cannot be reached, every few seconds.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::Client;
use verso_linux::i18n::tr;

/// How often the window looks at its requests.
const TICK: Duration = Duration::from_secs(2);
/// How often the server is asked while it cannot be reached, or while a request waits long.
const RETRY: Duration = Duration::from_secs(10);
/// How long a request may wait for its answer before the server is asked whether it is still there.
const SLOW: Duration = Duration::from_secs(12);
/// How long after a change of network the server is asked once more: the first ask can come before the new network's
/// addresses and names are ready.
const SETTLE: Duration = Duration::from_secs(3);
/// The shortest time between two "not possible" toasts, so a burst of failures shows one.
const TOAST_GAP: Duration = Duration::from_secs(5);

/// When to ask the server, from what the window knows: kept apart from GTK so it can be tested.
#[derive(Debug, Default)]
struct Asking {
    /// When it was last asked.
    last: Option<Instant>,
    /// An answer is awaited.
    waiting: bool,
}

impl Asking {
    /// Whether a tick asks the server: while it cannot be reached, every [`RETRY`]; while it can, when a request has
    /// waited [`SLOW`], at most every [`RETRY`].
    fn on_tick(&self, reachable: bool, longest_wait: Option<Duration>, now: Instant) -> bool {
        let due = self.last.is_none_or(|last| now.duration_since(last) >= RETRY);
        !self.waiting && due && (!reachable || longest_wait.is_some_and(|waited| waited >= SLOW))
    }
}

pub struct Connectivity {
    client: Client,
    host: String,
    reachable: Cell<bool>,
    asking: RefCell<Asking>,
    /// Something failed to load because the server could not be reached: it loads again when the server is back.
    missed: Cell<bool>,
    last_toast: Cell<Option<Instant>>,
    /// What to do when the server is back after something was missed: the window reads its page again.
    back: RefCell<Option<Box<dyn Fn()>>>,
    banners: RefCell<Vec<glib::WeakRef<adw::Banner>>>,
    /// The pages that have their banner.
    pages: RefCell<Vec<glib::WeakRef<adw::NavigationPage>>>,
    bus: Option<gio::DBusConnection>,
    tick: RefCell<Option<glib::SourceId>>,
    network: RefCell<Option<glib::SignalHandlerId>>,
    service: RefCell<Option<gio::SignalSubscription>>,
}

impl Connectivity {
    /// Watch the server `client` talks to; `back` runs when it answers again after something failed to load.
    pub fn new(client: Client, back: impl Fn() + 'static) -> Rc<Connectivity> {
        client.set_reachable(true);
        let connectivity = Rc::new(Connectivity {
            host: client.api_url().host_str().unwrap_or_default().to_owned(),
            client,
            reachable: Cell::new(true),
            asking: RefCell::default(),
            missed: Cell::new(false),
            last_toast: Cell::new(None),
            back: RefCell::new(Some(Box::new(back))),
            banners: RefCell::default(),
            pages: RefCell::default(),
            bus: gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE).ok(),
            tick: RefCell::default(),
            network: RefCell::default(),
            service: RefCell::default(),
        });
        let weak = Rc::downgrade(&connectivity);
        let tick = glib::timeout_add_local(TICK, move || {
            let Some(connectivity) = weak.upgrade() else { return glib::ControlFlow::Break };
            connectivity.tick();
            glib::ControlFlow::Continue
        });
        connectivity.tick.replace(Some(tick));
        let weak = Rc::downgrade(&connectivity);
        let network = gio::NetworkMonitor::default().connect_network_changed(move |_, _| {
            if let Some(connectivity) = weak.upgrade() {
                connectivity.network_changed();
            }
        });
        connectivity.network.replace(Some(network));
        // The service polls the server too, and its state changing is a reason to ask.
        if let Some(bus) = &connectivity.bus {
            let weak = Rc::downgrade(&connectivity);
            let service = bus.subscribe_to_signal(
                Some(&verso_linux::dbus::bus_name()),
                Some(verso_linux::dbus::INTERFACE),
                Some("StateChanged"),
                Some(verso_linux::dbus::OBJECT_PATH),
                None,
                gio::DBusSignalFlags::NONE,
                move |_| {
                    if let Some(connectivity) = weak.upgrade() {
                        connectivity.ask();
                    }
                },
            );
            connectivity.service.replace(Some(service));
        }
        connectivity
    }

    pub fn is_reachable(&self) -> bool {
        self.reachable.get()
    }

    fn tick(self: &Rc<Self>) {
        let ask = self.asking.borrow().on_tick(self.reachable.get(), self.client.longest_wait(), Instant::now());
        if ask {
            self.ask();
        }
    }

    /// Ask the server whether it answers, unless an answer is awaited already.
    pub fn ask(self: &Rc<Self>) {
        {
            let mut asking = self.asking.borrow_mut();
            if asking.waiting {
                return;
            }
            asking.waiting = true;
            asking.last = Some(Instant::now());
        }
        let client = self.client.clone();
        let weak = Rc::downgrade(self);
        crate::tasks::run(async move { client.ping().await.is_ok() }, move |answered| {
            if let Some(connectivity) = weak.upgrade() {
                connectivity.asking.borrow_mut().waiting = false;
                connectivity.answered(answered);
            }
        });
    }

    fn answered(&self, reachable: bool) {
        let was = self.reachable.replace(reachable);
        if was == reachable {
            // A failure while the server answers was a moment's: the page that failed says so, with Try Again.
            if reachable {
                self.missed.set(false);
            }
            return;
        }
        eprintln!("{} {}", self.host, if reachable { "answers again" } else { "cannot be reached" });
        self.client.set_reachable(reachable);
        self.banners.borrow_mut().retain(|banner| banner.upgrade().is_some());
        for banner in self.banners.borrow().iter().filter_map(glib::WeakRef::upgrade) {
            banner.set_revealed(!reachable);
        }
        if reachable && self.missed.replace(false) {
            if let Some(back) = self.back.borrow().as_ref() {
                back();
            }
        }
    }

    /// A change of network: ask now, and once more when it has settled.
    fn network_changed(self: &Rc<Self>) {
        self.ask();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(SETTLE, move || {
            if let Some(connectivity) = weak.upgrade() {
                connectivity.ask();
            }
        });
    }

    /// Something failed because the server could not be reached: ask it, and read again what failed once it answers.
    pub fn failed(self: &Rc<Self>) {
        self.missed.set(true);
        self.ask();
    }

    /// What a toast says for a failure because the server could not be reached; `None` when one said it moments ago.
    pub fn unreachable_toast(&self) -> Option<String> {
        let now = Instant::now();
        if self.last_toast.get().is_some_and(|last| now.duration_since(last) < TOAST_GAP) {
            return None;
        }
        self.last_toast.set(Some(now));
        Some(tr("Not possible while {host} is not reachable").replace("{host}", &self.host))
    }

    /// Try Now: ask the server, and have the service ask too, so the top bar follows at once.
    pub fn try_now(self: &Rc<Self>) {
        self.ask();
        if let Some(bus) = &self.bus {
            bus.call(
                Some(&verso_linux::dbus::bus_name()),
                verso_linux::dbus::OBJECT_PATH,
                verso_linux::dbus::INTERFACE,
                "CheckNow",
                None,
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                2000,
                gio::Cancellable::NONE,
                |_| {},
            );
        }
    }

    /// Put the banner under the header of `page`, once: every page of the window has its own, all following the
    /// server's state.
    pub fn attach(self: &Rc<Self>, page: &adw::NavigationPage) {
        {
            let mut pages = self.pages.borrow_mut();
            pages.retain(|shown| shown.upgrade().is_some());
            if pages.iter().any(|shown| shown.upgrade().as_ref() == Some(page)) {
                return;
            }
            pages.push(page.downgrade());
        }
        let Some(toolbar) = toolbar_of(page.upcast_ref()) else { return };
        let banner = adw::Banner::builder()
            .title(tr("{host} is not reachable. Verso keeps trying.").replace("{host}", &self.host))
            .button_label(tr("Try Now"))
            .revealed(!self.reachable.get())
            .build();
        let weak = Rc::downgrade(self);
        banner.connect_button_clicked(move |_| {
            if let Some(connectivity) = weak.upgrade() {
                connectivity.try_now();
            }
        });
        toolbar.add_top_bar(&banner);
        self.banners.borrow_mut().push(banner.downgrade());
    }
}

impl Drop for Connectivity {
    fn drop(&mut self) {
        if let Some(tick) = self.tick.take() {
            tick.remove();
        }
        if let Some(network) = self.network.take() {
            gio::NetworkMonitor::default().disconnect(network);
        }
        self.client.set_reachable(true);
        for banner in self.banners.borrow().iter().filter_map(glib::WeakRef::upgrade) {
            banner.set_revealed(false);
        }
    }
}

/// The page's own toolbar view: its child, or the first one inside it.
fn toolbar_of(widget: &gtk::Widget) -> Option<adw::ToolbarView> {
    let mut level = vec![widget.first_child()?];
    for _ in 0..4 {
        let mut next = Vec::new();
        for first in level {
            let mut child = Some(first);
            while let Some(widget) = child {
                if let Ok(toolbar) = widget.clone().downcast::<adw::ToolbarView>() {
                    return Some(toolbar);
                }
                if let Some(inner) = widget.first_child() {
                    next.push(inner);
                }
                child = widget.next_sibling();
            }
        }
        level = next;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_server_is_asked_while_it_cannot_be_reached_and_when_a_request_waits_long() {
        let start = Instant::now();
        let never = Asking::default();
        assert!(never.on_tick(false, None, start), "unreachable, never asked: ask");
        assert!(!never.on_tick(true, None, start), "reachable, nothing waiting: leave it");
        assert!(!never.on_tick(true, Some(Duration::from_secs(3)), start), "a request waiting a moment");
        assert!(never.on_tick(true, Some(SLOW), start), "a request waiting long");
        let asked = Asking { last: Some(start), waiting: false };
        assert!(!asked.on_tick(false, None, start + Duration::from_secs(4)), "not again at once");
        assert!(asked.on_tick(false, None, start + RETRY), "again after a while");
        assert!(!asked.on_tick(true, Some(Duration::from_secs(30)), start + Duration::from_secs(4)), "a slow request asks at most every while");
        let awaiting = Asking { last: Some(start), waiting: true };
        assert!(!awaiting.on_tick(false, None, start + Duration::from_secs(60)), "one ask at a time");
    }
}
