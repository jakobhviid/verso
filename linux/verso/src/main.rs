//! Verso's window for GNOME: an Immich library to browse, search and organise, in GTK 4 and libadwaita, with its
//! preferences, the drive's among them (ARCHITECTURE.md, "Verso's window"). The tray and the drive are `verso-service`'s.
//!
//! One instance per session (`dev.hviid.Verso`), so the browser's sign-in redirect and immich-crosslink links reach
//! the window already open.

mod account_settings;
mod activity;
mod admin;
mod album_page;
mod albums_page;
mod avatars;
mod cards;
mod collections;
mod connectivity;
mod crosslink;
mod crop;
mod dialogs;
mod drag;
mod drive_preferences;
mod edit;
mod explore;
mod faces;
mod grid;
mod imports;
mod info;
mod links_page;
mod map;
mod memories;
mod menu_actions;
mod motion;
mod notifications;
mod overview;
mod pages;
mod people_page;
mod photo_picker;
mod search_page;
mod preferences;
mod scrubber;
mod sharing;
mod similar;
mod slideshow;
mod stacks;
mod tasks;
mod upgrade;
mod textures;
mod utility_pages;
mod viewer;
mod window;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use verso_linux::i18n::tr;

pub const APP_ID: &str = "dev.hviid.Verso";

/// Whether Verso Drive is on, so the menus offer Show in Files (`mount.enabled`).
pub fn drive_on() -> bool {
    verso_desktop::session::drive_enabled()
}

/// The non-affiliation notice (SPEC.md).
pub const NOTICE: &str = "Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or \
                          sponsored by the Immich project or FUTO. “Immich” is used only to describe the server this \
                          software works with, and remains the mark of its owner.";

fn main() -> glib::ExitCode {
    if std::env::args().nth(1).as_deref() == Some("--probe") {
        return glib::ExitCode::SUCCESS;
    }
    // Verso's folders, keyring items and service, apart from Immich Mount's (`verso_core::product`); built for a
    // Flatpak (`--features flatpak`), without what its sandbox cannot reach.
    verso_core::product::set(if cfg!(feature = "flatpak") { &verso_core::product::VERSO_FLATPAK } else { &verso_core::product::VERSO });
    let application = adw::Application::builder().application_id(APP_ID).flags(gio::ApplicationFlags::HANDLES_OPEN).build();
    application.connect_startup(|_| load_style());
    application.connect_activate(|application| window_of(application).present());
    application.connect_open(|application, files, _hint| {
        let window = window_of(application);
        window.present();
        for file in files {
            let address = file.uri();
            // From the tray: Preferences, or the question to sign out.
            match tray_request(&address).map(str::to_owned) {
                Some(request) => window.when_ready(move |window| match request.as_str() {
                    request if Some(request) == tray_request(verso_linux::tray::OPEN_SETTINGS) => window.show_preferences(None),
                    request if Some(request) == tray_request(verso_linux::tray::OPEN_SIGN_OUT) => {
                        window.show_preferences(Some("account"));
                        window.confirm_sign_out();
                    }
                    // Opened again after an upgrade (`upgrade`), on the page it showed.
                    request if request.starts_with(upgrade::SHOW) => window.select_section(&request[upgrade::SHOW.len()..]),
                    request => eprintln!("the tray asked for something this app does not know: {request}"),
                }),
                None => window.handle_address(&address),
            }
        }
    });
    let about = gio::ActionEntry::builder("about").activate(|application: &adw::Application, _, _| show_about(application)).build();
    let quit = gio::ActionEntry::builder("quit").activate(|application: &adw::Application, _, _| application.quit()).build();
    let preferences = gio::ActionEntry::builder("preferences")
        .activate(|application: &adw::Application, _, _| window_of(application).show_preferences(None))
        .build();
    let shortcuts = gio::ActionEntry::builder("shortcuts").activate(|application: &adw::Application, _, _| show_shortcuts(application)).build();
    // Another window on the same account, as Files opens one: each with its own pages and viewer.
    let new_window = gio::ActionEntry::builder("new-window").activate(|application: &adw::Application, _, _| window::Window::new(application).present()).build();
    application.add_action_entries([about, quit, preferences, shortcuts, new_window]);
    upgrade::follow(&application);
    for (action, _, keys) in SHORTCUTS {
        application.set_accels_for_action(action, keys);
    }
    application.run()
}

/// What the tray asked for, from the address GIO makes of `verso:settings` (it may add slashes). A tray or window from
/// before Verso's names took Immich Mount's place says `immich-mount:`, until the upgrade restarts it.
fn tray_request(address: &str) -> Option<&str> {
    let rest = address.strip_prefix("verso:").or_else(|| address.strip_prefix("immich-mount:"))?;
    Some(rest.trim_start_matches('/').trim_end_matches('/'))
}

fn load_style() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("style.css"));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        // Its own icons (the Date Scroller's, the app icon's designs): in `icons` in the install's folder, as the
        // tarball has them, or, run from a checkout, beside the sources. The app's icon is installed in the icon theme.
        for icons in verso_linux::app_icon::icon_folders() {
            gtk::IconTheme::for_display(&display).add_search_path(icons);
        }
    }
    // The app icon chosen for the style (`app.icon`, `app.icon_dark`): its windows', and the launcher's entry, which an
    // upgrade may have replaced; again whenever libadwaita's style turns light or dark.
    let style = adw::StyleManager::default();
    show_app_icon(style.is_dark());
    style.connect_dark_notify(|style| show_app_icon(style.is_dark()));
}

/// The icon the windows, About and the sign-in page show, the look chosen for the window's style now.
pub fn app_icon_name() -> String {
    verso_desktop::preferences::app_icon_name(adw::StyleManager::default().is_dark())
}

