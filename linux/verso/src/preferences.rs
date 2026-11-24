//! Preferences: a sidebar of pages beside them. The account first (its profile, password, devices and keys), the
//! account's Immich features, then the drive (its status, then its settings pages, `drive_preferences`, drawn from the
//! layout every edition shares), and the server's administration for its admins. The service reads its settings as it
//! starts, so a change restarts it when its page is left or the window closes.

use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use verso_desktop::session;
use verso_linux::i18n::tr;

use verso_core::settings::Pane;
use verso_desktop::preferences::{Group, Page, Row};

use crate::window::Window;

/// A page of the Preferences window: its id, title and icon, and the heading it starts, if any.
struct Entry {
    id: &'static str,
    title: &'static str,
    icon: &'static str,
    heading: Option<&'static str>,
}

/// Verso's own pages, for all of it, Verso Gallery and Verso Drive alike: General (the app icon, Immich's web app, the
/// top bar icon) and Crosslink (Immich Crosslink, with the two participants Verso announces and the other apps found),
/// built as the drive's pages are, from the settings they show.
const GENERAL: Page = Page {
    pane: Pane::OtherApps,
    id: "verso-general",
    title: "General",
    icon: "preferences-system-symbolic",
    groups: &[
        // The app icon by day and by night; not in a Flatpak, which hides both settings.
        verso_desktop::preferences::APP_ICON_GROUP,
        Group {
            title: Some("Immich Web App"),
            description: None,
            rows: &[Row { key: "web.links", title: "Open in Immich and Copy Immich Link", subtitle: None, inner: None }],
            apps: false,
        },
        Group {
            title: Some("Top Bar Icon"),
            description: Some("A click shows its menu."),
            rows: &[
                Row { key: "tray.double_click", title: "Double-Click Opens", subtitle: None, inner: None },
                Row { key: "tray.colour", title: "Colour", subtitle: Some("The lens in its five colours, grey while the server cannot be reached."), inner: None },
            ],
            apps: false,
        },
    ],
};
const CROSSLINK: Page = Page {
    pane: Pane::OtherApps,
    id: "crosslink",
    title: "Crosslink",
    icon: "verso-crosslink-symbolic",
    groups: &[
        Group { title: None, description: None, rows: &[Row { key: "crosslink.enabled", title: "Immich Crosslink", subtitle: None, inner: None }], apps: false },
        Group {
            title: Some("Verso Takes Part As"),
            description: Some("Each is announced to other apps while its switch is on, so they offer to show what you choose in it."),
            rows: &[
                Row { key: "crosslink.gallery", title: "Verso Gallery", subtitle: None, inner: None },
                Row { key: "crosslink.drive", title: "Verso Drive", subtitle: None, inner: None },
            ],
            apps: true,
        },
    ],
};

/// Crosslink in Verso's Flatpak: the switch, and what a sandbox offers. It announces Verso Gallery with the entry it
/// exports, and cannot list the other apps.
const CROSSLINK_SANDBOXED: Page = Page {
    pane: Pane::OtherApps,
    id: "crosslink",
    title: "Crosslink",
    icon: "verso-crosslink-symbolic",
    groups: &[Group {
        title: None,
        description: Some("Verso takes part as Verso Gallery. Show in offers Show in Another App…, where you choose the app, as this version of Verso cannot list the apps that take part."),
        rows: &[Row { key: "crosslink.enabled", title: "Immich Crosslink", subtitle: None, inner: None }],
        apps: false,
    }],
};

/// Crosslink's page, as this build of Verso has it.
fn crosslink_page() -> &'static Page {
    if verso_core::product::current().sandboxed { &CROSSLINK_SANDBOXED } else { &CROSSLINK }
}

/// The drive's own pages, under Verso Drive: its General is Drive here, beside Verso's General; Other Apps is Verso's
/// Crosslink, above.
fn drive_pages() -> impl Iterator<Item = &'static Page> {
    verso_desktop::preferences::PAGES.iter().filter(|page| page.id != "other-apps")
}

/// Verso Drive's own page (its switch, whether it is mounted, Mount, Unmount and Open) shows the drive as Files and the
/// top bar do, by Verso's mark; the drive's settings (where it mounts, its name, its cache) have the disk.
const DRIVE_MARK: &str = "dev.hviid.Verso-symbolic";

