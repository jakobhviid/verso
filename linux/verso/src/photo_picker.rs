//! Choosing photos from the library to add to an album or a link: the Library's grid in a dialog, selecting from the
//! start, a click choosing or letting go of a photo; Add hands the photos chosen to whoever asked, Cancel or Escape
//! closes it. The way to add from where the photos go, beside Add to Album and Add to Public Link from the Library.

use std::cell::RefCell;

use adw::prelude::*;
use immich_api::TimelineScope;
use verso_desktop::library::Source;
use verso_linux::i18n::tr;

use crate::grid::Grid;
use crate::window::Window;

/// Choose photos from the library under `title`; `add` names the button that hands them to `chosen`.
pub fn pick_photos(window: &Window, title: &str, add: &str, chosen: impl Fn(Vec<String>) + 'static) {
    let Some(session) = window.session() else { return };
    let grid = Grid::new(session.connection.client.clone(), session.textures.clone(), Source::Timeline(TimelineScope::LibraryStacked), tr("No Photos Yet"), "image-x-generic-symbolic");
    grid.set_selecting(true);
    let heading = adw::WindowTitle::new(title, tr("Select Items"));
    let header = adw::HeaderBar::builder().title_widget(&heading).show_start_title_buttons(false).show_end_title_buttons(false).build();
    let cancel = gtk::Button::with_label(tr("Cancel"));
    let adding = gtk::Button::builder().label(add).sensitive(false).css_classes(["suggested-action"]).build();
    header.pack_start(&cancel);
    header.pack_end(&adding);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(grid.widget()));
    let dialog = adw::Dialog::builder().title(title).content_width(960).content_height(720).child(&toolbar).build();
    // Always choosing: a photo opens nothing here, and leaving selection mode (Escape on the grid) comes straight back.
    grid.on_open(|_, _| {});
    let (weak_grid, weak_heading, weak_adding) = (grid.downgrade(), heading.downgrade(), adding.downgrade());
    grid.on_selection_changed(move || {
        let Some(grid) = weak_grid.upgrade() else { return };
        if !grid.selecting() {
            grid.set_selecting(true);
            return;
        }
        let count = grid.selected_ids().len();
        if let Some(heading) = weak_heading.upgrade() {
            heading.set_subtitle(&match count {
                0 => tr("Select Items").to_owned(),
                1 => tr("1 Selected").to_owned(),
                count => tr("{count} Selected").replace("{count}", &count.to_string()),
            });
        }
        if let Some(adding) = weak_adding.upgrade() {
            adding.set_sensitive(count > 0);
        }
    });
    let weak_dialog = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(dialog) = weak_dialog.upgrade() {
            dialog.close();
        }
    });
    let (weak_dialog, weak_grid) = (dialog.downgrade(), grid.downgrade());
    adding.connect_clicked(move |_| {
        let (Some(dialog), Some(grid)) = (weak_dialog.upgrade(), weak_grid.upgrade()) else { return };
        let ids = grid.selected_ids();
        dialog.close();
        if !ids.is_empty() {
            chosen(ids);
        }
    });
    // The dialog keeps the grid while it is open, and lets it go as it closes.
    let held = RefCell::new(Some(grid));
    dialog.connect_closed(move |_| {
        held.borrow_mut().take();
    });
    dialog.present(Some(window));
}
