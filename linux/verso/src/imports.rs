//! Importing, as the Mac gallery does it: while files come in, and for 5 seconds after, the foot of the sidebar shows
//! the import just above the account, laid out as the account's row is. Where the account has its picture, a coloured
//! circle says how it goes (an arrow while files are sent, a tick once everything came in, an exclamation mark when
//! something needs a look); where it has its name, the import's title; where it has its server, a progress bar, or
//! once it ended a quieter line of what else it came to. Retry beside it when something failed or was cancelled; its
//! cross cancels it while it runs and closes it after. A click on it lists each file as it waits, is sent, and ends
//! (imported, already in the library, back from Recently Deleted, not imported, cancelled), with Import…, Cancel All,
//! Retry Failed and Clear. Once it ended it goes by itself after 5 seconds, into the notifications (`notifications`),
//! unless its cross closed it. There is no import button: Import… and Import Folders… are in the main menu, and files
//! are dropped anywhere. Files are sent one at a time; each joins its album as it comes in, and every two seconds the
//! grids show what came in so far, reading again only the months that changed.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use verso_desktop::notifications::Notification;
use verso_desktop::uploads::{self, Imported, Phase, Queue, State};
use verso_linux::i18n::tr;

use crate::notifications::{Badge, Sign};
use crate::window::Window;

/// The most files the list shows at once; the summary counts them all.
const SHOWN: usize = 200;

/// How long the import stays once it ended, in seconds, before it goes into the notifications.
const SHOWN_AFTER: u32 = 5;

pub struct Imports {
    window: glib::WeakRef<Window>,
    queue: RefCell<Queue>,
    /// The import at the sidebar's foot, with the line between it and the account: shown while there is an import.
    status: gtk::Box,
    badge: Badge,
    title: gtk::Label,
    progress: gtk::ProgressBar,
    caption: gtk::Label,
    retry_button: gtk::Button,
    stop_button: gtk::Button,
    /// The list of each file, opened by a click on the import.
    details: gtk::Popover,
    notes: gtk::Label,
    hint: gtk::Label,
    summary: gtk::Label,
    list: gtk::ListBox,
    scroller: gtk::ScrolledWindow,
    cancel: gtk::Button,
    retry: gtk::Button,
    clear: gtk::Button,
    /// The import shows: from its start until it is closed, or has gone by itself.
    shown: Cell<bool>,
    /// Files are being found in what was chosen.
    scanning: Cell<usize>,
    /// Counts the cancellations: files found for an import cancelled meanwhile are not sent.
    generation: Cell<u64>,
    /// Why the import stopped before any file (an album the account may only view), as the import says it.
    error: RefCell<Option<String>>,
    /// The grids will show what came in so far, shortly.
    refresh_pending: Cell<bool>,
    /// The import going by itself, 5 seconds after it ended.
    hiding: RefCell<Option<glib::SourceId>>,
    /// The progress bar moving while files are looked for, and how many there are is not known.
    pulsing: RefCell<Option<glib::SourceId>>,
    /// An album refused photos during this import, which a toast said once.
    album_refused: Cell<bool>,
}

impl Imports {
    /// Photos are being found or imported.
    pub fn busy(&self) -> bool {
        self.queue.borrow().is_running() || self.scanning.get() > 0
    }

