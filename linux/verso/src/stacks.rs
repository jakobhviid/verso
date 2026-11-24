//! A stack's own page: its photos, the primary first, read from the server each time it is shown or changed. As in
//! the Mac gallery's stack browser, the photo selected can be made the primary, taken out of the stack, or kept while
//! the others go to Recently Deleted; Unstack shows every photo on its own again.

use std::cell::RefCell;
use std::rc::Rc;

use gtk::gio;
use gtk::prelude::*;
use verso_desktop::library::Source;
use verso_desktop::text;
use verso_linux::i18n::tr;

use crate::grid::{Grid, WeakGrid};
use crate::pages::{self, Kind, Spec};
use crate::window::Window;

/// What a menu item does: to the window's stack shown in the grid.
type StackAction = fn(&Window, &str, &Grid);

/// Push the stack's page.
pub fn show_stack(window: &Window, stack_id: &str) {
    let mut spec = Spec::new(tr("Stack"), Source::Stack(stack_id.to_owned()), Kind::Plain).empty(tr("The Stack Is Empty"), "view-paged-symbolic");
    let menu = gio::Menu::new();
    menu.append(Some(tr("Set as Primary")), Some("page.primary"));
    menu.append(Some(tr("Remove from Stack")), Some("page.take-out"));
    menu.append(Some(tr("Move Others to Recently Deleted…")), Some("page.trash-others"));
    menu.append(Some(tr("Unstack")), Some("page.unstack"));
    spec.menu = Some(menu);
    let shown_grid: Rc<RefCell<Option<WeakGrid>>> = Rc::default();
    let actions: [(&str, StackAction); 4] = [("primary", set_primary), ("take-out", take_out), ("trash-others", trash_others), ("unstack", unstack)];
    for (name, act) in actions {
        let action = gio::SimpleAction::new(name, None);
        let (weak_window, stack_id, shown_grid) = (window.downgrade(), stack_id.to_owned(), shown_grid.clone());
        action.connect_activate(move |_, _| {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(grid) = shown_grid.borrow().as_ref().and_then(WeakGrid::upgrade) else { return };
            act(&window, &stack_id, &grid);
        });
        spec.actions.push(action);
    }
    let (page, grid) = pages::grid_page(window, spec);
    shown_grid.replace(grid.as_ref().map(Grid::downgrade));
    window.push_page(&page);
}

/// The stack's primary: the first photo of its page.
fn primary(grid: &Grid) -> Option<String> {
    grid.tiles().first().map(|tile| tile.id.clone())
}

fn set_primary(window: &Window, stack_id: &str, grid: &Grid) {
    let selected = grid.selected_ids();
    let [id] = selected.as_slice() else { return window.toast(tr("Select the one photo the stack should show")) };
    if primary(grid).as_ref() == Some(id) {
        return window.toast(tr("That photo is the primary already"));
    }
    let Some(session) = window.session() else { return };
    let (client, stack_id, id, shown) = (session.connection.client.clone(), stack_id.to_owned(), id.clone(), window.clone());
    crate::tasks::run(async move { client.set_stack_primary(&stack_id, &id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
        Ok(_) => {
            shown.toast(tr("The stack shows that photo now"));
            // The Library behind shows the stack by its primary: every grid reads again, this page too.
            shown.reload_grids();
        }
        Err(message) => shown.toast(&message),
    });
}

fn take_out(window: &Window, stack_id: &str, grid: &Grid) {
    let selected = grid.selected_ids();
    if selected.is_empty() {
        return window.toast(tr("Select the photos to take out of the stack"));
    }
    if primary(grid).is_some_and(|primary| selected.contains(&primary)) {
        return window.toast(tr("The primary photo stays: make another one the primary first"));
    }
    if grid.tiles().len() < selected.len() + 2 {
        return window.toast(tr("A stack keeps two photos at least: Unstack takes them all apart"));
    }
    let Some(session) = window.session() else { return };
    let (client, stack_id, shown) = (session.connection.client.clone(), stack_id.to_owned(), window.clone());
    let count = selected.len();
    crate::tasks::run(
        async move {
            for id in &selected {
                client.remove_from_stack(&stack_id, id).await.map_err(|error| verso_desktop::errors::said(&error))?;
            }
            Ok::<_, String>(())
        },
        move |outcome| {
            match outcome {
                Ok(()) => shown.toast(&tr("Took {items} out of the stack").replace("{items}", &text::items(count as u64))),
                Err(message) => shown.toast(&message),
            }
            // Some may have gone before a failure: read what is there.
            shown.reload_grids();
        },
    );
}

fn trash_others(window: &Window, stack_id: &str, grid: &Grid) {
    let selected = grid.selected_ids();
    let [keep] = selected.as_slice() else { return window.toast(tr("Select the one photo to keep")) };
    let others: Vec<String> = grid.tiles().into_iter().map(|tile| tile.id).filter(|id| id != keep).collect();
    if others.is_empty() {
        return;
    }
    let heading = tr("Move {items} to Recently Deleted?").replace("{items}", &text::items(others.len() as u64));
    let is_primary = primary(grid).as_ref() == Some(keep);
    let (weak_window, stack_id, keep) = (window.downgrade(), stack_id.to_owned(), keep.clone());
    crate::dialogs::confirm(
        window,
        &heading,
        tr("The stack keeps only the photo selected. The others can be restored from Recently Deleted until the trash is emptied."),
        tr("Move to Trash"),
        true,
        move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let (client, stack_id, keep, others, shown) = (session.connection.client.clone(), stack_id.clone(), keep.clone(), others.clone(), window.clone());
            crate::tasks::run(
                async move {
                    // The one kept becomes the primary first, so the stack never shows a photo in the trash.
                    if !is_primary {
                        client.set_stack_primary(&stack_id, &keep).await.map_err(|error| verso_desktop::errors::said(&error))?;
                    }
                    verso_desktop::actions::trash(&client, others).await
                },
                move |outcome| match outcome {
                    Ok(()) => {
                        shown.toast(tr("Kept one photo; the others are in Recently Deleted"));
                        shown.reopen_section(&shown.shown_section());
                    }
                    Err(message) => {
                        shown.toast(&message);
                        shown.reload_grids();
                    }
                },
            );
        },
    );
}

fn unstack(window: &Window, stack_id: &str, _grid: &Grid) {
    let Some(session) = window.session() else { return };
    let (client, stack_id, shown) = (session.connection.client.clone(), stack_id.to_owned(), window.clone());
    crate::tasks::run(async move { client.delete_stack(&stack_id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
        Ok(()) => {
            shown.toast(tr("Unstacked: each photo shows on its own again"));
            shown.reopen_section(&shown.shown_section());
        }
        Err(message) => shown.toast(&message),
    });
}
