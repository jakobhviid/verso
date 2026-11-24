//! Motion around the viewer, as the Mac gallery has it: the open photo zooms out of its grid square into the viewer
//! and back into its square as the viewer closes, while the page it leaves fades; and stepping to the next photo
//! slides it in, a touchpad swipe following the fingers (`Slide`). Only what the user does to what is on screen moves:
//! pages switch in place, the viewer's too.

use std::cell::{Cell, RefCell};

use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, glib, graphene};

/// The zoom's spring: the Mac's `.smooth(duration: 0.35)`, critically damped, so it settles without bouncing.
fn zoom_spring() -> adw::SpringParams {
    adw::SpringParams::new(1.0, 1.0, (2.0 * std::f64::consts::PI / 0.35).powi(2))
}

/// A slide from one photo to the next, on the Mac's curve (`ViewerSlider`) but longer than its 0.36 s, which moves
/// three quarters of the way in the first tenth of a second and read as too fast here.
pub const SLIDE_MS: u32 = 480;

/// A swipe's finish, from where the fingers left the photo, at most: shorter than a slide, as on the Mac (0.3 s there).
pub const SWIPE_MS: u32 = 400;

/// The Mac's slide curve, a cubic Bézier through (0.25, 0.8) and (0.3, 1), at `t` from 0 to 1.
pub fn slide_curve(t: f64) -> f64 {
    cubic_bezier((0.25, 0.8), (0.3, 1.0), t)
}

/// A CSS-style cubic Bézier easing from (0, 0) to (1, 1) through two control points, at `t`.
fn cubic_bezier((x1, y1): (f64, f64), (x2, y2): (f64, f64), t: f64) -> f64 {
    let curve = |a: f64, b: f64, s: f64| {
        let u = 1.0 - s;
        3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s
    };
    let slope = |a: f64, b: f64, s: f64| {
        let u = 1.0 - s;
        3.0 * u * u * a + 6.0 * u * s * (b - a) + 3.0 * s * s * (1.0 - b)
    };
    let t = t.clamp(0.0, 1.0);
    let mut s = t;
    for _ in 0..8 {
        let error = curve(x1, x2, s) - t;
        let rate = slope(x1, x2, s);
        if error.abs() < 1e-6 || rate.abs() < 1e-6 {
            break;
        }
        s = (s - error / rate).clamp(0.0, 1.0);
    }
    curve(y1, y2, s)
}

/// A still of what `widget` shows now, to fade out after it has gone. Drawn here, as its parent draws it: GTK's own
/// still of a widget (`WidgetPaintable::current_image`) came out empty for a page, which keeps no frame of its own.
pub fn still(widget: &impl IsA<gtk::Widget>) -> Option<gdk::Paintable> {
    let widget = widget.as_ref();
    let parent = widget.parent()?;
    let origin = widget.compute_point(&parent, &graphene::Point::zero())?;
    let snapshot = gtk::Snapshot::new();
    snapshot.translate(&graphene::Point::new(-origin.x(), -origin.y()));
    parent.snapshot_child(widget, &snapshot);
    snapshot.to_paintable(Some(&graphene::Size::new(widget.width() as f32, widget.height() as f32)))
}

/// The place a picture of `ratio` (width over height) takes when it fits inside `area`, centred.
pub fn contain(ratio: f64, area: &graphene::Rect) -> graphene::Rect {
    let ratio = if ratio > 0.0 { ratio as f32 } else { 1.0 };
    let (width, height) = if area.width() / area.height().max(1.0) > ratio { (area.height() * ratio, area.height()) } else { (area.width(), area.width() / ratio) };
    graphene::Rect::new(area.x() + (area.width() - width) / 2.0, area.y() + (area.height() - height) / 2.0, width, height)
}

/// Width over height of a paintable, when it has a size.
pub fn ratio_of(paintable: &gdk::Paintable) -> Option<f64> {
    let (width, height) = (paintable.intrinsic_width(), paintable.intrinsic_height());
    (width > 0 && height > 0).then(|| f64::from(width) / f64::from(height))
}

/// Draw `paintable` filling `rect`, cropped to it as a grid square crops its photo.
pub fn draw_cover(snapshot: &gtk::Snapshot, paintable: &gdk::Paintable, rect: &graphene::Rect) {
    let (width, height) = (paintable.intrinsic_width() as f32, paintable.intrinsic_height() as f32);
    if width <= 0.0 || height <= 0.0 || rect.width() <= 0.0 || rect.height() <= 0.0 {
        return;
    }
    let scale = (rect.width() / width).max(rect.height() / height);
    let (drawn_width, drawn_height) = (width * scale, height * scale);
    snapshot.push_clip(rect);
    snapshot.save();
    snapshot.translate(&graphene::Point::new(rect.x() + (rect.width() - drawn_width) / 2.0, rect.y() + (rect.height() - drawn_height) / 2.0));
    paintable.snapshot(snapshot, f64::from(drawn_width), f64::from(drawn_height));
    snapshot.restore();
    snapshot.pop();
}

