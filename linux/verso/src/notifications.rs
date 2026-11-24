//! The notifications at the sidebar's foot, beside the account, as on the Mac: a bell, with how many are unread beside
//! it (GNOME has no badges), opening a list in two parts, each saying where it comes from. Verso's own, kept on this
//! computer for the account (`verso_desktop::notifications`): for now what each import came to, one that did
//! not bring everything in opening to list each file and why. Immich's, the server's own (album invitations, failed
//! jobs, messages from the admin): read when the list opens and every minute while the window is up, less often while
//! the server does not answer; a server that refuses them (a key without the permission) or does not know them (an
//! older server) leaves that part out, and the bell with it while Verso has none either. A click on one marks it read,
//! each can be deleted, and Mark All Read marks both parts.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use adw::prelude::*;
use chrono::Utc;
use gtk::glib;
use immich_api::{ApiError, Client, NotificationFilter, NotificationLevel};
use verso_desktop::notifications::{self, Notification};
use verso_desktop::{settings, text};
use verso_linux::i18n::tr;

use crate::window::Window;

/// How often the server's notifications are read, in seconds, and how far apart at most while it does not answer.
const EVERY: u32 = 60;
const AT_MOST: u32 = 15 * 60;

/// The most files a notification lists; the rest are counted.
const FILES_SHOWN: usize = 100;

/// What a coloured circle says (`Badge`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sign {
    /// Files are being sent: an arrow, on the accent colour.
    Working,
    /// Everything came in, or the server says something went well: a tick, on green.
    Done,
    /// Something needs a look, or the server warns: an exclamation mark, on orange.
    NeedsLook,
    /// The server tells something: an i, on the accent colour.
    Info,
    /// The server says something failed: a cross, on red.
    Error,
}

/// A coloured circle with a white symbolic icon (style.css, `verso-badge`): the import's state at the sidebar's foot,
/// where the account has its picture and at its size, and each notification's.
pub struct Badge {
    /// The icon, drawn in the middle of its circle.
    pub widget: gtk::Image,
}

impl Badge {
    pub fn new(size: i32) -> Badge {
        let widget = gtk::Image::builder().pixel_size(16).width_request(size).height_request(size).halign(gtk::Align::Center).valign(gtk::Align::Center).css_classes(["verso-badge"]).build();
        Badge { widget }
    }

    pub fn show(&self, sign: Sign) {
        let (icon, colour) = match sign {
            Sign::Working => ("verso-arrow-up-symbolic", "working"),
            Sign::Done => ("object-select-symbolic", "done"),
            Sign::NeedsLook => ("verso-exclamation-symbolic", "needs-look"),
            Sign::Info => ("verso-info-symbolic", "info"),
            Sign::Error => ("window-close-symbolic", "error"),
        };
        self.widget.set_icon_name(Some(icon));
        self.widget.set_css_classes(&["verso-badge", colour]);
    }
}

/// A notification of either part, by its id.
#[derive(Clone)]
enum Which {
    Verso(String),
    Immich(String),
}

pub struct Bell {
    window: glib::WeakRef<Window>,
    client: Client,
    /// Whose Verso notifications these are (`Connection::account_key`).
    account: String,
    /// The server, as Immich's part says where it comes from.
    host: String,
    /// The bell, beside the account.
    pub button: gtk::MenuButton,
    count: gtk::Label,
    mark_all: gtk::Button,
    lists: gtk::Box,
    scroller: gtk::ScrolledWindow,
    empty: adw::StatusPage,
    verso: RefCell<Vec<Notification>>,
    immich: RefCell<Vec<immich_api::Notification>>,
    /// The server lists this account's notifications: not once it refused them (403) or does not know them (404).
    immich_available: Cell<bool>,
    /// Why the server's could not be read the last time, while it does not answer.
    immich_error: RefCell<Option<String>>,
    /// The notifications opened to show their files, kept open as the list is drawn again.
    expanded: RefCell<HashSet<String>>,
    /// Seconds until the server's are read again.
    delay: Cell<u32>,
    reading: RefCell<Option<glib::SourceId>>,
    /// The list will be drawn again, once the event at hand is over (it may come from a row of it).
    redraw_pending: Cell<bool>,
}