    pub fn new(window: &Window) -> Rc<Imports> {
        let title = gtk::Label::builder().label(tr("Import")).xalign(0.0).hexpand(true).css_classes(["heading"]).build();
        let choose = gtk::Button::builder().label(tr("Import…")).action_name("win.import").build();
        let folders = gtk::Button::builder().label(tr("Folders…")).action_name("win.import-folders").build();
        let choices = gtk::Box::builder().css_classes(["linked"]).build();
        choices.append(&choose);
        choices.append(&folders);
        let header = gtk::Box::builder().spacing(12).build();
        header.append(&title);
        header.append(&choices);
        let notes = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).css_classes(["caption", "warning"]).build();
        let hint = gtk::Label::builder().label(tr("Choose files or folders, or drop them onto the window. Dropped on an album, in the sidebar, on its card or on its page, they join the album too.")).xalign(0.0).wrap(true).css_classes(["dim-label"]).build();
        let summary = gtk::Label::builder().xalign(0.0).wrap(true).visible(false).css_classes(["dim-label"]).build();
        let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        let scroller = gtk::ScrolledWindow::builder().child(&list).hscrollbar_policy(gtk::PolicyType::Never).max_content_height(320).propagate_natural_height(true).visible(false).build();
        let cancel = gtk::Button::builder().label(tr("Cancel All")).build();
        let retry = gtk::Button::builder().label(tr("Retry Failed")).build();
        let clear = gtk::Button::builder().label(tr("Clear")).halign(gtk::Align::End).hexpand(true).build();
        let buttons = gtk::Box::builder().spacing(6).build();
        buttons.append(&cancel);
        buttons.append(&retry);
        buttons.append(&clear);
        let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).width_request(380).build();
        for widget in [header.upcast_ref::<gtk::Widget>(), notes.upcast_ref(), hint.upcast_ref(), summary.upcast_ref(), scroller.upcast_ref(), buttons.upcast_ref()] {
            content.append(widget);
        }
        let details = gtk::Popover::builder().child(&content).build();
        for button in [&choose, &folders] {
            let weak_popover = details.downgrade();
            button.connect_clicked(move |_| {
                if let Some(popover) = weak_popover.upgrade() {
                    popover.popdown();
                }
            });
        }
        // The import, laid out as the account below it is (`Window::build_account_footer`): the same margins, the
        // button's padding (style.css, `verso-import` beside `verso-account`), a circle of its picture's size, and two
        // lines, the second up to three once it wraps.
        let badge = Badge::new(28);
        let status_title = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
        let progress = gtk::ProgressBar::builder().valign(gtk::Align::Center).margin_top(5).margin_bottom(4).css_classes(["verso-import-progress"]).build();
        let caption = gtk::Label::builder().xalign(0.0).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).lines(3).ellipsize(gtk::pango::EllipsizeMode::End).css_classes(["caption", "dim-label"]).build();
        let labels = gtk::Box::builder().orientation(gtk::Orientation::Vertical).valign(gtk::Align::Center).hexpand(true).build();
        labels.append(&status_title);
        labels.append(&progress);
        labels.append(&caption);
        let row = gtk::Box::builder().spacing(8).build();
        row.append(&badge.widget);
        row.append(&labels);
        // A toggle that opens the list beside it, not a menu button: a menu button measures its height for one width
        // only, which cut off the line under the title once it wrapped.
        let status_button = gtk::ToggleButton::builder().child(&row).hexpand(true).css_classes(["verso-import"]).tooltip_text(tr("Show Each File")).build();
        details.set_parent(&status_button);
        details.set_position(gtk::PositionType::Right);
        let weak_popover = details.downgrade();
        status_button.connect_toggled(move |button| {
            if let (Some(popover), true) = (weak_popover.upgrade(), button.is_active()) {
                popover.popup();
            }
        });
        let weak_button = status_button.downgrade();
        details.connect_closed(move |_| {
            if let Some(button) = weak_button.upgrade() {
                button.set_active(false);
            }
        });
        let weak_popover = details.downgrade();
        status_button.connect_destroy(move |_| {
            if let Some(popover) = weak_popover.upgrade() {
                popover.unparent();
            }
        });
        let retry_button = gtk::Button::builder().icon_name("view-refresh-symbolic").tooltip_text(tr("Retry")).valign(gtk::Align::Center).css_classes(["flat"]).build();
        let stop_button = gtk::Button::builder().icon_name("window-close-symbolic").valign(gtk::Align::Center).css_classes(["flat", "circular"]).build();
        let line = gtk::Box::builder().spacing(6).margin_top(6).margin_bottom(6).margin_start(6).margin_end(6).build();
        line.append(&status_button);
        line.append(&retry_button);
        line.append(&stop_button);
        let status = gtk::Box::builder().orientation(gtk::Orientation::Vertical).visible(false).build();
        status.append(&line);
        status.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let imports = Rc::new(Imports {
            window: window.downgrade(),
            queue: RefCell::default(),
            status,
            badge,
            title: status_title,
            progress,
            caption,
            retry_button: retry_button.clone(),
            stop_button: stop_button.clone(),
            details: details.clone(),
            notes,
            hint,
            summary,
            list,
            scroller,
            cancel: cancel.clone(),
            retry: retry.clone(),
            clear: clear.clone(),
            shown: Cell::new(false),
            scanning: Cell::new(0),
            generation: Cell::new(0),
            error: RefCell::default(),
            refresh_pending: Cell::new(false),
            hiding: RefCell::default(),
            pulsing: RefCell::default(),
            album_refused: Cell::new(false),
        });
        let weak = Rc::downgrade(&imports);
        cancel.connect_clicked(move |_| {
            if let Some(imports) = weak.upgrade() {
                imports.cancel_all();
            }
        });
        for button in [&retry, &retry_button] {
            let weak = Rc::downgrade(&imports);
            button.connect_clicked(move |_| {
                if let Some(imports) = weak.upgrade() {
                    imports.retry_failed();
                }
            });
        }
        let weak = Rc::downgrade(&imports);
        clear.connect_clicked(move |_| {
            if let Some(imports) = weak.upgrade() {
                imports.close();
            }
        });
        let weak = Rc::downgrade(&imports);
        stop_button.connect_clicked(move |_| {
            let Some(imports) = weak.upgrade() else { return };
            if imports.busy() {
                imports.cancel_all();
            } else {
                imports.close();
            }
        });
        // The import stays while its list is open, and goes 5 seconds after it closes.
        let weak = Rc::downgrade(&imports);
        details.connect_closed(move |_| {
            if let Some(imports) = weak.upgrade().filter(|imports| imports.shown.get() && !imports.busy()) {
                imports.hide_later();
            }
        });
        imports.refresh();
        imports
    }

    /// The import at the sidebar's foot, for the window to place above the account.
    pub fn widget(&self) -> &gtk::Box {
        &self.status
    }

    /// Import files and folders, into `album` when one is given. An import after the last one ended starts the list
    /// afresh.
    pub fn enqueue(self: &Rc<Self>, paths: Vec<PathBuf>, album: Option<String>) {
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let client = session.connection.client.clone();
        if !self.busy() {
            self.keep_shown();
            self.start_afresh();
        }
        self.stay();
        self.scanning.set(self.scanning.get() + 1);
        self.shown.set(true);
        self.refresh();
        let (weak, generation) = (Rc::downgrade(self), self.generation.get());
        crate::tasks::run(
            async move {
                // Walking folders reads the disk: off the main loop.
                let found = tokio::task::spawn_blocking(move || uploads::files_in(&paths)).await.unwrap_or_default();
                let extensions = client.server_media_types().await.unwrap_or_default();
                (found, extensions)
            },
            move |(found, extensions)| {
                let Some(imports) = weak.upgrade() else { return };
                imports.scanning.set(imports.scanning.get().saturating_sub(1));
                if imports.generation.get() == generation {
                    let mut queue = imports.queue.borrow_mut();
                    if found.files.is_empty() && found.unreadable == 0 && queue.items.is_empty() && imports.scanning.get() == 0 {
                        imports.error.replace(Some(tr("No files were found in the selected folders.").to_owned()));
                    }
                    queue.unreadable += found.unreadable;
                    queue.enqueue(found.files, album, &extensions);
                }
                imports.refresh();
                imports.pump();
            },
        );
    }

    /// An import that stopped before any file (an album the account may only view): the import says why, and goes
    /// into the notifications as any import does. `false` while another import runs, which keeps the sidebar's foot:
    /// the caller says it some other way.
    pub fn stopped(self: &Rc<Self>, message: &str) -> bool {
        if self.busy() {
            return false;
        }
        self.keep_shown();
        self.start_afresh();
        self.stay();
        self.error.replace(Some(message.to_owned()));
        self.shown.set(true);
        self.refresh();
        self.hide_later();
        true
    }

    /// The list empties for a new import: the last one ended.
    fn start_afresh(&self) {
        self.queue.borrow_mut().clear();
        self.error.replace(None);
        self.album_refused.set(false);
    }

    /// The import stays: its going by itself is called off (a new import, Retry).
    fn stay(&self) {
        if let Some(hiding) = self.hiding.take() {
            hiding.remove();
        }
    }

    /// Cancel: what waits is cancelled, and files still being found are not sent; the file being sent finishes.
    fn cancel_all(self: &Rc<Self>) {
        if self.scanning.get() > 0 {
            self.generation.set(self.generation.get() + 1);
        }
        self.queue.borrow_mut().cancel_all();
        self.refresh();
        self.pump();
    }

    /// Retry: what failed or was cancelled is sent again.
    fn retry_failed(self: &Rc<Self>) {
        self.stay();
        self.queue.borrow_mut().retry_failed();
        self.refresh();
        self.pump();
    }

    /// The import goes from the sidebar's foot, and the finished files leave the list: its cross once it ended,
    /// Clear, or going by itself.
    fn close(&self) {
        if self.busy() {
            return;
        }
        self.stay();
        self.start_afresh();
        self.shown.set(false);
        self.details.popdown();
        self.refresh();
    }

    /// Once the import ended it stays 5 seconds, then goes into the notifications, where what it came to is kept:
    /// read when everything came in, unread when something needs a look. Not while its list is open: it goes 5 seconds
    /// after the list closes.
    fn hide_later(self: &Rc<Self>) {
        self.stay();
        let weak = Rc::downgrade(self);
        let hiding = glib::timeout_add_seconds_local_once(SHOWN_AFTER, move || {
            let Some(imports) = weak.upgrade() else { return };
            imports.hiding.replace(None);
            if !imports.shown.get() || imports.busy() || imports.details.is_visible() {
                return;
            }
            imports.keep_shown();
            imports.close();
        });
        self.hiding.replace(Some(hiding));
    }

    /// What the import shown came to goes into the notifications: when it goes by itself, and when a new import takes
    /// its place at the sidebar's foot first, so a failure dropped on quickly is kept. Its cross keeps nothing.
    fn keep_shown(&self) {
        if !self.shown.get() || self.busy() {
            return;
        }
        let outcome = self.queue.borrow().outcome(self.error.borrow().as_deref());
        if let Some(window) = self.window.upgrade() {
            window.keep_notification(Notification::new(outcome.title, outcome.caption, outcome.needs_look, outcome.files, chrono::Utc::now()));
        }
    }

    /// Send the next file, unless one is on its way; when none waits, finish the import.
    fn pump(self: &Rc<Self>) {
        if self.queue.borrow().sending() {
            return;
        }
        let next = self.queue.borrow_mut().take_next();
        self.refresh();
        let Some((index, path)) = next else {
            self.finish();
            return;
        };
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let client = session.connection.client.clone();
        let weak = Rc::downgrade(self);
        crate::tasks::run(async move { uploads::import(&client, &path).await }, move |outcome| {
            let Some(imports) = weak.upgrade() else { return };
            // A photo new to the library shows in its grids; one already there changes only an album it joins.
            let arrived = matches!(outcome, Ok(Imported::New(_) | Imported::Restored(_)));
            imports.queue.borrow_mut().finish(index, outcome);
            imports.add_to_albums();
            if arrived {
                imports.refresh_soon();
            }
            imports.pump();
        });
    }

    /// What came in for an album joins it at once, so its page shows it while the rest are sent.
    fn add_to_albums(self: &Rc<Self>) {
        let additions = self.queue.borrow_mut().album_additions();
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        for (album, ids) in additions {
            let (client, weak, weak_window) = (session.connection.client.clone(), Rc::downgrade(self), window.downgrade());
            crate::tasks::run(async move { client.add_assets_to_album(&album, &ids).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let (Some(imports), Some(window)) = (weak.upgrade(), weak_window.upgrade()) else { return };
                match outcome {
                    Ok(_) => imports.refresh_soon(),
                    // Once per import: the same refusal would come for every file.
                    Err(error) if !imports.album_refused.replace(true) => window.toast(&tr("They could not be added to the album: {error}").replace("{error}", &error)),
                    Err(_) => {}
                }
            });
        }
    }

    /// The grids show what came in so far, two seconds from the first file that did, so a large import redraws them
    /// every two seconds rather than for every file.
    fn refresh_soon(self: &Rc<Self>) {
        if self.refresh_pending.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_seconds_local_once(2, move || {
            let Some(imports) = weak.upgrade() else { return };
            imports.refresh_pending.set(false);
            if let Some(window) = imports.window.upgrade() {
                window.show_imports_so_far();
            }
        });
    }

    /// The queue is empty and no files are being found: the page shown is read again, and the import says what it
    /// came to, for 5 seconds. One cancelled while its files were still being found closes, as nothing happened.
    fn finish(self: &Rc<Self>) {
        if self.busy() || !self.shown.get() {
            return;
        }
        let Some(window) = self.window.upgrade() else { return };
        let (sent, new) = {
            let queue = self.queue.borrow();
            let said = queue.unsupported + queue.unreadable > 0 || self.error.borrow().is_some();
            if queue.items.is_empty() && !said {
                drop(queue);
                return self.close();
            }
            (!queue.items.is_empty(), queue.items.iter().any(|item| matches!(item.state, State::Done(Imported::New(_)))))
        };
        if sent {
            window.refresh();
        }
        // Immich reads a new file's date, shape and thumbnail in the background: until then it shows grey, square and
        // at the day it came in. The grids read again once it has had time, and again later.
        if new {
            for seconds in [5, 20] {
                let weak = window.downgrade();
                glib::timeout_add_seconds_local_once(seconds, move || {
                    if let Some(window) = weak.upgrade() {
                        window.reload_grids();
                    }
                });
            }
        }
        self.refresh();
        self.hide_later();
    }

    /// Show the import as it is, at the sidebar's foot and in the list.
    fn refresh(&self) {
        let queue = self.queue.borrow();
        let looking = self.scanning.get() > 0;
        let status = queue.status(looking, self.error.borrow().as_deref());
        let working = status.phase == Phase::Working;
        self.status.set_visible(self.shown.get());
        self.badge.show(match status.phase {
            Phase::Working => Sign::Working,
            Phase::Done => Sign::Done,
            Phase::NeedsLook => Sign::NeedsLook,
        });
        self.title.set_label(&status.title);
        self.progress.set_visible(working);
        if let Some(fraction) = status.progress {
            self.progress.set_fraction(fraction);
        }
        self.pulse(working && status.progress.is_none() && self.shown.get());
        self.caption.set_label(status.caption.as_deref().unwrap_or_default());
        self.caption.set_visible(!working && status.caption.is_some());
        self.retry_button.set_visible(!working && status.can_retry);
        self.stop_button.set_tooltip_text(Some(if working { tr("Cancel") } else { tr("Close") }));
        let failed = queue.failed();
        let mut notes = Vec::new();
        if looking {
            notes.push(tr("Looking for files…").to_owned());
        }
        if queue.unsupported > 0 {
            notes.push(tr("{count} files Immich does not take were left out").replace("{count}", &queue.unsupported.to_string()));
        }
        if queue.unreadable > 0 {
            notes.push(tr("{count} could not be read").replace("{count}", &queue.unreadable.to_string()));
        }
        if let Some(error) = self.error.borrow().as_deref() {
            notes.push(error.to_owned());
        }
        self.notes.set_label(&notes.join("\n"));
        self.notes.set_visible(!notes.is_empty());
        let empty = queue.items.is_empty();
        self.hint.set_visible(empty);
        self.summary.set_visible(!empty);
        self.summary.set_label(&queue.summary());
        self.scroller.set_visible(!empty);
        self.cancel.set_visible(queue.is_running());
        self.retry.set_visible(!queue.is_running() && !empty);
        self.retry.set_sensitive(failed > 0);
        self.clear.set_visible(!queue.is_running() && !empty);
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        // Around the file being sent, so the list shows where the import is.
        let at = queue.items.iter().position(|item| item.state == State::Sending || item.state == State::Waiting).unwrap_or(0);
        let start = at.saturating_sub(5).min(queue.items.len().saturating_sub(SHOWN));
        for item in queue.items.iter().skip(start).take(SHOWN) {
            let name = item.path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            let row = adw::ActionRow::builder().title(glib::markup_escape_text(&name)).subtitle(glib::markup_escape_text(item.state.error().map_or_else(|| item.state.title().to_owned(), |error| format!("{}: {error}", item.state.title())).as_str())).build();
            row.set_tooltip_text(item.path.to_str());
            if item.state == State::Sending {
                row.add_suffix(&adw::Spinner::new());
            }
            self.list.append(&row);
        }
    }

    /// Keep the progress bar moving while files are looked for, or stop it.
    fn pulse(&self, on: bool) {
        if !on {
            if let Some(pulsing) = self.pulsing.take() {
                pulsing.remove();
            }
            return;
        }
        if self.pulsing.borrow().is_some() {
            return;
        }
        let progress = self.progress.downgrade();
        let pulsing = glib::timeout_add_local(std::time::Duration::from_millis(120), move || match progress.upgrade() {
            Some(progress) => {
                progress.pulse();
                glib::ControlFlow::Continue
            }
            None => glib::ControlFlow::Break,
        });
        self.pulsing.replace(Some(pulsing));
    }
}
