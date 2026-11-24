//! Full Screen and the slideshow, as the Mac gallery's presentation: the viewer fills the screen on black, with
//! controls at the bottom that hide after a moment without the pointer moving (Exit, Previous, Play or Pause, Next,
//! Show in All Photos, the slideshow's settings). The slideshow goes on from the photo shown, in the grid's order or
//! shuffled, a photo for the interval and a video to its end (or the interval, if so set); it stops at the last.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

use adw::prelude::*;
use gtk::glib;
use verso_desktop::presentation::{self, Slideshow, INTERVALS, VIDEO_PATIENCE};
use verso_desktop::settings;
use verso_linux::i18n::tr;

use crate::pages::Kind;
use crate::viewer::State;

/// How long the controls stay without the pointer moving.
const CONTROLS_FOR: Duration = Duration::from_millis(2500);
const TICK: f64 = 0.25;

pub struct Presentation {
    pub slideshow: bool,
    paused: Cell<bool>,
    /// Seconds the photo shown has shown.
    elapsed: Cell<f64>,
    /// The slideshow's photos, as indices into the viewer's, and where it is in them.
    order: RefCell<Vec<usize>>,
    position: Cell<usize>,
    controls: gtk::Box,
    play: gtk::Button,
    last_motion: Cell<Instant>,
    /// Where the pointer was: GTK reports motion when the photo under a still pointer changes, which is not a move.
    pointer: Cell<(f64, f64)>,
    over_controls: Cell<bool>,
    settings_open: Cell<bool>,
    timer: RefCell<Option<glib::SourceId>>,
    motion: gtk::EventControllerMotion,
    fullscreen_handler: RefCell<Option<glib::SignalHandlerId>>,
}

pub fn is_on(state: &State) -> bool {
    state.presentation.borrow().is_some()
}

pub fn is_slideshow(state: &State) -> bool {
    state.presentation.borrow().as_ref().is_some_and(|shown| shown.slideshow)
}

/// Fill the screen with the viewer; with `slideshow`, step through the photos by themselves.
pub fn start(state: &Rc<State>, slideshow: bool) {
    if is_on(state) {
        stop(state);
    }
    let Some(window) = state.window.upgrade() else { return };
    let settings = Slideshow::load(settings::shared());
    let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |since| since.as_nanos() as u64);
    let order = presentation::order(state.tiles.borrow().len(), state.index.get(), settings.shuffle, seed);
    let controls = gtk::Box::builder().spacing(6).halign(gtk::Align::Center).valign(gtk::Align::End).margin_bottom(24).css_classes(["toolbar", "osd", "gallery-presentation-controls"]).build();
    let button = |icon: &str, tooltip: &str| gtk::Button::builder().icon_name(icon).tooltip_text(tooltip).css_classes(["circular"]).build();
    let exit = button("view-restore-symbolic", tr("Exit Full Screen"));
    let previous = button("media-skip-backward-symbolic", tr("Previous"));
    let play = button("media-playback-pause-symbolic", tr("Pause"));
    let next = button("media-skip-forward-symbolic", tr("Next"));
    let library = button("view-grid-symbolic", tr("Show in All Photos"));
    controls.append(&exit);
    controls.append(&previous);
    if slideshow {
        controls.append(&play);
    }
    controls.append(&next);
    if !matches!(state.kind, Kind::Library | Kind::Locked | Kind::Partner) {
        controls.append(&library);
    }
    let settings_button = gtk::MenuButton::builder().icon_name("emblem-system-symbolic").tooltip_text(tr("Slideshow Settings")).css_classes(["circular"]).build();
    if slideshow {
        controls.append(&settings_button);
    }
    let motion = gtk::EventControllerMotion::new();
    let shown = Rc::new(Presentation {
        slideshow,
        paused: Cell::new(false),
        elapsed: Cell::new(0.0),
        order: RefCell::new(order),
        position: Cell::new(0),
        controls: controls.clone(),
        play: play.clone(),
        last_motion: Cell::new(Instant::now()),
        pointer: Cell::new((f64::NAN, f64::NAN)),
        over_controls: Cell::new(false),
        settings_open: Cell::new(false),
        timer: RefCell::default(),
        motion: motion.clone(),
        fullscreen_handler: RefCell::default(),
    });
    settings_button.set_popover(Some(&settings_popover(state, &shown)));
    let weak = Rc::downgrade(state);
    let on = |button: &gtk::Button, run: fn(&Rc<State>)| {
        let weak = weak.clone();
        button.connect_clicked(move |_| {
            if let Some(state) = weak.upgrade() {
                run(&state);
            }
        });
    };
    on(&exit, stop);
    on(&previous, |state| step(state, -1));
    on(&next, |state| step(state, 1));
    on(&play, toggle_pause);
    on(&library, |state| {
        let (Some(window), Some(tile)) = (state.window.upgrade(), state.tile()) else { return };
        stop(state);
        window.close_viewer();
        window.show_in_library(&tile);
    });
    let hover = gtk::EventControllerMotion::new();
    let (entered, left) = (Rc::downgrade(&shown), Rc::downgrade(&shown));
    hover.connect_enter(move |_, _, _| {
        if let Some(shown) = entered.upgrade() {
            shown.over_controls.set(true);
        }
    });
    hover.connect_leave(move |_| {
        if let Some(shown) = left.upgrade() {
            shown.over_controls.set(false);
        }
    });
    controls.add_controller(hover);
    let (weak_state, weak_shown) = (Rc::downgrade(state), Rc::downgrade(&shown));
    motion.connect_motion(move |_, x, y| {
        let (Some(state), Some(shown)) = (weak_state.upgrade(), weak_shown.upgrade()) else { return };
        let (was_x, was_y) = shown.pointer.replace((x, y));
        if (x - was_x).abs() < 2.0 && (y - was_y).abs() < 2.0 {
            return;
        }
        shown.last_motion.set(Instant::now());
        shown.controls.set_visible(true);
        state.stage.set_cursor(None);
    });
    state.stage.add_controller(motion);
    state.stage.add_overlay(&controls);
    state.stage.add_css_class("gallery-presentation");
    state.toolbar.set_reveal_top_bars(false);
    // The photo alone: the details below it leave until the presentation ends.
    state.page_scroller.vadjustment().set_value(0.0);
    state.details_clamp.set_visible(false);
    state.previous.set_visible(false);
    state.next.set_visible(false);
    // Leaving full screen another way (the window's own key) ends it too.
    let weak = Rc::downgrade(state);
    let handler = window.connect_fullscreened_notify(move |window| {
        if let Some(state) = weak.upgrade().filter(|_| !window.is_fullscreen()) {
            stop(&state);
        }
    });
    shown.fullscreen_handler.replace(Some(handler));
    window.set_presenting(true);
    window.fullscreen();
    let weak = Rc::downgrade(state);
    let timer = glib::timeout_add_local(Duration::from_millis((TICK * 1000.0) as u64), move || tick(&weak));
    shown.timer.replace(Some(timer));
    state.presentation.replace(Some(shown));
    state.scrolled.grab_focus();
    // Videos play once in a slideshow, so it can move on.
    if let Some(stream) = state.video.media_stream() {
        stream.set_loop(false);
    }
}

