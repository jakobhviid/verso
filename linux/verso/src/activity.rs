//! Comments and likes in a shared album, on the album or on one photo in it: reading them, commenting, liking
//! (and taking the like back), and deleting one's own comments.

use adw::prelude::*;
use gtk::glib;
use immich_api::{Activity, ActivityFilter, ActivityKind};
use verso_linux::i18n::tr;

use crate::window::Window;

/// The dialog for an album's activity, or a photo's in it.
pub fn activity_dialog(window: &Window, album_id: &str, asset_id: Option<String>) {
    let dialog = adw::Dialog::builder().title(if asset_id.is_some() { tr("Comments on the Photo") } else { tr("Comments and Likes") }).content_width(420).content_height(560).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).valign(gtk::Align::Start).build();
    let likes = gtk::Label::builder().xalign(0.0).wrap(true).css_classes(["dim-label"]).build();
    let entry = gtk::Entry::builder().placeholder_text(tr("Add a comment")).hexpand(true).build();
    let send = gtk::Button::builder().icon_name("mail-send-symbolic").tooltip_text(tr("Send")).css_classes(["suggested-action"]).build();
    let like = gtk::ToggleButton::builder().label(tr("Like")).build();
    let empty = adw::StatusPage::builder().icon_name("chat-bubbles-text-symbolic").title(tr("No Comments Yet")).build();
    let stack = gtk::Stack::new();
    stack.add_named(&gtk::ScrolledWindow::builder().child(&list).vexpand(true).hscrollbar_policy(gtk::PolicyType::Never).build(), Some("list"));
    stack.add_named(&empty, Some("empty"));
    let compose = gtk::Box::builder().spacing(6).build();
    compose.append(&like);
    compose.append(&entry);
    compose.append(&send);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).margin_top(12).margin_bottom(12).margin_start(12).margin_end(12).build();
    content.append(&likes);
    content.append(&stack);
    content.append(&compose);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&content));
    dialog.set_child(Some(&toolbar));

    let reload = {
        let (weak_window, album_id, asset_id) = (window.downgrade(), album_id.to_owned(), asset_id.clone());
        let (weak_list, weak_likes, weak_like, weak_stack) = (list.downgrade(), likes.downgrade(), like.downgrade(), stack.downgrade());
        std::rc::Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let me = session.connection.user_id().map(str::to_owned);
            let client = session.connection.client.clone();
            let filter = ActivityFilter { asset_id: asset_id.clone(), album_level: Some(asset_id.is_none()), ..ActivityFilter::default() };
            let album_id = album_id.clone();
            let (weak_window, weak_list, weak_likes, weak_like, weak_stack) = (window.downgrade(), weak_list.clone(), weak_likes.clone(), weak_like.clone(), weak_stack.clone());
            crate::tasks::run(async move { client.activities(&album_id, &filter).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let (Some(window), Some(list), Some(likes), Some(like), Some(stack)) = (weak_window.upgrade(), weak_list.upgrade(), weak_likes.upgrade(), weak_like.upgrade(), weak_stack.upgrade()) else {
                    return;
                };
                let activities = match outcome {
                    Ok(activities) => activities,
                    Err(message) => return window.toast(&message),
                };
                show(&window, &list, &likes, &like, &stack, &activities, me.as_deref());
            });
        })
    };
    reload();

    // Commenting.
    let comment = {
        let (weak_window, weak_entry, album_id, asset_id, reload) = (window.downgrade(), entry.downgrade(), album_id.to_owned(), asset_id.clone(), reload.clone());
        move || {
            let (Some(window), Some(entry)) = (weak_window.upgrade(), weak_entry.upgrade()) else { return };
            let text = entry.text().trim().to_owned();
            if text.is_empty() {
                return;
            }
            let Some(session) = window.session() else { return };
            entry.set_text("");
            let (client, album_id, asset_id, reload, shown) = (session.connection.client.clone(), album_id.clone(), asset_id.clone(), reload.clone(), window.clone());
            crate::tasks::run(async move { client.comment(&album_id, asset_id.as_deref(), &text).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(_) => reload(),
                Err(message) => shown.toast(&message),
            });
        }
    };
    let comment = std::rc::Rc::new(comment);
    let send_comment = comment.clone();
    send.connect_clicked(move |_| send_comment());
    entry.connect_activate(move |_| comment());

    // Liking, and taking the like back.
    let (weak_window, album_id, reload) = (window.downgrade(), album_id.to_owned(), reload.clone());
    like.connect_clicked(move |button| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        let (client, album_id, asset_id, reload, shown) = (session.connection.client.clone(), album_id.clone(), asset_id.clone(), reload.clone(), window.clone());
        let liking = button.is_active();
        let me = session.connection.user_id().map(str::to_owned);
        crate::tasks::run(
            async move {
                if liking {
                    return client.like(&album_id, asset_id.as_deref()).await.map(|_| ()).map_err(|error| verso_desktop::errors::said(&error));
                }
                let filter = ActivityFilter { asset_id: asset_id.clone(), kind: Some(ActivityKind::Like), album_level: Some(asset_id.is_none()), ..ActivityFilter::default() };
                let mine = client.activities(&album_id, &filter).await.map_err(|error| verso_desktop::errors::said(&error))?.into_iter().find(|activity| Some(&activity.user.id) == me.as_ref());
                match mine {
                    Some(activity) => client.delete_activity(&activity.id).await.map_err(|error| verso_desktop::errors::said(&error)),
                    None => Ok(()),
                }
            },
            move |outcome| match outcome {
                Ok(()) => reload(),
                Err(message) => shown.toast(&message),
            },
        );
    });
    dialog.present(Some(window));
    entry.grab_focus();
}

