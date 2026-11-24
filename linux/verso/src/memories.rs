//! Memories, as the Mac gallery's: every memory Immich has made, newest first, a hundred at a time as the page
//! scrolls, each a card (`cards`): three of its photos and New until it is opened; when, how many, where most were
//! taken and who is in them; and a bookmark that keeps it, as Immich removes a memory after 30 days unless kept.
//! Delete Memory on a right click, after asking. A memory plays in a player of its own over the window: its
//! photos one by one on black for the account's memory duration (Immich's preference), with Previous, Play or
//! Pause, Next, where it is, and Remove from Memory. Opening a memory marks it seen; the Locked Folder's photos stay
//! out.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::asset::Visibility;
use immich_api::{Memory, MemoryChanges, MemoryFilter, MemoryOrder};
use verso_desktop::images::Kind as ImageKind;
use verso_desktop::text;
use verso_linux::i18n::tr;

use crate::cards::{and_list, chip, joined, Card, Shown};
use crate::collections::{add_card, card_page};
use crate::utility_pages::string_action;
use crate::window::Window;

/// Memories read at once.
const PAGE: u32 = 100;

/// A memory's title: how long ago its photos were taken.
fn title(memory: &Memory) -> String {
    let this_year = chrono::Datelike::year(&verso_desktop::library::today());
    match this_year - memory.data.year {
        years if years <= 0 => memory.data.year.to_string(),
        1 => tr("1 Year Ago").to_owned(),
        years => tr("{count} Years Ago").replace("{count}", &years.to_string()),
    }
}

/// The memory without the Locked Folder's photos.
fn visible(mut memory: Memory) -> Memory {
    memory.assets.retain(|asset| asset.visibility != Visibility::Locked);
    memory
}

struct Paging {
    next: Cell<u32>,
    more: Cell<bool>,
    busy: Cell<bool>,
    /// Seconds a photo shows in the player.
    duration: Cell<u32>,
    memories: RefCell<Vec<Memory>>,
}