/// The window's pages, in its sidebar's order: the account and what is Verso's as a whole first, then the drive, then
/// the server for its admins.
fn entries(admin: bool) -> Vec<Entry> {
    let mut entries = vec![
        Entry { id: "account", title: tr("Account"), icon: "avatar-default-symbolic", heading: None },
        Entry { id: GENERAL.id, title: tr(GENERAL.title), icon: GENERAL.icon, heading: None },
        Entry { id: CROSSLINK.id, title: tr(CROSSLINK.title), icon: CROSSLINK.icon, heading: None },
        Entry { id: "features", title: tr("Features"), icon: "application-x-addon-symbolic", heading: None },
        // In a Flatpak, one page saying the drive is not there, under its own name.
        if verso_core::product::current().sandboxed {
            Entry { id: "drive", title: tr("Verso Drive"), icon: DRIVE_MARK, heading: None }
        } else {
            Entry { id: "drive", title: tr("Status"), icon: DRIVE_MARK, heading: Some(tr("Verso Drive")) }
        },
    ];
    entries.extend(drive_pages().map(|page| Entry {
        id: page.id,
        title: if page.id == "general" { tr("Drive") } else { tr(page.title) },
        icon: if page.id == "general" { "drive-harddisk-symbolic" } else { page.icon },
        heading: None,
    }));
    if admin {
        entries.push(Entry { id: "admin", title: tr("Administration"), icon: "verso-server-symbolic", heading: Some(tr("Server")) });
    }
    entries
}

/// Preferences: pages in a sidebar beside them. One window per
/// gallery window, shown again when asked again; `page` opens one of its pages. The daemon reads its settings as it
/// starts, so a change of the drive's restarts it when its page is left or the window closes.
pub fn show(window: &Window, page: Option<&str>) {
    if let Some(open) = window.preferences_window() {
        if let Some(page) = page {
            select(&open, page);
        }
        open.present();
        return;
    }
    let admin = window.session().is_some_and(|session| session.connection.is_admin());
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::Browse).css_classes(["navigation-sidebar"]).build();
    for entry in entries(admin) {
        if let Some(heading) = entry.heading {
            let label = gtk::Label::builder().label(heading).xalign(0.0).css_classes(["dim-label", "gallery-sidebar-heading"]).build();
            list.append(&gtk::ListBoxRow::builder().child(&label).selectable(false).activatable(false).focusable(false).build());
        }
        let content = gtk::Box::builder().spacing(12).build();
        content.append(&gtk::Image::from_icon_name(entry.icon));
        content.append(&gtk::Label::builder().label(entry.title).xalign(0.0).build());
        // The drive's own pages, only while it is on.
        let drive_page = drive_pages().any(|page| page.id == entry.id);
        list.append(&gtk::ListBoxRow::builder().child(&content).name(entry.id).visible(!drive_page || crate::drive_on()).build());
    }
    let sidebar_toolbar = adw::ToolbarView::new();
    sidebar_toolbar.add_top_bar(&adw::HeaderBar::new());
    sidebar_toolbar.set_content(Some(&gtk::ScrolledWindow::builder().child(&list).hscrollbar_policy(gtk::PolicyType::Never).build()));
    let sidebar = adw::NavigationPage::builder().title(tr("Preferences")).child(&sidebar_toolbar).build();
    let pages = gtk::Stack::new();
    let content_toolbar = adw::ToolbarView::new();
    content_toolbar.add_top_bar(&adw::HeaderBar::new());
    content_toolbar.set_content(Some(&pages));
    let content = adw::NavigationPage::builder().title("").child(&content_toolbar).build();
    let split = adw::NavigationSplitView::builder().sidebar(&sidebar).content(&content).min_sidebar_width(200.0).max_sidebar_width(260.0).build();
    let preferences = adw::Window::builder().title(tr("Preferences")).default_width(920).default_height(680).transient_for(window).content(&split).build();
    let narrow = adw::Breakpoint::new(adw::BreakpointCondition::parse("max-width: 560sp").expect("a valid condition"));
    narrow.add_setter(&split, "collapsed", Some(&true.to_value()));
    preferences.add_breakpoint(narrow);
    let changed = Rc::new(Cell::new(false));
    let shown: Rc<std::cell::RefCell<String>> = Rc::default();
    let weak_window = window.downgrade();
    let context = crate::drive_preferences::Context {
        changed: changed.clone(),
        report: Rc::new(move |message: &str| {
            if let Some(window) = weak_window.upgrade() {
                window.toast(message);
            }
        }),
    };
    let (weak_window, weak_pages, weak_content, weak_split, settings_changed) = (window.downgrade(), pages.downgrade(), content.downgrade(), split.downgrade(), changed.clone());
    list.connect_row_selected(move |_, row| {
        let (Some(row), Some(window), Some(pages), Some(content), Some(split)) = (row, weak_window.upgrade(), weak_pages.upgrade(), weak_content.upgrade(), weak_split.upgrade()) else { return };
        let id = row.widget_name().to_string();
        // Leaving a drive page where something changed: the daemon reads its settings again.
        if *shown.borrow() != id && settings_changed.replace(false) {
            verso_desktop::preferences::restart_daemon();
        }
        shown.replace(id.clone());
        // Drawn anew each time, so a page shows things as they are now.
        if let Some(old) = pages.child_by_name(&id) {
            pages.remove(&old);
        }
        let drawn: gtk::Widget = match id.as_str() {
            "account" => account_page(&window).upcast(),
            "features" => crate::account_settings::features_page(&window).upcast(),
            "drive" if verso_core::product::current().sandboxed => drive_unavailable_page().upcast(),
            "drive" => drive_page(&window).upcast(),
            "admin" => crate::admin::admin_preferences(&window).upcast(),
            other => match drive_pages().chain([&GENERAL, crosslink_page()]).find(|page| page.id == other) {
                Some(layout) => crate::drive_preferences::page(layout, &context, window.upcast_ref()).upcast(),
                None => return,
            },
        };
        pages.add_named(&drawn, Some(&id));
        pages.set_visible_child_name(&id);
        content.set_title(&entries(true).iter().find(|entry| entry.id == id).map_or(String::new(), |entry| entry.title.to_owned()));
        split.set_show_content(true);
    });
    preferences.connect_close_request(move |_| {
        if changed.replace(false) {
            verso_desktop::preferences::restart_daemon();
        }
        glib::Propagation::Proceed
    });
    window.set_preferences_window(&preferences);
    select(&preferences, page.unwrap_or("account"));
    preferences.present();
}

