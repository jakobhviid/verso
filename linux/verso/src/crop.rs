//! Cropping a photo, as the Mac gallery does: a rectangle dragged on the unedited preview, kept as an edit in Immich
//! (`actions::set_crop`) so the original stays as it is, and its turns and mirrors stay too.

use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;
use immich_api::ThumbnailSize;
use verso_desktop::actions::{self, Crop};
use verso_linux::i18n::tr;

use crate::window::Window;

/// The picture is shown no larger than this.
const WIDEST: f64 = 640.0;
const TALLEST: f64 = 420.0;

/// A rectangle as fractions of the picture: left, top, width, height.
type Fraction = (f64, f64, f64, f64);
const WHOLE: Fraction = (0.0, 0.0, 1.0, 1.0);

/// Open the crop dialog for a photo; `saved` runs once the crop is in Immich.
pub fn crop_dialog(window: &Window, id: &str, saved: impl Fn() + 'static) {
    let Some(session) = window.session() else { return };
    let (client, id, me) = (session.connection.client.clone(), id.to_owned(), session.connection.user_id().map(str::to_owned));
    let shown = window.clone();
    crate::tasks::run(
        {
            let id = id.clone();
            async move {
                let details = client.asset_details(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                let edits = client.asset_edits(&id).await.map_err(|error| verso_desktop::errors::said(&error))?;
                // The unedited picture: the rectangle is in the original's pixels.
                let (bytes, _) = client.thumbnail(&id, ThumbnailSize::Preview).await.map_err(|error| verso_desktop::errors::said(&error))?;
                // Decoded at the size shown, so the picture and the frame drawn on it are one size.
                let picture = verso_desktop::images::decode_within(&bytes, WIDEST as u32, TALLEST as u32)?;
                Ok::<_, String>((details, edits, picture))
            }
        },
        move |outcome| {
            let (details, edits, picture) = match outcome {
                Ok(read) => read,
                Err(message) => return shown.toast(&message),
            };
            if !actions::can_edit_picture(&details, me.as_deref()) {
                return shown.toast(tr("Only your own still photos can be cropped here"));
            }
            let Some((width, height)) = actions::upright_size(&details) else { return };
            let start = actions::crop_of(&edits).map_or(WHOLE, |crop| {
                (f64::from(crop.x) / f64::from(width), f64::from(crop.y) / f64::from(height), f64::from(crop.width) / f64::from(width), f64::from(crop.height) / f64::from(height))
            });
            present(&shown, id, (width, height), crate::textures::texture(picture), start, saved);
        },
    );
}

/// Where a picture of shape `ratio` sits when fitted into `width` by `height`: left, top, width, height.
fn fitted(width: f64, height: f64, ratio: f64) -> (f64, f64, f64, f64) {
    if width / height.max(1.0) > ratio {
        let shown = height * ratio;
        ((width - shown) / 2.0, 0.0, shown, height)
    } else {
        let shown = width / ratio;
        (0.0, (height - shown) / 2.0, width, shown)
    }
}

fn present(window: &Window, id: String, size: (u32, u32), texture: gtk::gdk::Texture, start: Fraction, saved: impl Fn() + 'static) {
    let ratio = f64::from(texture.width()) / f64::from(texture.height().max(1));
    let chosen = Rc::new(Cell::new(start));

    let picture = gtk::Picture::builder().paintable(&texture).content_fit(gtk::ContentFit::Contain).can_shrink(false).build();
    let canvas = gtk::DrawingArea::new();
    let overlay = gtk::Overlay::builder().child(&picture).halign(gtk::Align::Center).valign(gtk::Align::Center).build();
    overlay.add_overlay(&canvas);
    overlay.update_property(&[gtk::accessible::Property::Label(tr("The photo, with the crop drawn on it"))]);

    // The crop: a white frame over a light veil, as the Mac gallery draws it, the rest dimmed.
    let drawn = chosen.clone();
    canvas.set_draw_func(move |_, context, width, height| {
        let (left, top, wide, high) = drawn.get();
        let (origin_x, origin_y, width, height) = fitted(f64::from(width), f64::from(height), ratio);
        let (x, y, w, h) = (origin_x + left * width, origin_y + top * height, wide * width, high * height);
        context.set_source_rgba(0.0, 0.0, 0.0, 0.45);
        context.set_fill_rule(gtk::cairo::FillRule::EvenOdd);
        context.rectangle(origin_x, origin_y, width, height);
        context.rectangle(x, y, w, h);
        let _ = context.fill();
        context.set_fill_rule(gtk::cairo::FillRule::Winding);
        context.set_source_rgba(1.0, 1.0, 1.0, 0.12);
        context.rectangle(x, y, w, h);
        let _ = context.fill_preserve();
        context.set_source_rgba(1.0, 1.0, 1.0, 1.0);
        context.set_line_width(2.0);
        let _ = context.stroke();
    });
    let drag = gtk::GestureDrag::new();
    let (weak_canvas, dragged) = (canvas.downgrade(), chosen.clone());
    drag.connect_drag_update(move |gesture, offset_x, offset_y| {
        let (Some(canvas), Some((start_x, start_y))) = (weak_canvas.upgrade(), gesture.start_point()) else { return };
        let (origin_x, origin_y, width, height) = fitted(f64::from(canvas.width().max(1)), f64::from(canvas.height().max(1)), ratio);
        let clamp = |value: f64| value.clamp(0.0, 1.0);
        let (from_x, from_y) = (clamp((start_x - origin_x) / width), clamp((start_y - origin_y) / height));
        let (to_x, to_y) = (clamp((start_x + offset_x - origin_x) / width), clamp((start_y + offset_y - origin_y) / height));
        if (from_x - to_x).abs() * width < 2.0 && (from_y - to_y).abs() * height < 2.0 {
            return;
        }
        dragged.set((from_x.min(to_x), from_y.min(to_y), (from_x - to_x).abs(), (from_y - to_y).abs()));
        canvas.queue_draw();
    });
    canvas.add_controller(drag);

    let caption = gtk::Label::builder()
        .label(tr("Drag a rectangle on the unedited photo. Its turns and mirrors stay as they are."))
        .wrap(true)
        .xalign(0.0)
        .css_classes(["dim-label"])
        .build();
    let reset = gtk::Button::with_label(tr("Reset Crop"));
    let cancel = gtk::Button::with_label(tr("Cancel"));
    let save = gtk::Button::builder().label(tr("Save")).css_classes(["suggested-action"]).build();
    let buttons = gtk::Box::builder().spacing(12).build();
    buttons.append(&reset);
    buttons.append(&gtk::Box::builder().hexpand(true).build());
    buttons.append(&cancel);
    buttons.append(&save);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(18).margin_start(18).margin_end(18).build();
    content.append(&caption);
    content.append(&overlay);
    content.append(&buttons);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::builder().show_end_title_buttons(false).build());
    toolbar.set_content(Some(&content));
    let dialog = adw::Dialog::builder().title(tr("Crop")).child(&toolbar).build();
    dialog.set_default_widget(Some(&save));

    let (weak_canvas, reset_to) = (canvas.downgrade(), chosen.clone());
    reset.connect_clicked(move |_| {
        reset_to.set(WHOLE);
        if let Some(canvas) = weak_canvas.upgrade() {
            canvas.queue_draw();
        }
    });
    let weak_dialog = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
    });
    let (weak_dialog, weak_window, saved) = (dialog.downgrade(), window.downgrade(), Rc::new(saved));
    save.connect_clicked(move |button| {
        let (Some(dialog), Some(window)) = (weak_dialog.upgrade(), weak_window.upgrade()) else { return };
        if chosen.get() == start {
            dialog.close();
            return;
        }
        let Some(session) = window.session() else { return };
        let crop: Option<Crop> = actions::crop_in_pixels(chosen.get(), size.0, size.1);
        let (client, id, saved, shown) = (session.connection.client.clone(), id.clone(), saved.clone(), window.clone());
        button.set_sensitive(false);
        let weak_button = button.downgrade();
        crate::tasks::run(async move { actions::set_crop(&client, id, crop).await }, move |outcome| match outcome {
            Ok(()) => {
                dialog.close();
                saved();
            }
            Err(message) => {
                if let Some(button) = weak_button.upgrade() {
                    button.set_sensitive(true);
                }
                shown.toast(&message);
            }
        });
    });
    dialog.present(Some(window));
}