pub fn memories_page(window: &Window) -> adw::NavigationPage {
    let cards = card_page(tr("Memories"), tr("No Memories"), "document-open-recent-symbolic");
    cards.empty.set_description(Some(tr("Immich makes memories from your library each day: the same day in earlier years.")));
    // Cards, as many on a line as fit, at most five, at the zoom's size.
    cards.page.add_css_class("verso-card-page");
    cards.header.pack_start(&crate::cards::zoom_buttons());
    cards.flow.set_max_children_per_line(5);
    cards.flow.set_min_children_per_line(1);
    cards.flow.add_css_class("verso-cards");
    let paging = Rc::new(Paging { next: Cell::new(1), more: Cell::new(true), busy: Cell::new(false), duration: Cell::new(5), memories: RefCell::default() });
    let load: Rc<dyn Fn()> = {
        let (weak_window, flow, stack, empty, paging) = (window.downgrade(), cards.flow.clone(), cards.stack.clone(), cards.empty.clone(), paging.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            if paging.busy.get() || !paging.more.get() {
                return;
            }
            paging.busy.set(true);
            let first = paging.next.get() == 1;
            let filter = MemoryFilter { order: Some(MemoryOrder::Desc), size: Some(PAGE), page: Some(paging.next.get()), ..MemoryFilter::default() };
            let client = session.connection.client.clone();
            let (weak_window, flow, stack, empty, paging, textures) = (window.downgrade(), flow.clone(), stack.clone(), empty.clone(), paging.clone(), session.textures.clone());
            crate::tasks::run(
                async move {
                    let preferences = if first { Some(client.preferences().await.map_err(|error| verso_desktop::errors::said(&error))?) } else { None };
                    if preferences.as_ref().is_some_and(|preferences| !preferences.memories.enabled) {
                        return Ok((preferences, Vec::new()));
                    }
                    let memories = client.memories(&filter).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    Ok::<_, String>((preferences, memories))
                },
                move |outcome| {
                    paging.busy.set(false);
                    let Some(window) = weak_window.upgrade() else { return };
                    let (preferences, batch) = match outcome {
                        Ok(found) => found,
                        Err(message) => {
                            paging.more.set(false);
                            stack.set_visible_child_name("empty");
                            return window.toast(&message);
                        }
                    };
                    if let Some(preferences) = preferences {
                        paging.duration.set(preferences.memories.duration.max(1));
                        if !preferences.memories.enabled {
                            paging.more.set(false);
                            empty.set_title(tr("Memories Are Off"));
                            empty.set_description(Some(tr("Memories are turned off in Immich's account settings.")));
                            stack.set_visible_child_name("empty");
                            return;
                        }
                    }
                    paging.more.set(batch.len() == PAGE as usize);
                    paging.next.set(paging.next.get() + 1);
                    for memory in batch.into_iter().map(visible).filter(|memory| !memory.assets.is_empty()) {
                        let name = title(&memory);
                        let (shown, new) = memory_card(&window, &textures, &memory);
                        memory_menu(&shown, &memory.id);
                        let (weak_window, id, paging_for_open) = (window.downgrade(), memory.id.clone(), Rc::downgrade(&paging));
                        let new = new.map(|new| new.downgrade());
                        add_card(&flow, &shown, &name, move || {
                            let (Some(window), Some(paging)) = (weak_window.upgrade(), paging_for_open.upgrade()) else { return };
                            // Opened, it is seen (`memory_player` tells Immich).
                            if let Some(new) = new.as_ref().and_then(glib::WeakRef::upgrade) {
                                new.set_visible(false);
                            }
                            let Some(memory) = paging.memories.borrow().iter().find(|memory| memory.id == id).cloned() else { return };
                            window.present_over(&memory_player(&window, memory, paging.duration.get()));
                        });
                        paging.memories.borrow_mut().push(memory);
                    }
                    stack.set_visible_child_name(if paging.memories.borrow().is_empty() { "empty" } else { "cards" });
                },
            );
        })
    };
    // More as the page scrolls to its end.
    if let Some(scrolled) = cards.flow.ancestor(gtk::ScrolledWindow::static_type()).and_downcast::<gtk::ScrolledWindow>() {
        let more = load.clone();
        scrolled.connect_edge_reached(move |_, edge| {
            if edge == gtk::PositionType::Bottom {
                more();
            }
        });
    }
    let actions = gio::SimpleActionGroup::new();
    let (weak_window, flow, paging) = (window.downgrade(), cards.flow.clone(), paging.clone());
    actions.add_action(&string_action("delete", move |id| {
        let Some(window) = weak_window.upgrade() else { return };
        let (weak, flow, paging) = (window.downgrade(), flow.downgrade(), Rc::downgrade(&paging));
        crate::dialogs::confirm(&window, tr("Delete the Memory?"), tr("The photos in it stay in your library."), tr("Delete Memory"), true, move || {
            let Some(window) = weak.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, id, shown, flow, paging) = (session.connection.client.clone(), id.clone(), window.clone(), flow.clone(), paging.clone());
            let deleted = id.clone();
            crate::tasks::run(async move { client.delete_memory(&deleted).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(()) => {
                    let Some(paging) = paging.upgrade() else { return };
                    let index = paging.memories.borrow().iter().position(|memory| memory.id == id);
                    if let (Some(index), Some(flow)) = (index, flow.upgrade()) {
                        paging.memories.borrow_mut().remove(index);
                        if let Some(child) = flow.child_at_index(index as i32) {
                            flow.remove(&child);
                        }
                    }
                }
                Err(message) => shown.toast(&message),
            });
        });
    }));
    cards.page.insert_action_group("memories", Some(&actions));
    load();
    cards.page
}