/// Open one of the window's pages, by its id.
fn select(preferences: &adw::Window, id: &str) {
    let Some(list) = find_list(preferences.upcast_ref()) else { return };
    let mut index = 0;
    while let Some(row) = list.row_at_index(index) {
        if row.widget_name() == id {
            list.select_row(Some(&row));
            return;
        }
        index += 1;
    }
}

/// The window's sidebar list.
fn find_list(widget: &gtk::Widget) -> Option<gtk::ListBox> {
    if let Some(list) = widget.downcast_ref::<gtk::ListBox>() {
        return Some(list.clone());
    }
    let mut child = widget.first_child();
    while let Some(current) = child {
        if let Some(found) = find_list(&current) {
            return Some(found);
        }
        child = current.next_sibling();
    }
    None
}

/// Show or hide the drive's own pages in the window's sidebar (General, Folders, Other Apps), as the drive is on or off.
fn show_drive_pages(preferences: &gtk::Widget, on: bool) {
    let Some(list) = find_list(preferences) else { return };
    let mut index = 0;
    while let Some(row) = list.row_at_index(index) {
        if drive_pages().any(|page| page.id == row.widget_name()) {
            row.set_visible(on);
        }
        index += 1;
    }
}

/// Verso Drive: its switch, then, while it is on, where it is, whether it is mounted, and the buttons to mount,
/// unmount and open it.
/// Verso Drive in Verso's Flatpak: not there, why, and where to have it.
fn drive_unavailable_page() -> adw::PreferencesPage {
    let status = adw::StatusPage::builder()
        .icon_name("drive-harddisk-symbolic")
        .title(tr("Verso Drive"))
        .description(tr("Your library as a drive in Files needs access outside the Flatpak's sandbox, so it is not part of this version of Verso. Verso installed with Homebrew has it."))
        .build();
    status.set_child(Some(&gtk::LinkButton::builder().label(tr("Installing Verso with Homebrew")).uri("https://github.com/jakobhviid/verso#with-homebrew").halign(gtk::Align::Center).build()));
    let group = adw::PreferencesGroup::new();
    group.add(&status);
    let page = adw::PreferencesPage::new();
    page.add(&group);
    page
}