/// The look chosen for the style (`dark`) as the windows' icon, and in the launcher's entry, off the main thread.
fn show_app_icon(dark: bool) {
    verso_linux::app_icon::set_dark_style(dark);
    gtk::Window::set_default_icon_name(&verso_desktop::preferences::app_icon_name(dark));
    std::thread::spawn(move || verso_desktop::preferences::apply_app_icon(dark));
}

/// The app's keyboard shortcuts: its action, what it does, and its keys. The dialog lists exactly these.
pub const SHORTCUTS: &[(&str, &str, &[&str])] = &[
    ("app.new-window", "New Window", &["<Control>n"]),
    ("win.search", "Search", &["<Control>f"]),
    ("win.refresh", "Refresh", &["<Control>r", "F5"]),
    ("win.import", "Import", &["<Control><Shift>i"]),
    ("win.toggle-info", "Show or Hide Info", &["<Control>i"]),
    ("win.zoom-in", "Bigger Thumbnails", &["<Control>plus", "<Control>equal", "<Control>KP_Add"]),
    ("win.zoom-out", "Smaller Thumbnails", &["<Control>minus", "<Control>KP_Subtract"]),
    ("win.new-album", "New Album", &["<Control><Alt>n"]),
    ("app.preferences", "Preferences", &["<Control>comma"]),
    ("app.shortcuts", "Keyboard Shortcuts", &["<Control>question"]),
    ("app.quit", "Quit", &["<Control>q"]),
];

/// Keys that work in the grid and the viewer, listed in the dialog beside the app's own.
const VIEW_KEYS: &[(&str, &str)] = &[
    ("Select All", "<Control>a"),
    ("Move Between Photos", "Left Right Up Down"),
    ("Extend the Selection", "<Shift>Left <Shift>Right"),
    ("Open the Photo", "Return"),
    ("Move to Trash (in Recently Deleted's grid: Delete Forever, after asking)", "Delete"),
    ("Open the Ringed Photo, or Add It to the Selection While Selecting", "space"),
    ("Favorite", "period"),
    ("Info", "<Control>i"),
    ("Previous or Next Photo in the Viewer", "Left Right"),
    ("The Photo's Details, or Back to the Photo, in the Viewer", "Down Up"),
    ("Zoom the Photo", "plus minus 0"),
    ("Back", "Escape"),
    ("Back From a Photo, or Play and Pause a Video, in the Viewer", "space"),
];

fn show_shortcuts(application: &adw::Application) {
    let general = adw::ShortcutsSection::new(Some(tr("General")));
    for (_, title, keys) in SHORTCUTS {
        general.add(adw::ShortcutsItem::new(tr(title), keys[0]));
    }
    let photos = adw::ShortcutsSection::new(Some(tr("Photos")));
    for (title, keys) in VIEW_KEYS {
        photos.add(adw::ShortcutsItem::new(tr(title), keys));
    }
    let dialog = adw::ShortcutsDialog::new();
    dialog.add(general);
    dialog.add(photos);
    dialog.present(application.active_window().as_ref());
}

fn window_of(application: &adw::Application) -> window::Window {
    application.active_window().and_downcast::<window::Window>().unwrap_or_else(|| window::Window::new(application))
}

fn show_about(application: &adw::Application) {
    let about = adw::AboutDialog::builder()
        .application_name("Verso")
        .application_icon(app_icon_name())
        .developer_name("Jakob Hviid")
        .version(verso_core::product::VERSION)
        .comments(format!("{}\n\n{}", tr("Your Immich photos and videos, on your desktop."), tr(NOTICE)))
        .license_type(gtk::License::MitX11)
        .build();
    about.add_credit_section(
        Some(tr("Immich Gallery for the Mac")),
        &["Alessandro Craciun https://github.com/IGOLz/ImmichGallery", "Jakob Hviid https://github.com/jakobhviid"],
    );
    about.add_credit_section(Some(tr("The Drive")), &["Immich Mount https://jakob.hviid.phd/immich-mount/"]);
    about.add_credit_section(Some(tr("The Immich API Layer")), &["immich-rs https://github.com/boul2gom/immich-rs"]);
    about.add_credit_section(Some(tr("Placeholders")), &["ThumbHash by Evan Wallace https://evanw.github.io/thumbhash/"]);
    about.add_legal_section(
        tr("AI Disclosure"),
        None,
        gtk::License::Custom,
        Some(tr("Parts of this project were written with the assistance of AI coding agents. All changes are reviewed by the maintainer.")),
    );
    // Its icon follows the style while it is open.
    let style = adw::StyleManager::default();
    let shown = about.downgrade();
    let following = std::cell::Cell::new(Some(style.connect_dark_notify(move |_| {
        if let Some(about) = shown.upgrade() {
            about.set_application_icon(&app_icon_name());
        }
    })));
    about.connect_closed(move |_| {
        if let Some(handler) = following.take() {
            style.disconnect(handler);
        }
    });
    about.present(application.active_window().as_ref());
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_trays_requests_read_as_gio_spells_them() {
        assert_eq!(super::tray_request(verso_linux::tray::OPEN_SETTINGS), Some("settings"));
        assert_eq!(super::tray_request(verso_linux::tray::OPEN_SIGN_OUT), Some("sign-out"));
        assert_eq!(super::tray_request("verso:///sign-out/"), Some("sign-out"));
        assert_eq!(super::tray_request("immich-mount:settings"), Some("settings"), "from a tray started before the upgrade");
        assert_eq!(super::tray_request("app.immich:///oauth-callback?code=1"), None);
    }
}