pub fn stop(state: &Rc<State>) {
    let Some(shown) = state.presentation.take() else { return };
    if let Some(timer) = shown.timer.take() {
        timer.remove();
    }
    if let Some(window) = state.window.upgrade() {
        if let Some(handler) = shown.fullscreen_handler.take() {
            window.disconnect(handler);
        }
        window.unfullscreen();
        window.set_presenting(false);
    }
    state.stage.remove_overlay(&shown.controls);
    state.stage.remove_controller(&shown.motion);
    state.stage.remove_css_class("gallery-presentation");
    state.stage.set_cursor(None);
    state.toolbar.set_reveal_top_bars(true);
    state.details_clamp.set_visible(true);
    state.picture.set_opacity(1.0);
    state.refresh_steps();
    state.scrolled.grab_focus();
}

/// The next or previous photo: in a slideshow, in its order (it pauses at the last); else in the viewer's.
pub fn step(state: &Rc<State>, by: i32) {
    let Some(shown) = state.presentation.borrow().clone().filter(|shown| shown.slideshow) else {
        state.step(by);
        return;
    };
    let order = shown.order.borrow().clone();
    let position = shown.position.get() as i64 + i64::from(by);
    if position < 0 {
        return;
    }
    let Some(index) = order.get(position as usize) else {
        set_paused(&shown, true);
        return;
    };
    shown.position.set(position as usize);
    shown.elapsed.set(0.0);
    state.index.set(*index);
    state.show();
}

pub fn toggle_pause(state: &Rc<State>) {
    if let Some(shown) = state.presentation.borrow().clone().filter(|shown| shown.slideshow) {
        set_paused(&shown, !shown.paused.get());
    }
}

fn set_paused(shown: &Presentation, paused: bool) {
    shown.paused.set(paused);
    shown.elapsed.set(0.0);
    shown.play.set_icon_name(if paused { "media-playback-start-symbolic" } else { "media-playback-pause-symbolic" });
    shown.play.set_tooltip_text(Some(if paused { tr("Play") } else { tr("Pause") }));
}

/// A photo has just been shown: its time starts, and a slideshow that fades fades it in.
pub fn shown(state: &Rc<State>) {
    let Some(shown) = state.presentation.borrow().clone() else { return };
    shown.elapsed.set(0.0);
    if shown.slideshow && Slideshow::load(settings::shared()).fade {
        let target = adw::PropertyAnimationTarget::new(&state.picture, "opacity");
        adw::TimedAnimation::builder().widget(&state.picture).value_from(0.0).value_to(1.0).duration(350).target(&target).build().play();
    }
}