fn drive_page(window: &Window) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();
    let switch_group = adw::PreferencesGroup::builder()
        .description(tr("Verso Drive shows your library as folders in Files and in every file dialog, so any program can open a photo. Originals download only when something opens them."))
        .build();
    let on = crate::drive_on();
    let switch = adw::SwitchRow::builder().title(tr("Verso Drive")).subtitle(tr("Show your library in Files")).active(on).build();
    switch_group.add(&switch);
    page.add(&switch_group);
    let group = adw::PreferencesGroup::builder().title(tr("Status")).visible(on).build();
    let state = adw::ActionRow::builder().title(tr("Drive")).subtitle(tr("Checking…")).build();
    let connection = adw::ActionRow::builder().title(tr("Connection")).visible(false).build();
    // What the drive's Status page shows besides: uploads, the cache, where the sign-in is kept.
    let uploads = adw::ActionRow::builder().title(tr("Uploads")).visible(false).build();
    let cache = adw::ActionRow::builder().title(tr("Cache")).visible(false).build();
    let kept = adw::ActionRow::builder().title(tr("Sign-In")).visible(false).build();
    let open = gtk::Button::builder().label(tr("Open in Files")).valign(gtk::Align::Center).visible(false).build();
    let mount = gtk::Button::builder().label(tr("Mount")).valign(gtk::Align::Center).css_classes(["suggested-action"]).visible(false).build();
    let unmount = gtk::Button::builder().label(tr("Unmount")).valign(gtk::Align::Center).visible(false).build();
    state.add_suffix(&open);
    state.add_suffix(&mount);
    state.add_suffix(&unmount);
    group.add(&state);
    group.add(&connection);
    group.add(&uploads);
    group.add(&cache);
    group.add(&kept);
    page.add(&group);

    let refresh: Rc<dyn Fn()> = {
        let (weak_state, weak_connection, weak_open, weak_mount, weak_unmount) =
            (state.downgrade(), connection.downgrade(), open.downgrade(), mount.downgrade(), unmount.downgrade());
        let (weak_uploads, weak_cache, weak_kept) = (uploads.downgrade(), cache.downgrade(), kept.downgrade());
        Rc::new(move || {
            let (weak_state, weak_connection, weak_open, weak_mount, weak_unmount) =
                (weak_state.clone(), weak_connection.clone(), weak_open.clone(), weak_mount.clone(), weak_unmount.clone());
            let (weak_uploads, weak_cache, weak_kept) = (weak_uploads.clone(), weak_cache.clone(), weak_kept.clone());
            crate::tasks::run(session::current_status(), move |status| {
                if let (Some(uploads), Some(cache), Some(kept), Some(status)) = (weak_uploads.upgrade(), weak_cache.upgrade(), weak_kept.upgrade(), status.as_ref()) {
                    uploads.set_visible(status.uploads_text().is_some());
                    uploads.set_subtitle(&status.uploads_text().unwrap_or_default());
                    cache.set_visible(true);
                    cache.set_subtitle(&status.cache_text(verso_desktop::preferences::format_size));
                    kept.set_visible(!status.credential_place.is_empty());
                    kept.set_subtitle(&status.credential_place);
                }
                let (Some(state), Some(connection), Some(open), Some(mount), Some(unmount)) =
                    (weak_state.upgrade(), weak_connection.upgrade(), weak_open.upgrade(), weak_mount.upgrade(), weak_unmount.upgrade())
                else {
                    return;
                };
                match status {
                    Some(status) => {
                        state.set_subtitle(if status.mounted { tr("Mounted") } else { tr("Not mounted") });
                        connection.set_visible(true);
                        connection.set_subtitle(&status.connection_text());
                        open.set_visible(status.mounted);
                        unmount.set_visible(status.mounted);
                        mount.set_visible(!status.mounted);
                    }
                    None => {
                        state.set_subtitle(tr("Not set up"));
                        mount.set_visible(true);
                    }
                }
            });
        })
    };
    refresh();
    let set_mounted = |button: &gtk::Button, mounted: bool, refresh: Rc<dyn Fn()>, window: &Window| {
        let weak_window = window.downgrade();
        button.connect_clicked(move |button| {
            button.set_sensitive(false);
            let (refresh, weak_window, weak_button) = (refresh.clone(), weak_window.clone(), button.downgrade());
            crate::tasks::run(async move { session::set_mounted(mounted) }, move |outcome| {
                if let (Err(message), Some(window)) = (outcome, weak_window.upgrade()) {
                    window.toast(&message);
                }
                if let Some(button) = weak_button.upgrade() {
                    button.set_sensitive(true);
                }
                // The daemon takes a few seconds to mount; look again then.
                let later = refresh.clone();
                glib::timeout_add_seconds_local_once(3, move || later());
                refresh();
            });
        });
    };
    set_mounted(&mount, true, refresh.clone(), window);
    set_mounted(&unmount, false, refresh.clone(), window);
    // The switch writes `mount.enabled` and restarts the service, which mounts the drive or takes it away.
    let reverting = Rc::new(Cell::new(false));
    let (weak_window, weak_group, weak_state, weak_mount) = (window.downgrade(), group.downgrade(), state.downgrade(), mount.downgrade());
    switch.connect_active_notify(move |switch| {
        if reverting.get() {
            return;
        }
        let on = switch.is_active();
        switch.set_sensitive(false);
        if let Some(preferences) = switch.root() {
            show_drive_pages(preferences.upcast_ref(), on);
        }
        let (refresh, weak_window, weak_group, weak_switch, reverting) = (refresh.clone(), weak_window.clone(), weak_group.clone(), switch.downgrade(), reverting.clone());
        let (weak_state, weak_mount) = (weak_state.clone(), weak_mount.clone());
        crate::tasks::run(async move { session::set_drive(on) }, move |outcome| {
            let Some(switch) = weak_switch.upgrade() else { return };
            switch.set_sensitive(true);
            let now = match outcome {
                Ok(()) => on,
                Err(message) => {
                    if let Some(window) = weak_window.upgrade() {
                        window.toast(&message);
                    }
                    reverting.set(true);
                    switch.set_active(crate::drive_on());
                    reverting.set(false);
                    crate::drive_on()
                }
            };
            if let Some(preferences) = switch.root() {
                show_drive_pages(preferences.upcast_ref(), now);
            }
            if let Some(group) = weak_group.upgrade() {
                group.set_visible(now);
            }
            if !now {
                return refresh();
            }
            // Switched on, the drive mounts within seconds: it reads Mounting until it is up, rather than Not mounted
            // with a Mount button, which read as if switching it on had not been enough.
            if let Some(state) = weak_state.upgrade() {
                state.set_subtitle(tr("Mounting…"));
            }
            if let Some(mount) = weak_mount.upgrade() {
                mount.set_visible(false);
            }
            // Looked at each second, for up to 20, until it is mounted; then, or at the last look, the page shows it.
            let (tries, done, refresh) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(false)), refresh.clone());
            glib::timeout_add_seconds_local(1, move || {
                if done.get() {
                    return glib::ControlFlow::Break;
                }
                tries.set(tries.get() + 1);
                let (refresh, done, last) = (refresh.clone(), done.clone(), tries.get() >= 20);
                crate::tasks::run(session::current_status(), move |status| {
                    if status.is_some_and(|status| status.mounted) || last {
                        done.set(true);
                        refresh();
                    }
                });
                if last { glib::ControlFlow::Break } else { glib::ControlFlow::Continue }
            });
        });
    });
    let weak_window = window.downgrade();
    open.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let shown = window.clone();
        crate::tasks::run(session::current_status(), move |status| {
            if let Some(status) = status {
                gtk::FileLauncher::new(Some(&gio::File::for_path(status.mount_point))).launch(Some(&shown), gio::Cancellable::NONE, |_| {});
            }
        });
    });
    page
}