/// A memory as a card (the module's head says what it shows), and its New chip while it is not opened yet.
fn memory_card(window: &Window, textures: &Rc<crate::textures::Textures>, memory: &Memory) -> (gtk::Box, Option<gtk::Box>) {
    let card = Card::new(&title(memory), true);
    card.set_photos(textures, &memory.assets.iter().take(3).map(|asset| Shown::photo(&asset.id)).collect::<Vec<_>>());
    let new = memory.seen_at.is_none().then(|| {
        let new = chip(None, Some(tr("New")), tr("Not opened yet"));
        new.add_css_class("accent");
        card.chip_start(&new);
        new
    });
    card.chip_end(&keep_button(window, memory));
    // The day its photos were taken: the first's, else the memory's day in its year.
    let day = memory
        .assets
        .iter()
        .find_map(|asset| asset.local_date_time)
        .map(|taken| taken.date())
        .or_else(|| chrono::NaiveDate::from_ymd_opt(memory.data.year, chrono::Datelike::month(&memory.memory_at), chrono::Datelike::day(&memory.memory_at)));
    let day = day.map(|day| format!("{} {} {}", chrono::Datelike::day(&day), text::month_name(chrono::Datelike::month(&day)), chrono::Datelike::year(&day))).unwrap_or_default();
    card.line(&joined(&[day, text::items(memory.assets.len() as u64)]));
    let people = who(memory, 3);
    let with = if people.is_empty() { String::new() } else { tr("with {people}").replace("{people}", &and_list(&people)) };
    card.line(&joined(&[where_taken(memory).unwrap_or_default(), with]));
    (card.root.clone(), new)
}

/// The bookmark that keeps a memory (`isSaved`): Immich removes a memory after 30 days unless it is kept. A ribbon,
/// filled once kept, as a thing to keep is marked; a star means a rating and a heart a favorite.
fn keep_button(window: &Window, memory: &Memory) -> gtk::ToggleButton {
    let icon = |kept: bool| if kept { "verso-keep-symbolic" } else { "verso-keep-outline-symbolic" };
    let keep = gtk::ToggleButton::builder()
        .icon_name(icon(memory.is_saved))
        .active(memory.is_saved)
        .css_classes(["verso-card-chip", "verso-card-chip-button"])
        .tooltip_text(tr("Keep: Immich removes a memory after 30 days unless it is kept"))
        .build();
    let (weak_window, id) = (window.downgrade(), memory.id.clone());
    keep.connect_toggled(move |keep| {
        let kept = keep.is_active();
        keep.set_icon_name(icon(kept));
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, id, weak_keep, shown) = (session.connection.client.clone(), id.clone(), keep.downgrade(), window.clone());
        let changes = MemoryChanges { is_saved: Some(kept), ..MemoryChanges::default() };
        crate::tasks::run(async move { client.update_memory(&id, &changes).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            if let Err(message) = outcome {
                // Back as it was: the server did not take it.
                if let Some(keep) = weak_keep.upgrade() {
                    keep.set_active(!kept);
                }
                shown.toast(&message);
            }
        });
    });
    keep
}

/// Where most of a memory's photos were taken: "Odense, Denmark".
fn where_taken(memory: &Memory) -> Option<String> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for exif in memory.assets.iter().filter_map(|asset| asset.exif.as_ref()) {
        let place = [exif.city.as_deref(), exif.country.as_deref()].into_iter().flatten().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(", ");
        if place.is_empty() {
            continue;
        }
        match counts.iter_mut().find(|(known, _)| *known == place) {
            Some((_, count)) => *count += 1,
            None => counts.push((place, 1)),
        }
    }
    counts.into_iter().max_by_key(|(_, count)| *count).map(|(place, _)| place)
}

/// The named people in a memory's photos, those in the most photos first, up to `most`.
fn who(memory: &Memory, most: usize) -> Vec<String> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for person in memory.assets.iter().flat_map(|asset| &asset.people).filter(|person| !person.name.is_empty() && !person.is_hidden) {
        match counts.iter_mut().find(|(known, _)| *known == person.name) {
            Some((_, count)) => *count += 1,
            None => counts.push((person.name.clone(), 1)),
        }
    }
    counts.sort_by_key(|(_, count)| std::cmp::Reverse(*count));
    counts.into_iter().take(most).map(|(name, _)| name).collect()
}