fn tick(weak: &Weak<State>) -> glib::ControlFlow {
    let Some(state) = weak.upgrade() else { return glib::ControlFlow::Break };
    let Some(shown) = state.presentation.borrow().clone() else { return glib::ControlFlow::Break };
    if shown.last_motion.get().elapsed() > CONTROLS_FOR && !shown.over_controls.get() && !shown.settings_open.get() && shown.controls.is_visible() {
        shown.controls.set_visible(false);
        state.stage.set_cursor_from_name(Some("none"));
    }
    if !shown.slideshow || shown.paused.get() || shown.settings_open.get() {
        return glib::ControlFlow::Continue;
    }
    let settings = Slideshow::load(settings::shared());
    shown.elapsed.set(shown.elapsed.get() + TICK);
    let is_video = state.tile().is_some_and(|tile| tile.is_video);
    let due = if is_video && !settings.limit_videos {
        // A video plays to its end; one that never starts gives up after a while.
        let stream = state.video.media_stream();
        stream.as_ref().is_some_and(|stream| stream.is_ended()) || (shown.elapsed.get() >= VIDEO_PATIENCE && !stream.is_some_and(|stream| stream.is_playing()))
    } else {
        shown.elapsed.get() >= settings.interval
    };
    if due {
        step(&state, 1);
    }
    glib::ControlFlow::Continue
}

/// The slideshow's settings: the interval, shuffle, fade, and whether videos keep to the interval.
fn settings_popover(state: &Rc<State>, shown: &Rc<Presentation>) -> gtk::Popover {
    let current = Slideshow::load(settings::shared());
    let labels: Vec<String> = INTERVALS.iter().map(|seconds| tr("{count} seconds").replace("{count}", &seconds.to_string())).collect();
    let names: Vec<&str> = labels.iter().map(String::as_str).collect();
    let interval = gtk::DropDown::from_strings(&names);
    interval.set_valign(gtk::Align::Center);
    interval.set_selected(INTERVALS.iter().position(|seconds| f64::from(*seconds) == current.interval).unwrap_or(2) as u32);
    let interval_row = adw::ActionRow::builder().title(tr("Interval")).build();
    interval_row.add_suffix(&interval);
    let shuffle = adw::SwitchRow::builder().title(tr("Shuffle")).active(current.shuffle).build();
    let fade = adw::SwitchRow::builder().title(tr("Fade Transition")).active(current.fade).build();
    let limit = adw::SwitchRow::builder().title(tr("Limit Videos to Slide Interval")).subtitle(tr("Videos otherwise play to the end. Space pauses or resumes.")).active(current.limit_videos).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).width_request(340).build();
    for row in [interval_row.upcast_ref::<gtk::Widget>(), shuffle.upcast_ref(), fade.upcast_ref(), limit.upcast_ref()] {
        list.append(row);
    }
    let save = {
        let (interval, shuffle, fade, limit) = (interval.clone(), shuffle.clone(), fade.clone(), limit.clone());
        move || {
            let chosen = Slideshow {
                interval: f64::from(INTERVALS.get(interval.selected() as usize).copied().unwrap_or(5)),
                shuffle: shuffle.is_active(),
                fade: fade.is_active(),
                limit_videos: limit.is_active(),
            };
            chosen.save(settings::shared());
        }
    };
    let saved = save.clone();
    interval.connect_selected_notify(move |_| saved());
    let saved = save.clone();
    fade.connect_active_notify(move |_| saved());
    let saved = save.clone();
    limit.connect_active_notify(move |_| saved());
    // Shuffling anew starts the order again from the photo shown.
    let (weak_state, weak_shown) = (Rc::downgrade(state), Rc::downgrade(shown));
    shuffle.connect_active_notify(move |shuffle| {
        save();
        let (Some(state), Some(shown)) = (weak_state.upgrade(), weak_shown.upgrade()) else { return };
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |since| since.as_nanos() as u64);
        shown.order.replace(presentation::order(state.tiles.borrow().len(), state.index.get(), shuffle.is_active(), seed));
        shown.position.set(0);
    });
    let popover = gtk::Popover::builder().child(&list).build();
    let (opened, closed) = (Rc::downgrade(shown), Rc::downgrade(shown));
    popover.connect_show(move |_| {
        if let Some(shown) = opened.upgrade() {
            shown.settings_open.set(true);
        }
    });
    popover.connect_closed(move |_| {
        if let Some(shown) = closed.upgrade() {
            shown.settings_open.set(false);
            shown.last_motion.set(Instant::now());
        }
    });
    popover
}