fn account_page(window: &Window) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();
    let group = adw::PreferencesGroup::builder().title(tr("Account")).build();
    if let Some(session) = window.session() {
        let connection = &session.connection;
        group.add(&adw::ActionRow::builder().title(tr("Server")).subtitle(glib::markup_escape_text(&connection.server)).subtitle_selectable(true).css_classes(["property"]).build());
        if let Some(account) = &connection.account {
            group.add(&adw::ActionRow::builder().title(tr("Signed In As")).subtitle(glib::markup_escape_text(&format!("{} ({})", account.name, account.email))).css_classes(["property"]).build());
        }
        let kind = if connection.with_api_key { tr("An API key") } else { tr("A session, from signing in") };
        group.add(&adw::ActionRow::builder().title(tr("Signed In With")).subtitle(kind).css_classes(["property"]).build());
        if let Some(certificate) = connection.client.trusted_certificate() {
            group.add(&trusted_certificate_row(window, certificate));
        }
    }
    page.add(&group);
    page.add(&crate::account_settings::profile_group(window));
    if window.session().is_some_and(|session| !session.connection.with_api_key) {
        page.add(&crate::account_settings::password_group(window));
        page.add(&devices_group(window));
        page.add(&keys_group(window));
    }
    let sign_out_group = adw::PreferencesGroup::new();
    // A Flatpak has no drive to take away.
    if !verso_core::product::current().sandboxed {
        sign_out_group.set_description(Some(tr("Signing out also takes Verso Drive out of Files.")));
    }
    let sign_out = adw::ButtonRow::builder().title(tr("Sign Out…")).css_classes(["destructive-action"]).build();
    let weak_window = window.downgrade();
    sign_out.connect_activated(move |row| {
        if let Some(preferences) = row.root().and_downcast::<adw::Window>() {
            preferences.close();
        }
        if let Some(window) = weak_window.upgrade() {
            window.confirm_sign_out();
        }
    });
    sign_out_group.add(&sign_out);
    page.add(&sign_out_group);
    page
}

