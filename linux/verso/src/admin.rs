//! Administration, for the server's admins: the server and its storage, what each user keeps, the job queues
//! (run, pause, resume), external libraries (scan), and the users. Changing users and the server's settings stays in
//! Immich's web app, which the page links to.

use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::{gio, glib};
use immich_api::{QueueCommand, QueueName};
use verso_desktop::text;
use verso_core::links::server_address;
use verso_linux::i18n::tr;

use crate::window::Window;

/// A queue's name as people read it: `thumbnailGeneration` as "Thumbnail Generation".
fn queue_title(name: &QueueName) -> String {
    let raw = name.as_str();
    let mut title = String::new();
    for (index, character) in raw.chars().enumerate() {
        if index == 0 {
            title.extend(character.to_uppercase());
        } else if character.is_uppercase() {
            title.push(' ');
            title.push(character);
        } else {
            title.push(character);
        }
    }
    title
}

/// Administration, a page of Preferences for the server's admins.
pub fn admin_preferences(window: &Window) -> adw::PreferencesPage {
    let preferences = adw::PreferencesPage::new();
    let Some(session) = window.session() else { return preferences };
    if !session.connection.is_admin() {
        return preferences;
    }
    let web_group = adw::PreferencesGroup::builder().description(tr("Changing users and the server's settings stays in Immich's web app.")).build();
    let web = adw::ButtonRow::builder().title(tr("Open Administration in Immich")).end_icon_name("adw-external-link-symbolic").build();
    let weak_window = window.downgrade();
    web.connect_activated(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(session) = window.session() else { return };
        gtk::UriLauncher::new(&format!("{}/admin", server_address(&session.connection.server))).launch(Some(&window), gio::Cancellable::NONE, |_| {});
    });
    web_group.add(&web);
    preferences.add(&web_group);

    let server = adw::PreferencesGroup::builder().title(tr("Server")).build();
    let usage = adw::PreferencesGroup::builder().title(tr("Use by User")).build();
    let jobs = adw::PreferencesGroup::builder().title(tr("Jobs")).description(tr("Immich's background work. Run starts a queue on what is missing; Pause holds it.")).build();
    let libraries = adw::PreferencesGroup::builder().title(tr("External Libraries")).build();
    let users = adw::PreferencesGroup::builder().title(tr("Users")).build();
    for group in [&server, &usage, &jobs, &libraries, &users] {
        preferences.add(group);
    }

    // The server, its storage and use, the users and the libraries: read once.
    let client = session.connection.client.clone();
    let (weak_server, weak_usage, weak_libraries, weak_users, weak_window) = (server.downgrade(), usage.downgrade(), libraries.downgrade(), users.downgrade(), window.downgrade());
    crate::tasks::run(
        async move {
            let about = client.server_about().await.ok();
            let storage = client.server_storage().await.ok();
            let statistics = client.server_statistics().await.ok();
            let libraries = client.libraries().await.unwrap_or_default();
            let users = client.admin_users(false).await.unwrap_or_default();
            (about, storage, statistics, libraries, users)
        },
        move |(about, storage, statistics, libraries, users)| {
            let (Some(server), Some(usage), Some(library_group), Some(user_group)) = (weak_server.upgrade(), weak_usage.upgrade(), weak_libraries.upgrade(), weak_users.upgrade()) else { return };
            let row = |title: &str, value: &str| adw::ActionRow::builder().title(glib::markup_escape_text(title)).subtitle(glib::markup_escape_text(value)).css_classes(["property"]).build();
            if let Some(about) = about {
                server.add(&row(tr("Immich"), &about.version));
            }
            if let Some(storage) = storage {
                server.add(&row(tr("Storage"), &tr("{used} of {size} used ({percent} %)").replace("{used}", &text::size(storage.disk_use)).replace("{size}", &text::size(storage.disk_size)).replace("{percent}", &format!("{:.0}", storage.disk_usage_percentage))));
            }
            if let Some(statistics) = &statistics {
                server.add(&row(tr("Library"), &tr("{photos} photos, {videos} videos, {size}").replace("{photos}", &statistics.photos.to_string()).replace("{videos}", &statistics.videos.to_string()).replace("{size}", &text::size(statistics.usage))));
                for user in &statistics.usage_by_user {
                    let mut line = tr("{photos} photos, {videos} videos, {size}").replace("{photos}", &user.photos.to_string()).replace("{videos}", &user.videos.to_string()).replace("{size}", &text::size(user.usage));
                    if let Some(quota) = user.quota_size_in_bytes.filter(|quota| *quota > 0) {
                        line.push_str(&format!(" · {}", tr("quota {size}").replace("{size}", &text::size(quota))));
                    }
                    usage.add(&row(&user.user_name, &line));
                }
            }
            usage.set_visible(statistics.is_some_and(|statistics| !statistics.usage_by_user.is_empty()));
            library_group.set_visible(!libraries.is_empty());
            for library in libraries {
                let line = format!("{} · {}", text::items(library.asset_count), library.import_paths.join(", "));
                let library_row = row(&library.name, &line);
                let scan = gtk::Button::builder().label(tr("Scan")).valign(gtk::Align::Center).build();
                let (weak_window, id) = (weak_window.clone(), library.id.clone());
                scan.connect_clicked(move |_| {
                    let Some(window) = weak_window.upgrade() else { return };
                    let Some(session) = window.session() else { return };
                    let (client, id, shown) = (session.connection.client.clone(), id.clone(), window.clone());
                    crate::tasks::run(async move { client.scan_library(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                        shown.toast(&outcome.map(|()| tr("Scanning the library").to_owned()).unwrap_or_else(|message| message));
                    });
                });
                library_row.add_suffix(&scan);
                library_group.add(&library_row);
            }
            for user in users {
                let mut line = user.email.clone();
                if user.is_admin {
                    line.push_str(&format!(" · {}", tr("Admin")));
                }
                user_group.add(&row(&user.name, &line));
            }
        },
    );

    // The queues, read again every few seconds while the page is on screen.
    let queue_rows: Rc<std::cell::RefCell<Vec<gtk::Widget>>> = Rc::default();
    let refresh: Rc<dyn Fn()> = {
        let (weak_jobs, weak_window, rows) = (jobs.downgrade(), window.downgrade(), queue_rows.clone());
        Rc::new(move || {
            let Some(window) = weak_window.upgrade() else { return };
            let Some(session) = window.session() else { return };
            let client = session.connection.client.clone();
            let (weak_jobs, weak_window, rows) = (weak_jobs.clone(), weak_window.clone(), rows.clone());
            crate::tasks::run(async move { client.queues().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                let Some(jobs) = weak_jobs.upgrade() else { return };
                for row in rows.borrow_mut().drain(..) {
                    jobs.remove(&row);
                }
                let Ok(queues) = outcome else { return };
                for queue in queues {
                    let statistics = &queue.statistics;
                    let mut line = tr("{active} running, {waiting} waiting").replace("{active}", &statistics.active.to_string()).replace("{waiting}", &statistics.waiting.to_string());
                    if statistics.failed > 0 {
                        line.push_str(&format!(", {}", tr("{failed} failed").replace("{failed}", &statistics.failed.to_string())));
                    }
                    if queue.is_paused {
                        line.push_str(&format!(" · {}", tr("paused")));
                    }
                    let row = adw::ActionRow::builder().title(queue_title(&queue.name)).subtitle(line).build();
                    let command = |label: &str, command: QueueCommand| {
                        let button = gtk::Button::builder().label(label).valign(gtk::Align::Center).css_classes(["flat"]).build();
                        let (weak_window, name) = (weak_window.clone(), queue.name.clone());
                        button.connect_clicked(move |_| {
                            let Some(window) = weak_window.upgrade() else { return };
                            let Some(session) = window.session() else { return };
                            let (client, name, command, shown) = (session.connection.client.clone(), name.clone(), command.clone(), window.clone());
                            crate::tasks::run(async move { client.command_queue(&name, &command, false).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                                if let Err(message) = outcome {
                                    shown.toast(&message);
                                }
                            });
                        });
                        button
                    };
                    row.add_suffix(&command(tr("Run"), QueueCommand::Start));
                    row.add_suffix(&if queue.is_paused { command(tr("Resume"), QueueCommand::Resume) } else { command(tr("Pause"), QueueCommand::Pause) });
                    jobs.add(&row);
                    rows.borrow_mut().push(row.upcast());
                }
            });
        })
    };
    refresh();
    let (weak_page, again) = (preferences.downgrade(), refresh.clone());
    glib::timeout_add_local(Duration::from_secs(5), move || {
        let Some(page) = weak_page.upgrade() else { return glib::ControlFlow::Break };
        if page.is_mapped() {
            again();
        }
        glib::ControlFlow::Continue
    });
    preferences
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queues_read_as_words() {
        assert_eq!(queue_title(&QueueName::ThumbnailGeneration), "Thumbnail Generation");
        assert_eq!(queue_title(&QueueName::Ocr), "Ocr");
    }
}