fn mix(from: &graphene::Rect, to: &graphene::Rect, progress: f32) -> graphene::Rect {
    let at = |a: f32, b: f32| a + (b - a) * progress;
    graphene::Rect::new(at(from.x(), to.x()), at(from.y(), to.y()), at(from.width(), to.width()), at(from.height(), to.height()))
}

/// What the photo flies with: its picture, and where it lands, asked each frame, as the page under it lays out.
type Picture = Box<dyn Fn() -> Option<gdk::Paintable>>;
type Place = Box<dyn Fn() -> Option<graphene::Rect>>;

/// One zoom: the page left behind, fading out; the photo, from `from` to wherever `to` says.
pub struct Flight {
    pub backdrop: Option<gdk::Paintable>,
    pub photo: Picture,
    pub from: graphene::Rect,
    pub to: Place,
    /// Runs once the photo has landed (or the zoom was cut short): what was hidden for it shows again.
    pub done: Box<dyn FnOnce()>,
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct FlightLayer {
        pub flight: RefCell<Option<Flight>>,
        pub progress: Cell<f64>,
        pub animation: RefCell<Option<adw::Animation>>,
        /// Frames waited for the landing place, which the page under the layer has only once laid out.
        pub waited: Cell<u32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FlightLayer {
        const NAME: &'static str = "VersoFlightLayer";
        type Type = super::FlightLayer;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for FlightLayer {}

    impl WidgetImpl for FlightLayer {
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let flight = self.flight.borrow();
            let Some(flight) = flight.as_ref() else { return };
            let widget = self.obj();
            let progress = self.progress.get();
            // The page left behind, on the window's colour (its style's `color`): a page draws no background of its
            // own, and the one coming in showed through.
            if let Some(backdrop) = &flight.backdrop {
                let (width, height) = (widget.width() as f32, widget.height() as f32);
                snapshot.push_opacity(1.0 - progress);
                snapshot.append_color(&widget.color(), &graphene::Rect::new(0.0, 0.0, width, height));
                backdrop.snapshot(snapshot, f64::from(width), f64::from(height));
                snapshot.pop();
            }
            let Some(photo) = (flight.photo)() else { return };
            match (flight.to)() {
                Some(to) => draw_cover(snapshot, &photo, &mix(&flight.from, &to, progress as f32)),
                // Nowhere to land (its square is off screen): it fades where it is, with the page it left.
                None => {
                    snapshot.push_opacity(1.0 - progress);
                    draw_cover(snapshot, &photo, &flight.from);
                    snapshot.pop();
                }
            }
        }
    }
}

glib::wrapper! {
    /// The layer over the window's content where the photo flies between its square and the viewer.
    pub struct FlightLayer(ObjectSubclass<imp::FlightLayer>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for FlightLayer {
    fn default() -> Self {
        glib::Object::builder().property("can-target", false).property("visible", false).property("css-classes", glib::StrV::from(["verso-flight"])).build()
    }
}

impl FlightLayer {
    /// Fly `flight`; a zoom still running lands at once first.
    pub fn fly(&self, flight: Flight) {
        self.land();
        let imp = self.imp();
        imp.flight.replace(Some(flight));
        imp.progress.set(0.0);
        imp.waited.set(0);
        self.set_visible(true);
        self.queue_draw();
        // Off once the landing place is known: a page just shown lays out in the next frame or two.
        self.add_tick_callback(|layer, _| {
            let imp = layer.imp();
            let ready = imp.flight.borrow().as_ref().is_some_and(|flight| (flight.to)().is_some());
            if !ready && imp.waited.get() < 6 && imp.flight.borrow().is_some() {
                imp.waited.set(imp.waited.get() + 1);
                return glib::ControlFlow::Continue;
            }
            if imp.flight.borrow().is_some() {
                layer.take_off();
            }
            glib::ControlFlow::Break
        });
    }

    fn take_off(&self) {
        let weak = self.downgrade();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            if let Some(layer) = weak.upgrade() {
                layer.imp().progress.set(value);
                layer.queue_draw();
            }
        });
        let animation = adw::SpringAnimation::builder().widget(self).value_from(0.0).value_to(1.0).spring_params(&zoom_spring()).clamp(true).target(&target).build();
        let weak = self.downgrade();
        animation.connect_done(move |_| {
            if let Some(layer) = weak.upgrade() {
                layer.land();
            }
        });
        self.imp().animation.replace(Some(animation.clone().upcast()));
        animation.play();
    }

    /// End the zoom where it is going, and show what it hid.
    pub fn land(&self) {
        let imp = self.imp();
        imp.animation.replace(None);
        if let Some(flight) = imp.flight.take() {
            (flight.done)();
        }
        self.set_visible(false);
    }
}

/// A photo and its place on the stage, asked each frame: the photo coming in sharpens as its preview arrives.
type Placed = Box<dyn Fn() -> Option<(gdk::Paintable, graphene::Rect)>>;

/// One slide on the viewer's stage: the photo going out, and the one coming in from the side it is going to.
pub struct Slide {
    pub outgoing: Option<(gdk::Paintable, graphene::Rect)>,
    pub incoming: Placed,
    /// 1 when the next photo comes in from the right, -1 when the previous one comes in from the left.
    pub direction: f32,
}

mod slide_imp {
    use super::*;