/// The certificate trusted for the server where the system does not trust it (ARCHITECTURE.md, "A certificate of the
/// server's own"), and forgetting it: the next connection asks again, unless the system trusts the server by then.
fn trusted_certificate_row(window: &Window, certificate: immich_api::CertificatePin) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(tr("Trusted Certificate (SHA-256)"))
        .subtitle(verso_desktop::session::fingerprint_lines(certificate, 16))
        .subtitle_selectable(true)
        .css_classes(["property", "monospace"])
        .build();
    let forget = gtk::Button::builder().label(tr("Forget…")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    let weak_window = window.downgrade();
    forget.connect_clicked(move |button| {
        let Some(window) = weak_window.upgrade() else { return };
        let Some(preferences) = button.root().and_downcast::<adw::Window>() else { return };
        let shown = window.clone();
        let closing = preferences.downgrade();
        crate::dialogs::confirm(
            &preferences,
            tr("Forget the Certificate?"),
            tr("Verso stops trusting this certificate and connects again, asking about the server's certificate, unless this computer trusts it."),
            tr("Forget"),
            true,
            move || {
                if let Some(preferences) = closing.upgrade() {
                    preferences.close();
                }
                shown.forget_certificate();
            },
        );
    });
    row.add_suffix(&forget);
    row
}

/// The devices signed in to the account, and signing the others out.
fn devices_group(window: &Window) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(tr("Devices")).description(tr("Where this account is signed in.")).build();
    let others = gtk::Button::builder().label(tr("Sign Out Others…")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    group.set_header_suffix(Some(&others));
    let weak_window = window.downgrade();
    others.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let shown = window.clone();
        crate::dialogs::confirm(&window, tr("Sign Out the Other Devices?"), tr("Every other app and browser signed in to this account signs out. This one stays signed in."), tr("Sign Out Others"), true, move || {
            let Some(session) = shown.session() else { return };
            let (client, done) = (session.connection.client.clone(), shown.clone());
            crate::tasks::run(async move { client.delete_other_sessions().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
                done.toast(&outcome.map(|()| tr("The other devices are signed out").to_owned()).unwrap_or_else(|message| message));
            });
        });
    });
    let Some(session) = window.session() else { return group };
    let client = session.connection.client.clone();
    let weak_group = group.downgrade();
    crate::tasks::run(async move { client.sessions().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let Some(group) = weak_group.upgrade() else { return };
        let Ok(mut sessions) = outcome else { return group.set_visible(false) };
        sessions.sort_by_key(|session| std::cmp::Reverse(session.updated_at));
        for device in sessions.iter().take(20) {
            let name = [device.device_os.as_str(), device.device_type.as_str()].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" · ");
            let mut line = verso_desktop::text::taken(device.updated_at.naive_utc());
            if device.current {
                line = format!("{} · {line}", tr("This app"));
            }
            group.add(&adw::ActionRow::builder().title(glib::markup_escape_text(if name.is_empty() { tr("A device") } else { &name })).subtitle(line).build());
        }
    });
    group
}