impl Bell {
    pub fn new(window: &Window, client: Client, account: String, host: String) -> Rc<Bell> {
        let icon = gtk::Image::from_icon_name("preferences-system-notifications-symbolic");
        let count = gtk::Label::builder().visible(false).css_classes(["caption-heading", "numeric"]).build();
        let label = gtk::Box::builder().spacing(4).build();
        label.append(&icon);
        label.append(&count);
        let heading = gtk::Label::builder().label(tr("Notifications")).xalign(0.0).hexpand(true).css_classes(["heading"]).build();
        let mark_all = gtk::Button::builder().label(tr("Mark All Read")).visible(false).css_classes(["flat"]).build();
        let header = gtk::Box::builder().spacing(6).margin_start(12).margin_end(6).margin_top(6).margin_bottom(6).height_request(34).build();
        header.append(&heading);
        header.append(&mark_all);
        let lists = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(18).margin_start(12).margin_end(12).margin_top(6).margin_bottom(12).build();
        let scroller = gtk::ScrolledWindow::builder().child(&lists).hscrollbar_policy(gtk::PolicyType::Never).propagate_natural_height(true).max_content_height(480).build();
        let empty = adw::StatusPage::builder().icon_name("preferences-system-notifications-symbolic").title(tr("No Notifications")).css_classes(["compact"]).build();
        let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).width_request(360).build();
        content.append(&header);
        content.append(&scroller);
        content.append(&empty);
        let popover = gtk::Popover::builder().child(&content).build();
        let button = gtk::MenuButton::builder().child(&label).popover(&popover).direction(gtk::ArrowType::Up).valign(gtk::Align::Center).visible(false).css_classes(["flat", "verso-bell"]).build();
        let bell = Rc::new(Bell {
            window: window.downgrade(),
            client,
            account,
            host,
            button,
            count,
            mark_all: mark_all.clone(),
            lists,
            scroller,
            empty,
            verso: RefCell::default(),
            immich: RefCell::default(),
            immich_available: Cell::new(true),
            immich_error: RefCell::default(),
            expanded: RefCell::default(),
            delay: Cell::new(EVERY),
            reading: RefCell::default(),
            redraw_pending: Cell::new(false),
        });
        let weak = Rc::downgrade(&bell);
        popover.connect_show(move |_| {
            if let Some(bell) = weak.upgrade() {
                bell.read(false);
            }
        });
        let weak = Rc::downgrade(&bell);
        mark_all.connect_clicked(move |_| {
            if let Some(bell) = weak.upgrade() {
                bell.mark_all_read();
            }
        });
        bell.read(true);
        bell
    }

    /// Keep one of Verso's notifications (an import that went from the sidebar's foot).
    pub fn add(self: &Rc<Self>, notification: Notification) {
        notifications::add(settings::shared(), &self.account, notification, Utc::now());
        self.verso.replace(notifications::kept(settings::shared(), &self.account, Utc::now()));
        self.redraw_soon();
    }

    /// Read both parts again: Verso's from this computer at once, Immich's from the server. `again` keeps reading the
    /// server's every minute after, doubling the wait while it does not answer.
    fn read(self: &Rc<Self>, again: bool) {
        self.verso.replace(notifications::kept(settings::shared(), &self.account, Utc::now()));
        self.redraw_soon();
        if !self.immich_available.get() {
            return;
        }
        let (client, weak) = (self.client.clone(), Rc::downgrade(self));
        crate::tasks::run(async move { client.notifications(&NotificationFilter::default()).await }, move |outcome| {
            let Some(bell) = weak.upgrade() else { return };
            match outcome {
                Ok(mut listed) => {
                    listed.sort_by_key(|notification| std::cmp::Reverse(notification.created_at));
                    bell.immich.replace(listed);
                    bell.immich_error.replace(None);
                    bell.delay.set(EVERY);
                }
                Err(ApiError::Forbidden { .. } | ApiError::NotFound) => {
                    bell.immich_available.set(false);
                    bell.immich.borrow_mut().clear();
                }
                Err(error) => {
                    bell.immich_error.replace(Some(verso_desktop::errors::said(&error)));
                    if again {
                        bell.delay.set((bell.delay.get() * 2).min(AT_MOST));
                    }
                }
            }
            bell.redraw_soon();
            if again && bell.immich_available.get() {
                bell.read_later();
            }
        });
    }

    fn read_later(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        let reading = glib::timeout_add_seconds_local_once(self.delay.get(), move || {
            if let Some(bell) = weak.upgrade() {
                bell.reading.replace(None);
                bell.read(true);
            }
        });
        if let Some(earlier) = self.reading.replace(Some(reading)) {
            earlier.remove();
        }
    }

    fn mark_read(self: &Rc<Self>, which: &Which) {
        let now = Utc::now();
        match which {
            Which::Verso(id) => {
                notifications::mark_read(settings::shared(), &self.account, std::slice::from_ref(id), now);
                self.verso.replace(notifications::kept(settings::shared(), &self.account, now));
            }
            Which::Immich(id) => {
                let unread = self.immich.borrow_mut().iter_mut().find(|notification| notification.id == *id && notification.read_at.is_none()).map(|notification| notification.read_at = Some(now)).is_some();
                if unread {
                    self.ask_server(vec![id.clone()], false);
                }
            }
        }
        self.redraw_soon();
    }

    fn mark_all_read(self: &Rc<Self>) {
        let now = Utc::now();
        let verso: Vec<String> = self.verso.borrow().iter().filter(|notification| notification.read_at.is_none()).map(|notification| notification.id.clone()).collect();
        notifications::mark_read(settings::shared(), &self.account, &verso, now);
        self.verso.replace(notifications::kept(settings::shared(), &self.account, now));
        let mut immich = Vec::new();
        for notification in self.immich.borrow_mut().iter_mut().filter(|notification| notification.read_at.is_none()) {
            notification.read_at = Some(now);
            immich.push(notification.id.clone());
        }
        if !immich.is_empty() {
            self.ask_server(immich, false);
        }
        self.redraw_soon();
    }

    fn delete(self: &Rc<Self>, which: &Which) {
        match which {
            Which::Verso(id) => {
                notifications::delete(settings::shared(), &self.account, id, Utc::now());
                self.verso.replace(notifications::kept(settings::shared(), &self.account, Utc::now()));
            }
            Which::Immich(id) => {
                self.immich.borrow_mut().retain(|notification| notification.id != *id);
                self.ask_server(vec![id.clone()], true);
            }
        }
        self.redraw_soon();
    }

    /// Mark the server's notifications `ids` read, or delete them; shown so at once, read again if the server refused.
    fn ask_server(self: &Rc<Self>, ids: Vec<String>, deleting: bool) {
        let (client, weak) = (self.client.clone(), Rc::downgrade(self));
        crate::tasks::run(
            async move {
                if deleting {
                    client.delete_notifications(&ids).await
                } else {
                    client.mark_notifications(&ids, Some(Utc::now())).await
                }
            },
            move |outcome| {
                let (Some(bell), Err(error)) = (weak.upgrade(), outcome) else { return };
                if let Some(window) = bell.window.upgrade() {
                    window.toast(&verso_desktop::errors::said(&error));
                }
                bell.read(false);
            },
        );
    }

    fn redraw_soon(self: &Rc<Self>) {
        if self.redraw_pending.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(bell) = weak.upgrade() {
                bell.redraw_pending.set(false);
                bell.redraw();
            }
        });
    }

    /// The bell with how many are unread, and the list drawn again.
    fn redraw(self: &Rc<Self>) {
        let available = self.immich_available.get();
        let verso = self.verso.borrow().clone();
        let immich = if available { self.immich.borrow().clone() } else { Vec::new() };
        let unread = verso.iter().filter(|notification| notification.read_at.is_none()).count() + immich.iter().filter(|notification| notification.read_at.is_none()).count();
        self.button.set_visible(available || !verso.is_empty());
        self.count.set_label(&unread.to_string());
        self.count.set_visible(unread > 0);
        let said = match unread {
            0 => tr("Notifications").to_owned(),
            1 => tr("1 unread notification").to_owned(),
            _ => tr("{count} unread notifications").replace("{count}", &unread.to_string()),
        };
        self.button.set_tooltip_text(Some(&said));
        self.button.update_property(&[gtk::accessible::Property::Label(&said)]);
        self.mark_all.set_visible(unread > 0);
        while let Some(child) = self.lists.first_child() {
            self.lists.remove(&child);
        }
        let now = Utc::now();
        if !verso.is_empty() {
            let group = adw::PreferencesGroup::builder().title(tr("Verso")).description(tr("On this computer")).build();
            for notification in &verso {
                group.add(&self.verso_row(notification, now));
            }
            self.lists.append(&group);
        }
        let error = self.immich_error.borrow().clone();
        if available && (!immich.is_empty() || error.is_some()) {
            let group = adw::PreferencesGroup::builder().title(tr("Immich")).description(&self.host).build();
            if let Some(error) = error {
                group.add(&adw::ActionRow::builder().title(tr("Could not be read")).subtitle(error).use_markup(false).css_classes(["error"]).build());
            }
            for notification in &immich {
                group.add(&self.immich_row(notification, now));
            }
            self.lists.append(&group);
        }
        let empty = self.lists.first_child().is_none();
        self.scroller.set_visible(!empty);
        self.empty.set_visible(empty);
    }

    /// One of Verso's: what an import came to, opening to list each file not imported, and why.
    fn verso_row(self: &Rc<Self>, notification: &Notification, now: chrono::DateTime<Utc>) -> gtk::Widget {
        let sign = if notification.needs_look { Sign::NeedsLook } else { Sign::Done };
        let lines = [notification.caption.clone().unwrap_or_default(), text::ago(notification.created_at, now)];
        let which = Which::Verso(notification.id.clone());
        let unread = notification.read_at.is_none();
        if notification.files.is_empty() {
            return self.plain_row(&notification.title, &lines, sign, unread, which);
        }
        let row = adw::ExpanderRow::builder().title(title_markup(&notification.title, unread)).subtitle(subtitle_markup(&lines)).build();
        let badge = Badge::new(32);
        badge.show(sign);
        row.add_prefix(&badge.widget);
        row.add_suffix(&self.delete_button(&which));
        for file in notification.files.iter().take(FILES_SHOWN) {
            row.add_row(&adw::ActionRow::builder().title(&file.name).subtitle(&file.reason).use_markup(false).build());
        }
        if notification.files.len() > FILES_SHOWN {
            let more = tr("{count} more").replace("{count}", &(notification.files.len() - FILES_SHOWN).to_string());
            row.add_row(&adw::ActionRow::builder().title(more).use_markup(false).css_classes(["dim-label"]).build());
        }
        row.set_expanded(self.expanded.borrow().contains(&notification.id));
        let (weak, id) = (Rc::downgrade(self), notification.id.clone());
        row.connect_expanded_notify(move |row| {
            let Some(bell) = weak.upgrade() else { return };
            if row.is_expanded() {
                bell.expanded.borrow_mut().insert(id.clone());
                if unread {
                    bell.mark_read(&Which::Verso(id.clone()));
                }
            } else {
                bell.expanded.borrow_mut().remove(&id);
            }
        });
        row.upcast()
    }

    /// One of Immich's: its title, what it says, and when.
    fn immich_row(self: &Rc<Self>, notification: &immich_api::Notification, now: chrono::DateTime<Utc>) -> gtk::Widget {
        let sign = match notification.level {
            NotificationLevel::Success => Sign::Done,
            NotificationLevel::Warning => Sign::NeedsLook,
            NotificationLevel::Error => Sign::Error,
            NotificationLevel::Info | NotificationLevel::Other(_) => Sign::Info,
        };
        let lines = [notification.description.clone().unwrap_or_default(), text::ago(notification.created_at, now)];
        self.plain_row(&notification.title, &lines, sign, notification.read_at.is_none(), Which::Immich(notification.id.clone()))
    }

    /// A row that a click marks read.
    fn plain_row(self: &Rc<Self>, title: &str, lines: &[String], sign: Sign, unread: bool, which: Which) -> gtk::Widget {
        let row = adw::ActionRow::builder().title(title_markup(title, unread)).subtitle(subtitle_markup(lines)).activatable(unread).build();
        let badge = Badge::new(32);
        badge.show(sign);
        row.add_prefix(&badge.widget);
        row.add_suffix(&self.delete_button(&which));
        let weak = Rc::downgrade(self);
        row.connect_activated(move |_| {
            if let Some(bell) = weak.upgrade() {
                bell.mark_read(&which);
            }
        });
        row.upcast()
    }

    fn delete_button(self: &Rc<Self>, which: &Which) -> gtk::Button {
        let button = gtk::Button::builder().icon_name("user-trash-symbolic").tooltip_text(tr("Delete")).valign(gtk::Align::Center).css_classes(["flat"]).build();
        let (weak, which) = (Rc::downgrade(self), which.clone());
        button.connect_clicked(move |_| {
            if let Some(bell) = weak.upgrade() {
                bell.delete(&which);
            }
        });
        button
    }
}

impl Drop for Bell {
    fn drop(&mut self) {
        if let Some(reading) = self.reading.take() {
            reading.remove();
        }
    }
}

/// A notification's title, bold while unread.
fn title_markup(title: &str, unread: bool) -> String {
    let title = glib::markup_escape_text(title);
    if unread {
        format!("<b>{title}</b>")
    } else {
        title.to_string()
    }
}

/// What a notification says, then when, on lines of their own.
fn subtitle_markup(lines: &[String]) -> String {
    lines.iter().filter(|line| !line.trim().is_empty()).map(|line| glib::markup_escape_text(line.trim()).to_string()).collect::<Vec<_>>().join("\n")
}