    #[derive(Default)]
    pub struct SlideLayer {
        pub slide: RefCell<Option<Slide>>,
        /// 0 with the outgoing photo in place, 1 with the incoming one.
        pub progress: Cell<f64>,
        pub animation: RefCell<Option<adw::Animation>>,
        pub done: RefCell<Option<Box<dyn FnOnce()>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SlideLayer {
        const NAME: &'static str = "VersoSlideLayer";
        type Type = super::SlideLayer;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for SlideLayer {}

    impl WidgetImpl for SlideLayer {
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let slide = self.slide.borrow();
            let Some(slide) = slide.as_ref() else { return };
            let (width, progress) = (self.obj().width() as f32, self.progress.get() as f32);
            let draw = |placed: Option<(gdk::Paintable, graphene::Rect)>, shift: f32| {
                if let Some((paintable, rect)) = placed {
                    snapshot.save();
                    snapshot.translate(&graphene::Point::new(shift, 0.0));
                    draw_cover(snapshot, &paintable, &rect);
                    snapshot.restore();
                }
            };
            draw(slide.outgoing.clone(), -slide.direction * width * progress);
            draw((slide.incoming)(), slide.direction * width * (1.0 - progress));
        }
    }
}

glib::wrapper! {
    /// The layer on the viewer's stage where one photo slides out and the next in.
    pub struct SlideLayer(ObjectSubclass<slide_imp::SlideLayer>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for SlideLayer {
    fn default() -> Self {
        glib::Object::builder().property("can-target", false).property("visible", false).build()
    }
}

impl SlideLayer {
    /// Whether a slide is shown, running or held by a swipe.
    pub fn is_sliding(&self) -> bool {
        self.imp().slide.borrow().is_some()
    }

    /// Show `slide` at `progress`, still: a swipe moves it with the fingers. `done` runs when it ends.
    pub fn hold(&self, slide: Slide, progress: f64, done: Box<dyn FnOnce()>) {
        let imp = self.imp();
        imp.animation.replace(None);
        imp.slide.replace(Some(slide));
        imp.done.replace(Some(done));
        imp.progress.set(progress);
        self.set_visible(true);
        self.queue_draw();
    }

    pub fn progress(&self) -> f64 {
        self.imp().progress.get()
    }

    /// Run on from where the slide is to `to` (1 the incoming photo in place, 0 back) on the Mac's curve, in
    /// `duration` milliseconds, then end it.
    pub fn run(&self, to: f64, duration: u32) {
        let start = self.imp().progress.get();
        let weak = self.downgrade();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            if let Some(layer) = weak.upgrade() {
                layer.imp().progress.set(start + (to - start) * slide_curve(value));
                layer.queue_draw();
            }
        });
        let animation = adw::TimedAnimation::builder().widget(self).value_from(0.0).value_to(1.0).duration(duration).easing(adw::Easing::Linear).target(&target).build();
        let weak = self.downgrade();
        animation.connect_done(move |_| {
            if let Some(layer) = weak.upgrade() {
                layer.end();
            }
        });
        self.imp().animation.replace(Some(animation.clone().upcast()));
        animation.play();
    }

    /// End the slide where it is, and show the stage again.
    pub fn end(&self) {
        let imp = self.imp();
        imp.animation.replace(None);
        imp.slide.replace(None);
        if let Some(done) = imp.done.take() {
            done();
        }
        self.set_visible(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_slide_curve_starts_and_ends_in_place_and_eases_out() {
        assert!(slide_curve(0.0).abs() < 1e-9);
        assert!((slide_curve(1.0) - 1.0).abs() < 1e-9);
        // Fast at first: past three quarters of the way at half the time.
        assert!(slide_curve(0.5) > 0.75);
        let mut last = 0.0;
        for step in 1..=20 {
            let value = slide_curve(f64::from(step) / 20.0);
            assert!(value >= last);
            last = value;
        }
    }

    #[test]
    fn a_picture_fits_inside_its_area_centred() {
        let area = graphene::Rect::new(0.0, 0.0, 400.0, 200.0);
        let wide = contain(4.0, &area);
        assert_eq!((wide.x(), wide.y(), wide.width(), wide.height()), (0.0, 50.0, 400.0, 100.0));
        let tall = contain(0.5, &area);
        assert_eq!((tall.x(), tall.y(), tall.width(), tall.height()), (150.0, 0.0, 100.0, 200.0));
    }
}