/// Delete Memory, on a right click on its card.
fn memory_menu(card: &gtk::Box, id: &str) {
    let menu = gio::Menu::new();
    menu.append(Some(tr("Delete Memory…")), Some(&format!("memories.delete::{id}")));
    let click = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
    click.connect_pressed(move |gesture, _, x, y| {
        let Some(card) = gesture.widget() else { return };
        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_parent(&card);
        popover.set_has_arrow(false);
        popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        // The popover goes once closed; after its action has run.
        popover.connect_closed(|popover| {
            let popover = popover.clone();
            glib::idle_add_local_once(move || popover.unparent());
        });
        popover.popup();
    });
    card.add_controller(click);
}

struct Player {
    window: glib::WeakRef<Window>,
    memory: RefCell<Memory>,
    index: Cell<usize>,
    paused: Cell<bool>,
    duration: u32,
    picture: gtk::Picture,
    title: adw::WindowTitle,
    position: gtk::Label,
    play: gtk::Button,
    /// Bumps with each photo shown, so a late picture or a stale timer does nothing.
    shown: Cell<u64>,
}

/// A memory, played.
fn memory_player(window: &Window, memory: Memory, duration: u32) -> adw::NavigationPage {
    let picture = gtk::Picture::builder().content_fit(gtk::ContentFit::Contain).can_shrink(true).hexpand(true).vexpand(true).build();
    let stage = gtk::Box::builder().css_classes(["gallery-stage", "gallery-presentation"]).build();
    stage.append(&picture);
    let title = adw::WindowTitle::new(&title(&memory), &memory.data.year.to_string());
    let header = adw::HeaderBar::builder().title_widget(&title).build();
    let button = |icon: &str, tooltip: &str| gtk::Button::builder().icon_name(icon).tooltip_text(tooltip).css_classes(["circular"]).build();
    let previous = button("media-skip-backward-symbolic", tr("Previous"));
    let play = button("media-playback-pause-symbolic", tr("Pause"));
    let next = button("media-skip-forward-symbolic", tr("Next"));
    let position = gtk::Label::builder().css_classes(["numeric"]).width_chars(7).build();
    let remove = gtk::Button::builder().label(tr("Remove from Memory")).build();
    let controls = gtk::Box::builder().spacing(6).halign(gtk::Align::Center).margin_top(6).margin_bottom(6).build();
    for widget in [previous.upcast_ref::<gtk::Widget>(), play.upcast_ref(), next.upcast_ref(), position.upcast_ref(), remove.upcast_ref()] {
        controls.append(widget);
    }
    let toolbar = adw::ToolbarView::builder().top_bar_style(adw::ToolbarStyle::Raised).bottom_bar_style(adw::ToolbarStyle::Raised).build();
    toolbar.add_top_bar(&header);
    toolbar.add_bottom_bar(&controls);
    toolbar.set_content(Some(&stage));
    let page = adw::NavigationPage::builder().title(tr("Memory")).child(&toolbar).build();
    let player = Rc::new(Player { window: window.downgrade(), memory: RefCell::new(memory), index: Cell::new(0), paused: Cell::new(false), duration, picture, title, position, play: play.clone(), shown: Cell::new(0) });
    let on = |button: &gtk::Button, run: fn(&Rc<Player>)| {
        let weak = Rc::downgrade(&player);
        button.connect_clicked(move |_| {
            if let Some(player) = weak.upgrade() {
                run(&player);
            }
        });
    };
    on(&previous, |player| player.step(-1));
    on(&next, |player| player.step(1));
    on(&play, |player| player.set_paused(!player.paused.get()));
    on(&remove, Player::remove_shown);
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(&player);
    keys.connect_key_pressed(move |_, key, _, _| {
        let Some(player) = weak.upgrade() else { return glib::Propagation::Proceed };
        match key {
            gdk::Key::Left => player.step(-1),
            gdk::Key::Right => player.step(1),
            gdk::Key::space => player.set_paused(!player.paused.get()),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    page.add_controller(keys);
    // Opening it marks it seen.
    if let Some(session) = window.session() {
        let (client, id) = (session.connection.client.clone(), player.memory.borrow().id.clone());
        let changes = MemoryChanges { seen_at: Some(chrono::Utc::now()), ..MemoryChanges::default() };
        crate::tasks::run(async move { client.update_memory(&id, &changes).await.map(|_| ()).map_err(|error| verso_desktop::errors::said(&error)) }, |_| {});
    }
    // The page owns the player; everything else holds it weakly.
    let owned = player.clone();
    page.connect_destroy(move |_| {
        let _ = &owned;
    });
    player.show();
    page
}

impl Player {
    fn show(self: &Rc<Self>) {
        let Some(session) = self.window.upgrade().and_then(|window| window.session()) else { return };
        let memory = self.memory.borrow();
        let Some(asset) = memory.assets.get(self.index.get()) else { return };
        self.shown.set(self.shown.get() + 1);
        let shown = self.shown.get();
        self.position.set_label(&format!("{} / {}", self.index.get() + 1, memory.assets.len()));
        self.title.set_subtitle(&asset.local_date_time.map(|taken| text::day(taken.date())).unwrap_or_else(|| memory.data.year.to_string()));
        // The last picture stays until the next has come, then the next fades in, as on the Mac.
        let weak = Rc::downgrade(self);
        session.textures.get(ImageKind::Preview, &asset.id, asset.thumbhash.as_deref(), move |texture| {
            let (Some(player), Some(texture)) = (weak.upgrade(), texture) else { return };
            if player.shown.get() != shown {
                return;
            }
            player.picture.set_paintable(Some(&texture));
            let target = adw::PropertyAnimationTarget::new(&player.picture, "opacity");
            adw::TimedAnimation::builder().widget(&player.picture).value_from(0.4).value_to(1.0).duration(500).target(&target).build().play();
        });
        let weak = Rc::downgrade(self);
        glib::timeout_add_seconds_local_once(self.duration, move || advance(&weak, shown));
    }

    fn step(self: &Rc<Self>, by: i32) {
        let count = self.memory.borrow().assets.len() as i64;
        let index = (self.index.get() as i64 + i64::from(by)).clamp(0, (count - 1).max(0)) as usize;
        if index != self.index.get() {
            self.index.set(index);
            self.show();
        }
    }

    fn set_paused(self: &Rc<Self>, paused: bool) {
        self.paused.set(paused);
        self.play.set_icon_name(if paused { "media-playback-start-symbolic" } else { "media-playback-pause-symbolic" });
        self.play.set_tooltip_text(Some(if paused { tr("Play") } else { tr("Pause") }));
        if !paused {
            // Play again: the photo shown gets its full time.
            self.show();
        }
    }

    /// Remove from Memory: the photo leaves the memory, not the library.
    fn remove_shown(self: &Rc<Self>) {
        let Some(window) = self.window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (id, asset) = {
            let memory = self.memory.borrow();
            let Some(asset) = memory.assets.get(self.index.get()) else { return };
            (memory.id.clone(), asset.id.clone())
        };
        let (client, weak) = (session.connection.client.clone(), Rc::downgrade(self));
        crate::tasks::run(async move { client.remove_memory_assets(&id, std::slice::from_ref(&asset)).await.map(|_| asset).map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
            let Some(player) = weak.upgrade() else { return };
            match outcome {
                Ok(asset) => {
                    let left = {
                        let mut memory = player.memory.borrow_mut();
                        memory.assets.retain(|known| known.id != asset);
                        memory.assets.len()
                    };
                    if left == 0 {
                        if let Some(window) = player.window.upgrade() {
                            window.close_over();
                        }
                        return;
                    }
                    player.index.set(player.index.get().min(left - 1));
                    player.show();
                }
                Err(message) => {
                    if let Some(window) = player.window.upgrade() {
                        window.toast(&message);
                    }
                }
            }
        });
    }
}

/// The photo's time is up: the next, unless paused or another has shown since; the last pauses.
fn advance(weak: &Weak<Player>, shown: u64) {
    let Some(player) = weak.upgrade() else { return };
    if player.paused.get() || player.shown.get() != shown {
        return;
    }
    if player.index.get() + 1 < player.memory.borrow().assets.len() {
        player.step(1);
    } else {
        player.set_paused(true);
    }
}
