//! The timeline's scrubber, as Immich's web app and the Mac gallery have one: a strip at the grid's right edge with
//! the years down it, each month a dot, the mark where the grid is; pointing at it names the month, and a click or a
//! drag goes to exactly the place it points at, partway into a month as readily as to its start. Where each month is
//! on it, and the place a point stands for, is the core's date scroller (`verso_core::rail`), as on the Mac and the
//! iPhone: each month takes the room the grid gives it, its heading and its rows, so the strip follows the grid.

use std::cell::{Cell, RefCell};

use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, glib, graphene};
use immich_api::YearMonth;
use verso_core::rail::{Place, Rail, Shape};
use verso_desktop::text;
use verso_linux::i18n::tr;

/// What a click or a drag runs, with the place it points at.
type Jump = Box<dyn Fn(Place)>;

/// The strip's width.
pub const WIDTH: i32 = 64;
const PAD: f32 = 10.0;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Scrubber {
        /// The months, in the grid's order, and how many photos each holds.
        pub months: RefCell<Vec<(YearMonth, u32)>>,
        /// How the grid lays them out; how much of it is in view is the strip's own height.
        pub shape: Cell<Option<Shape>>,
        /// Where the grid is: the place at its top.
        pub current: Cell<Option<Place>>,
        /// Where the pointer is, while it is over the strip.
        pub hover: Cell<Option<f32>>,
        /// The month and row last jumped to, so a drag asks again only when it reaches another row.
        pub last_jump: Cell<Option<(usize, Option<u32>)>>,
        pub on_jump: RefCell<Option<Jump>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Scrubber {
        const NAME: &'static str = "GalleryScrubber";
        type Type = super::Scrubber;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for Scrubber {}

    impl WidgetImpl for Scrubber {
        fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            match orientation {
                gtk::Orientation::Horizontal => (WIDTH, WIDTH, -1, -1),
                _ => (0, 0, -1, -1),
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let widget = self.obj();
            let months = self.months.borrow();
            let (width, height) = (widget.width() as f32, widget.height() as f32);
            if months.len() < 2 || height < 4.0 * PAD {
                return;
            }
            let Some(rail) = widget.rail() else { return };
            let ink = widget.color();
            let dim = gdk::RGBA::new(ink.red(), ink.green(), ink.blue(), 0.55);
            let faint = gdk::RGBA::new(ink.red(), ink.green(), ink.blue(), 0.3);
            let accent = adw::StyleManager::default().accent_color_rgba();
            // Each month a dot; each year its label, where it has room.
            for top in rail.tops() {
                snapshot.append_color(&faint, &graphene::Rect::new(width - 9.0, super::strip_y(height, top), 3.0, 2.0));
            }
            let label_height = widget.create_pango_layout(Some("2000")).pixel_size().1 as f32;
            for mark in rail.year_marks(f64::from(super::span(height)), f64::from(label_height + 2.0)) {
                let label = if mark.now { tr("Now").to_owned() } else { mark.year.to_string() };
                let layout = widget.create_pango_layout(Some(&label));
                let (text_width, text_height) = layout.pixel_size();
                let y = super::strip_y(height, mark.fraction);
                snapshot.save();
                snapshot.translate(&graphene::Point::new(width - 14.0 - text_width as f32, (y - text_height as f32 / 2.0).max(0.0)));
                snapshot.append_layout(&layout, &dim);
                snapshot.restore();
            }
            if let Some(place) = self.current.get() {
                let y = super::strip_y(height, rail.fraction_of(place));
                snapshot.append_color(&accent, &graphene::Rect::new(width - 22.0, y - 1.0, 22.0, 3.0));
            }
            if let Some(y) = self.hover.get() {
                snapshot.append_color(&ink, &graphene::Rect::new(0.0, y - 0.5, width, 1.0));
                if let Some((month, _)) = rail.month_at(super::fraction_at(height, y)).and_then(|index| months.get(index)) {
                    let layout = widget.create_pango_layout(Some(&text::month_title(*month)));
                    let (text_width, text_height) = layout.pixel_size();
                    // Left of the strip, over the grid, so a long month's name reads whole.
                    let (box_width, box_height) = (text_width as f32 + 12.0, text_height as f32 + 4.0);
                    let top = (y - box_height / 2.0).clamp(0.0, (height - box_height).max(0.0));
                    let left = -box_width - 4.0;
                    let background = gsk_rounded(left, top, box_width, box_height);
                    snapshot.push_rounded_clip(&background);
                    snapshot.append_color(&accent, &graphene::Rect::new(left, top, box_width, box_height));
                    snapshot.pop();
                    snapshot.save();
                    snapshot.translate(&graphene::Point::new(left + 6.0, top + 2.0));
                    snapshot.append_layout(&layout, &gdk::RGBA::WHITE);
                    snapshot.restore();
                }
            }
        }
    }

    fn gsk_rounded(left: f32, top: f32, width: f32, height: f32) -> gtk::gsk::RoundedRect {
        gtk::gsk::RoundedRect::from_rect(graphene::Rect::new(left, top, width, height), height / 2.0)
    }
}

glib::wrapper! {
    pub struct Scrubber(ObjectSubclass<imp::Scrubber>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

/// How long the months' part of a strip of `height` is, between its pads.
fn span(height: f32) -> f32 {
    (height - 2.0 * PAD).max(1.0)
}

/// Where a point of the scroller (a fraction, `verso_core::rail`) is down a strip of `height`.
fn strip_y(height: f32, fraction: f64) -> f32 {
    PAD + fraction as f32 * span(height)
}

/// The point of the scroller at `y` down a strip of `height`.
fn fraction_at(height: f32, y: f32) -> f64 {
    f64::from(((y - PAD) / span(height)).clamp(0.0, 1.0))
}

impl Scrubber {
    pub fn new() -> Scrubber {
        let scrubber: Scrubber = glib::Object::builder().property("halign", gtk::Align::End).property("valign", gtk::Align::Fill).property("visible", false).build();
        scrubber.set_cursor_from_name(Some("pointer"));
        let motion = gtk::EventControllerMotion::new();
        motion.connect_motion(|controller, _, y| {
            if let Some(scrubber) = controller.widget().and_downcast::<Scrubber>() {
                scrubber.imp().hover.set(Some(y as f32));
                scrubber.queue_draw();
            }
        });
        motion.connect_leave(|controller| {
            if let Some(scrubber) = controller.widget().and_downcast::<Scrubber>() {
                scrubber.imp().hover.set(None);
                scrubber.queue_draw();
            }
        });
        scrubber.add_controller(motion);
        let drag = gtk::GestureDrag::new();
        drag.connect_drag_begin(|gesture, _, y| {
            if let Some(scrubber) = gesture.widget().and_downcast::<Scrubber>() {
                scrubber.imp().last_jump.set(None);
                scrubber.jump(y as f32);
            }
        });
        drag.connect_drag_update(|gesture, _, dy| {
            let (Some(scrubber), Some((_, y))) = (gesture.widget().and_downcast::<Scrubber>(), gesture.start_point()) else { return };
            let y = (y + dy) as f32;
            scrubber.imp().hover.set(Some(y));
            scrubber.jump(y);
        });
        scrubber.add_controller(drag);
        scrubber
    }

    /// The months as the grid lays them out, with the strip's height in view.
    fn rail(&self) -> Option<Rail> {
        let shape = self.imp().shape.get()?;
        Some(Rail::new(&self.imp().months.borrow(), Shape { viewport: f64::from(self.height()), ..shape }))
    }

    fn jump(&self, y: f32) {
        let Some(place) = self.rail().and_then(|rail| rail.place_at(fraction_at(self.height() as f32, y))) else { return };
        if self.imp().last_jump.replace(Some((place.month, place.row))) == Some((place.month, place.row)) {
            return;
        }
        self.imp().current.set(Some(place));
        self.queue_draw();
        if let Some(on_jump) = self.imp().on_jump.borrow().as_ref() {
            on_jump(place);
        }
    }

    /// The timeline's months, and how the grid lays them out: how many photos a row holds, a row's height with the
    /// space below it, and a month's heading. Fewer than two months hide the strip.
    pub fn set_months(&self, months: Vec<(YearMonth, u32)>, columns: u32, row_height: f64, header_height: f64) {
        self.set_visible(months.len() >= 2);
        self.imp().months.replace(months);
        self.imp().shape.set(Some(Shape { columns, row_height, header_height, viewport: 0.0, flows: false }));
        self.queue_draw();
    }

    /// How many photos a row holds, as the strip reckons the grid's rows.
    pub fn columns(&self) -> u32 {
        self.imp().shape.get().map_or(1, |shape| shape.columns.max(1))
    }

    /// A row's height with the space below it, as the strip reckons the grid's rows.
    pub fn row_height(&self) -> f64 {
        self.imp().shape.get().map_or(0.0, |shape| shape.row_height)
    }

    /// Where the grid is: the place at its top.
    pub fn set_current(&self, place: Option<Place>) {
        if self.imp().current.replace(place) != place {
            self.queue_draw();
        }
    }

    /// Run `handler` with the place the strip is clicked or dragged to.
    pub fn connect_jump(&self, handler: impl Fn(Place) + 'static) {
        self.imp().on_jump.replace(Some(Box::new(handler)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_strip_runs_between_its_pads_and_back() {
        assert_eq!(strip_y(120.0, 0.0), PAD);
        assert_eq!(strip_y(120.0, 1.0), 120.0 - PAD);
        assert_eq!(fraction_at(120.0, 60.0), 0.5);
        assert_eq!(fraction_at(120.0, 0.0), 0.0, "above the first month, the grid's top");
        assert_eq!(fraction_at(120.0, 200.0), 1.0, "below the last, its end");
        assert_eq!(span(10.0), 1.0, "a strip too short for its pads still has a place for each point");
    }
}