/// The account's API keys: deleting one, and making one, whose secret shows once.
fn keys_group(window: &Window) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title(tr("API Keys")).description(tr("Keys let scripts and other apps use this account.")).build();
    let new_key = gtk::Button::builder().label(tr("New Key…")).valign(gtk::Align::Center).css_classes(["flat"]).build();
    group.set_header_suffix(Some(&new_key));
    let weak_window = window.downgrade();
    new_key.connect_clicked(move |_| {
        let Some(window) = weak_window.upgrade() else { return };
        let shown = window.clone();
        crate::dialogs::ask_text(&window, tr("New API Key"), tr("Name"), "", tr("Create"), move |name| {
            let Some(session) = shown.session() else { return };
            let (client, done) = (session.connection.client.clone(), shown.clone());
            crate::tasks::run(async move { client.create_api_key(&name, &["all".to_owned()]).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                Ok(created) => show_secret(&done, created.secret.expose()),
                Err(message) => done.toast(&message),
            });
        });
    });
    let Some(session) = window.session() else { return group };
    let client = session.connection.client.clone();
    let (weak_group, weak_window) = (group.downgrade(), window.downgrade());
    crate::tasks::run(async move { client.api_keys().await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| {
        let Some(group) = weak_group.upgrade() else { return };
        let Ok(keys) = outcome else { return group.set_visible(false) };
        for key in keys {
            let row = adw::ActionRow::builder()
                .title(glib::markup_escape_text(&key.name))
                .subtitle(tr("Made {date}").replace("{date}", &verso_desktop::text::day(key.created_at.date_naive())))
                .build();
            let delete = gtk::Button::builder().icon_name("user-trash-symbolic").tooltip_text(tr("Delete the Key")).valign(gtk::Align::Center).css_classes(["flat"]).build();
            let (weak_window, weak_row, id) = (weak_window.clone(), row.downgrade(), key.id.clone());
            delete.connect_clicked(move |_| {
                let Some(window) = weak_window.upgrade() else { return };
                let (shown, weak_row, id) = (window.clone(), weak_row.clone(), id.clone());
                crate::dialogs::confirm(&window, tr("Delete the Key?"), tr("Whatever uses it can no longer reach the account. If the drive or this app signed in with it, they sign out."), tr("Delete Key"), true, move || {
                    let Some(session) = shown.session() else { return };
                    let (client, id, weak_row, done) = (session.connection.client.clone(), id.clone(), weak_row.clone(), shown.clone());
                    crate::tasks::run(async move { client.delete_api_key(&id).await.map_err(|error| verso_desktop::errors::said(&error)) }, move |outcome| match outcome {
                        Ok(()) => {
                            if let Some(row) = weak_row.upgrade() {
                                row.set_visible(false);
                            }
                        }
                        Err(message) => done.toast(&message),
                    });
                });
            });
            row.add_suffix(&delete);
            group.add(&row);
        }
    });
    group
}

/// A new key's secret, shown once, with a button to copy it.
fn show_secret(window: &Window, secret: &str) {
    let dialog = adw::AlertDialog::new(Some(tr("Your New API Key")), Some(tr("Copy it now: Immich shows it only once.")));
    let label = gtk::Label::builder().label(secret).selectable(true).wrap(true).css_classes(["monospace"]).build();
    dialog.set_extra_child(Some(&label));
    dialog.add_responses(&[("copy", tr("Copy")), ("close", tr("Done"))]);
    dialog.set_response_appearance("copy", adw::ResponseAppearance::Suggested);
    dialog.set_close_response("close");
    let (weak_window, secret) = (window.downgrade(), secret.to_owned());
    dialog.connect_response(Some("copy"), move |_, _| {
        if let Some(window) = weak_window.upgrade() {
            window.clipboard().set_text(&secret);
            window.toast(tr("Key copied"));
        }
    });
    dialog.present(Some(window));
}