/// Fill the dialog: the likes in a line, the comments as rows (one's own with Delete), the Like button's state.
fn show(window: &Window, list: &gtk::ListBox, likes: &gtk::Label, like: &gtk::ToggleButton, stack: &gtk::Stack, activities: &[Activity], me: Option<&str>) {
    list.remove_all();
    let likers: Vec<&str> = activities.iter().filter(|activity| activity.kind == ActivityKind::Like).map(|activity| activity.user.name.as_str()).collect();
    likes.set_visible(!likers.is_empty());
    likes.set_label(&tr("Liked by {names}").replace("{names}", &likers.join(", ")));
    let liked = activities.iter().any(|activity| activity.kind == ActivityKind::Like && Some(activity.user.id.as_str()) == me);
    like.set_active(liked);
    like.set_label(if liked { tr("Unlike") } else { tr("Like") });
    let comments: Vec<&Activity> = activities.iter().filter(|activity| activity.kind == ActivityKind::Comment).collect();
    stack.set_visible_child_name(if comments.is_empty() { "empty" } else { "list" });
    for activity in comments {
        let when = verso_desktop::text::taken(activity.created_at.naive_utc());
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(activity.comment.as_deref().unwrap_or_default()))
            .subtitle(glib::markup_escape_text(&format!("{} · {when}", activity.user.name)))
            .title_lines(0)
            .build();
        if Some(activity.user.id.as_str()) == me {
            let delete = gtk::Button::builder().icon_name("user-trash-symbolic").tooltip_text(tr("Delete the Comment")).valign(gtk::Align::Center).css_classes(["flat"]).build();
            let (weak_window, weak_row, id) = (window.downgrade(), row.downgrade(), activity.id.clone());
            delete.connect_clicked(move |button| {
                let (weak_window, id, weak_row) = (weak_window.clone(), id.clone(), weak_row.clone());
                crate::dialogs::confirm(button, tr("Delete the Comment?"), tr("It goes for everyone who sees the album."), tr("Delete"), true, move || {
                    let Some(window) = weak_window.upgrade() else { return };
                    let Some(session) = window.session() else { return };
                    let (client, id, weak_row, shown) = (session.connection.client.clone(), id.clone(), weak_row.clone(), window.clone());
                    crate::tasks::run(async move { client.delete_activity(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                        Ok(()) => {
                            if let Some(row) = weak_row.upgrade() {
                                row.set_visible(false);
                            }
                        }
                        Err(message) => shown.toast(&message),
                    });
                });
            });
            row.add_suffix(&delete);
        }
        list.append(&row);
    }
}
