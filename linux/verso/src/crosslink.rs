//! Immich Crosslink from Verso Gallery (ARCHITECTURE.md, "Links on Linux, and the Files extension"): Show in *app* for each other participant that shows
//! an item's kind, by the name and icon its desktop entry gives, Verso Drive among them, the link sent to that app
//! alone. Open in Immich and Copy Immich Link follow their own switch, in Verso's General. A Flatpak offers one Show in
//! Another App… instead (`ANOTHER_APP`).

use adw::prelude::*;
use gtk::{gio, glib};
use verso_core::settings::Config;
use verso_linux::crosslink_apps::{self, CrosslinkApp};
use verso_linux::i18n::tr;
use verso_linux::participants;

use crate::window::Window;

/// Verso's settings, as both halves read them.
fn config() -> Option<Config> {
    let paths = verso_linux::paths::Paths::from_environment();
    Config::from_toml(&std::fs::read_to_string(paths.config_file()).unwrap_or_default()).ok()
}

/// Whether the menus offer Open in Immich and Copy Immich Link (`web.links`).
pub fn web_links() -> bool {
    config().is_none_or(|config| config.web_links)
}

/// The one Show in of Verso's Flatpak, as its sandbox cannot list the other apps: Show in Another App…, which asks the
/// system to let the user choose (the OpenURI portal), as the protocol's second way to offer Show in has it.
pub const ANOTHER_APP: &str = "another-app";

/// The participants offered for an item of `kind` (`asset`, `album`, `person`, `place`): found now, announcing the
/// kind, not switched off in Crosslink, and never Verso Gallery itself. None while Immich Crosslink is off, and none in
/// a Flatpak, which offers Show in Another App… instead.
pub fn offered(kind: &str) -> Vec<CrosslinkApp> {
    if verso_core::product::current().sandboxed {
        return Vec::new();
    }
    let Some(config) = config().filter(|config| config.crosslink_enabled) else { return Vec::new() };
    crosslink_apps::installed_except(&[participants::GALLERY.id])
        .into_iter()
        .filter(|app| app.shows.iter().any(|shown| shown == kind) && !crosslink_apps::is_hidden(&config.crosslink_hidden, &app.id))
        .collect()
}

/// Add Open in Immich and Copy Immich Link (`{prefix}.open-in-immich`, `{prefix}.copy-link`) where their switch is on,
/// then Show in *app* for each participant offered for `kind`, as `{prefix}.show-in` with the app's id.
pub fn append(menu: &gio::Menu, kind: &str, prefix: &str) {
    if web_links() {
        menu.append(Some(tr("Open in Immich")), Some(&format!("{prefix}.open-in-immich")));
        menu.append(Some(tr("Copy Immich Link")), Some(&format!("{prefix}.copy-link")));
    }
    if verso_core::product::current().sandboxed {
        if config().is_some_and(|config| config.crosslink_enabled) {
            let item = gio::MenuItem::new(Some(tr("Show in Another App…")), None);
            item.set_action_and_target_value(Some(&format!("{prefix}.show-in")), Some(&ANOTHER_APP.to_variant()));
            menu.append_item(&item);
        }
        return;
    }
    for app in offered(kind) {
        let item = gio::MenuItem::new(Some(&tr("Show in {app}").replace("{app}", &app.name)), None);
        item.set_action_and_target_value(Some(&format!("{prefix}.show-in")), Some(&app.id.to_variant()));
        menu.append_item(&item);
    }
}

/// Hand `link` to the system to show in the app the user chooses (the OpenURI portal, asking).
fn ask_which_app(window: &Window, link: &str) {
    let Ok(bus) = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE) else {
        return window.toast(tr("No app could be asked to show it."));
    };
    let options = glib::VariantDict::new(None);
    options.insert("ask", true);
    let parameters = glib::Variant::tuple_from_iter(["".to_variant(), link.to_variant(), options.end()]);
    let weak = window.downgrade();
    bus.call(
        Some("org.freedesktop.portal.Desktop"),
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.OpenURI",
        "OpenURI",
        Some(&parameters),
        None,
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
        move |outcome| {
            if let (Err(error), Some(window)) = (outcome, weak.upgrade()) {
                window.toast(&tr("No app could be asked to show it: {error}").replace("{error}", &error.to_string()));
            }
        },
    );
}

/// Send `link` to the participant `id` alone, never through the scheme's default handler; tell the user when it
/// cannot be sent.
pub fn send(window: &Window, id: &str, link: &str) {
    if id == ANOTHER_APP {
        return ask_which_app(window, link);
    }
    // Found as the protocol finds participants: among the apps registered for the scheme, by desktop entry id.
    let found = gio::AppInfo::all_for_type(crosslink_apps::SCHEME_TYPE).into_iter().find(|app| app.id().as_deref() == Some(id));
    let Some(app) = found else {
        return window.toast(tr("That app is no longer there."));
    };
    let context = WidgetExt::display(window).app_launch_context();
    if let Err(error) = app.launch_uris(&[link], Some(&context)) {
        window.toast(&tr("{app} could not be opened: {error}").replace("{app}", &app.name()).replace("{error}", &error.to_string()));
    }
}
