//! The tray icon (ARCHITECTURE.md, "The tray"): the Mac's menu bar item on Linux, served by the daemon itself, as a
//! StatusNotifierItem with a `com.canonical.dbusmenu` menu. Both are D-Bus alone, so the static daemon needs no
//! toolkit. KDE Plasma shows it in its system tray; GNOME shows it where the AppIndicator extension is on (Ubuntu,
//! Bazzite), and nowhere on stock GNOME, where the app and Files' sidebar stay the way in.
//!
//! The menu is the Mac's: the state on its first line, then grey lines saying what each is, then the way to the
//! drive, the settings and the app, and at the foot Sign Out… and Quit, which unmounts, as the tray menus of KDE and
//! the apps that use GNOME's AppIndicator end.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

use verso_core::product::{self, Product};

use crate::dbus::State;
use crate::i18n::tr;

const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/MenuBar";
const WATCHER: &str = "org.kde.StatusNotifierWatcher";
/// A menu item's properties, by dbusmenu's names (`label`, `enabled`, `type`).
type Properties = HashMap<String, OwnedValue>;
/// One item and its children, dbusmenu's `(ia{sv}av)`.
type Layout = (i32, Properties, Vec<OwnedValue>);
/// Icons as pixels, which the item never sends (it names a themed icon): StatusNotifierItem's `a(iiay)`.
type Pixmaps = Vec<(i32, i32, Vec<u8>)>;

/// The icon the package installs for the view's state (DESIGN.md, "The icon family"): the symbolic one, which themes
/// recolour, or in colour where `tray.colour` asks. The top bar shows the state without the menu being opened: signed
/// out first, then the server unreachable, then the drive unmounted.
fn icon_for(view: &View, colour: bool) -> String {
    let id = view.product.id;
    let state = match view.state {
        State::SignedOut => Some("signed-out"),
        State::Offline => Some("offline"),
        _ if view.unmounted && view.mount_point.is_empty() => Some("unmounted"),
        _ => None,
    };
    match (colour, state) {
        (true, Some(state)) => format!("{id}-tray-{state}"),
        (true, None) => format!("{id}-tray"),
        (false, Some(state)) => format!("{id}-{state}-symbolic"),
        (false, None) => view.product.symbolic_icon(),
    }
}

/// Whether the top bar icon is in colour (`tray.colour`), read as it is asked for, so a change in Preferences counts
/// at once.
fn colour_chosen() -> bool {
    let paths = crate::paths::Paths::from_environment();
    std::fs::read_to_string(paths.config_file())
        .ok()
        .and_then(|text| verso_core::settings::Config::from_toml(&text).ok())
        .is_some_and(|config| config.tray_colour)
}

/// The item's id: the product's folder name (`verso`).
fn item_id() -> &'static str {
    product::current().folder
}

/// What the tray shows: the daemon's view of the server, kept up to date as the state changes.
#[derive(Debug, Clone)]
pub struct View {
    pub state: State,
    pub server_url: String,
    pub server_version: String,
    pub account: String,
    /// Where the drive is mounted; empty while Verso's drive is off, and the menu then offers no way to it.
    pub mount_point: String,
    /// A newer release, once the daemon has seen one (`crate::updates`).
    pub update: Option<crate::updates::Release>,
    /// Whether this install looks for releases (the rpm's and the deb's, `updates.check`): the menu has Check for
    /// Updates.
    pub checks_updates: bool,
    /// Verso's window, where it is found: the menu offers to open it, and its preferences and signing out go to it.
    pub gallery: Option<std::path::PathBuf>,
    /// Which product the daemon is, for the menu's names.
    pub product: &'static Product,
    /// Verso's drive is on but not mounted (unmounted from Files, or from the menu): the menu offers to mount it.
    pub unmounted: bool,
}

/// The program the tray opens as the app: Verso's window, where it is found. An AppImage's is the AppImage file run
/// again, an instance of its own (the service's mount goes with the service, and the window it opened should not).
pub fn gallery_program() -> Option<std::path::PathBuf> {
    if product::current().appimage {
        let image = std::env::var_os("APPIMAGE").map(std::path::PathBuf::from).filter(|file| file.is_absolute());
        if image.is_some() {
            return image;
        }
    }
    crate::programs::find(product::WINDOW)
}

/// One line of the menu: its label, and what clicking it does (`None` for a grey line).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line {
    Text(String),
    Separator,
    Action(String, Action),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    OpenDrive,
    OpenSettings,
    OpenGallery,
    OpenUpdate,
    Mount,
    Unmount,
    SignOut,
    Quit,
    /// Ask the server now, while it cannot be reached, rather than at the next poll.
    TryAgain,
    /// Look for a newer release now (`updates::check_now`).
    CheckForUpdates,
}

/// What Verso's window is given to open on its Preferences: an address no other program claims, which it receives as
/// a file to open (in the window already running, if one is).
pub const OPEN_SETTINGS: &str = "verso:settings";
/// What Verso's window is given to open on its Account page, asking whether to sign out: the service has no window to
/// ask in, and signing out is never done without asking.
pub const OPEN_SIGN_OUT: &str = "verso:sign-out";

impl View {
    fn host(&self) -> String {
        url_host(&self.server_url)
    }

    /// The first line, as the Mac's menu has it.
    pub fn status_line(&self) -> String {
        match self.state {
            State::Online => tr("Connected to {server}").replace("{server}", &self.host()),
            State::Offline => tr("{server} is not reachable").replace("{server}", &self.host()),
            State::SignedOut => tr("Signed out of Immich").to_owned(),
            State::Connecting => tr("Signed in to {server}").replace("{server}", &self.host()),
        }
    }

    /// Every line of the menu, in order.
    pub fn lines(&self) -> Vec<Line> {
        let mut lines = vec![Line::Text(self.status_line())];
        // What the icon's pause says: Verso's drive is on, and unmounted.
        if self.unmounted && self.mount_point.is_empty() {
            lines.push(Line::Text(tr("Verso Drive is unmounted").to_owned()));
        }
        if !self.server_version.is_empty() {
            lines.push(Line::Text(tr("Server version: Immich {version}").replace("{version}", &self.server_version)));
        }
        if !self.account.is_empty() {
            lines.push(Line::Text(tr("Signed in as: {account}").replace("{account}", &self.account)));
        }
        // The service tries again by itself every few seconds; this is for not waiting.
        if self.state == State::Offline {
            lines.push(Line::Action(tr("Try Again Now").to_owned(), Action::TryAgain));
        }
        lines.push(Line::Separator);
        if self.gallery.is_some() {
            lines.push(Line::Action(tr("Open {app}").replace("{app}", self.product.name), Action::OpenGallery));
        }
        if !self.mount_point.is_empty() {
            lines.push(Line::Action(tr("Open in Files").to_owned(), Action::OpenDrive));
        }
        // Verso's drive from the menu, as from Preferences: Unmount while it is mounted, Mount while it is on and not,
        // so nobody has to look for it in Preferences to have it back.
        if self.product.drive {
            if !self.mount_point.is_empty() {
                lines.push(Line::Action(tr("Unmount Verso Drive").to_owned(), Action::Unmount));
            } else if self.unmounted {
                lines.push(Line::Action(tr("Mount Verso Drive").to_owned(), Action::Mount));
            }
        }
        lines.push(Line::Action(tr("Preferences…").to_owned(), Action::OpenSettings));
        // As the Mac's menu bar icon has it, for the installs that look for releases themselves.
        if self.checks_updates && self.update.is_none() {
            lines.push(Line::Action(tr("Check for Updates").to_owned(), Action::CheckForUpdates));
        }
        if let Some(release) = &self.update {
            lines.push(Line::Separator);
            let get = tr("Get {app} {version}…").replace("{app}", self.product.name).replace("{version}", &release.version);
            lines.push(Line::Action(get, Action::OpenUpdate));
        }
        lines.push(Line::Separator);
        if self.state == State::SignedOut {
            // Signed out already: the way back in is the window, which asks.
            lines.push(Line::Action(tr("Sign In…").to_owned(), Action::OpenGallery));
        } else {
            lines.push(Line::Action(tr("Sign Out…").to_owned(), Action::SignOut));
        }
        lines.push(Line::Action(tr("Quit {app}").replace("{app}", self.product.name), Action::Quit));
        lines
    }
}

/// What Verso's double click opens, read as it happens, so a change in Preferences counts at once: the drive in
/// Files only while it is mounted, else the app.
fn double_click_action(view: &View) -> Action {
    let paths = crate::paths::Paths::from_environment();
    let chosen = std::fs::read_to_string(paths.config_file())
        .ok()
        .and_then(|text| verso_core::settings::Config::from_toml(&text).ok())
        .map(|config| config.tray_double_click)
        .unwrap_or_default();
    match chosen.as_str() {
        "drive" if !view.mount_point.is_empty() => Action::OpenDrive,
        "preferences" => Action::OpenSettings,
        _ => Action::OpenGallery,
    }
}

/// `photos.example.org` from `https://photos.example.org:443/`, as the Mac's menu names the server.
fn url_host(url: &str) -> String {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let host = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    host.rsplit_once(':').filter(|(_, port)| port.chars().all(|c| c.is_ascii_digit())).map_or(host, |(host, _)| host).to_owned()
}

/// The menu's layout as dbusmenu wants it: the root (id 0) with one child per line, ids from 1 in order.
fn layout(lines: &[Line]) -> Layout {
    let children = lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| {
            let item: Layout = (index as i32 + 1, properties(line), Vec::new());
            OwnedValue::try_from(Value::from(item)).ok()
        })
        .collect();
    let mut root = HashMap::new();
    root.insert("children-display".to_owned(), owned("submenu"));
    (0, root, children)
}

fn properties(line: &Line) -> Properties {
    let mut properties = HashMap::new();
    match line {
        Line::Text(label) => {
            properties.insert("label".to_owned(), owned(label.as_str()));
            properties.insert("enabled".to_owned(), OwnedValue::from(false));
        }
        Line::Separator => {
            properties.insert("type".to_owned(), owned("separator"));
        }
        Line::Action(label, _) => {
            properties.insert("label".to_owned(), owned(label.as_str()));
        }
    }
    properties
}

fn owned(text: &str) -> OwnedValue {
    OwnedValue::try_from(Value::from(text)).expect("a string is a value")
}

struct Shared {
    view: Mutex<View>,
    revision: Mutex<u32>,
}

impl Shared {
    fn lines(&self) -> Vec<Line> {
        self.view.lock().expect("tray view lock").lines()
    }
}

/// `org.kde.StatusNotifierItem`: the icon itself.
struct Item {
    shared: Arc<Shared>,
}

#[zbus::interface(name = "org.kde.StatusNotifierItem")]
impl Item {
    #[zbus(property)]
    fn category(&self) -> &str {
        "ApplicationStatus"
    }

    #[zbus(property)]
    fn id(&self) -> &str {
        item_id()
    }

    #[zbus(property)]
    fn title(&self) -> String {
        product::current().name.to_owned()
    }

    #[zbus(property)]
    fn status(&self) -> &str {
        "Active"
    }

    #[zbus(property)]
    fn window_id(&self) -> i32 {
        0
    }

    #[zbus(property)]
    fn icon_name(&self) -> String {
        icon_for(&self.shared.view.lock().expect("tray view lock"), colour_chosen())
    }

    #[zbus(property)]
    fn icon_pixmap(&self) -> Pixmaps {
        Vec::new()
    }

    #[zbus(property)]
    fn overlay_icon_name(&self) -> &str {
        ""
    }

    #[zbus(property)]
    fn attention_icon_name(&self) -> &str {
        ""
    }

    #[zbus(property)]
    fn tool_tip(&self) -> (String, Pixmaps, String, String) {
        let view = self.shared.view.lock().expect("tray view lock");
        (icon_for(&view, colour_chosen()), Vec::new(), product::current().name.to_owned(), view.status_line())
    }

    /// The menu is all there is, as on the Mac: a click shows it rather than calling `Activate`.
    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn menu(&self) -> ObjectPath<'_> {
        ObjectPath::from_static_str_unchecked(MENU_PATH)
    }

    /// A double click, as GNOME's AppIndicator extension sends it (a click shows the menu): Verso opens what its
    /// General page says (`tray.double_click`), itself at first.
    fn activate(&self, _x: i32, _y: i32) {
        let view = self.shared.view.lock().expect("tray view lock");
        run(double_click_action(&view), &view);
    }


    fn secondary_activate(&self, _x: i32, _y: i32) {}

    fn context_menu(&self, _x: i32, _y: i32) {}

    fn scroll(&self, _delta: i32, _orientation: &str) {}

    #[zbus(signal)]
    async fn new_tool_tip(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_icon(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// `com.canonical.dbusmenu`: the menu, flat, built anew from the view at each change.
struct Menu {
    shared: Arc<Shared>,
}

#[zbus::interface(name = "com.canonical.dbusmenu")]
impl Menu {
    #[zbus(property)]
    fn version(&self) -> u32 {
        3
    }

    #[zbus(property)]
    fn text_direction(&self) -> &str {
        "ltr"
    }

    #[zbus(property)]
    fn status(&self) -> &str {
        "normal"
    }

    #[zbus(property)]
    fn icon_theme_path(&self) -> Vec<String> {
        Vec::new()
    }

    fn get_layout(
        &self,
        _parent_id: i32,
        _recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> (u32, Layout) {
        (*self.shared.revision.lock().expect("tray revision lock"), layout(&self.shared.lines()))
    }

    fn get_group_properties(&self, ids: Vec<i32>, _property_names: Vec<String>) -> Vec<(i32, Properties)> {
        let lines = self.shared.lines();
        let wanted = |id: &i32| ids.is_empty() || ids.contains(id);
        lines.iter().enumerate().map(|(index, line)| (index as i32 + 1, properties(line))).filter(|(id, _)| wanted(id)).collect()
    }

    fn get_property(&self, id: i32, name: &str) -> zbus::fdo::Result<OwnedValue> {
        let lines = self.shared.lines();
        let line = lines.get((id - 1).max(0) as usize).ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("no item {id}")))?;
        properties(line).remove(name).ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("no property {name}")))
    }

    fn event(&self, id: i32, event_id: &str, _data: OwnedValue, _timestamp: u32) {
        if event_id != "clicked" {
            return;
        }
        let view = self.shared.view.lock().expect("tray view lock").clone();
        if let Some(Line::Action(_, action)) = view.lines().get((id - 1).max(0) as usize) {
            run(*action, &view);
        }
    }

    fn event_group(&self, events: Vec<(i32, String, OwnedValue, u32)>) -> Vec<i32> {
        for (id, event_id, data, timestamp) in events {
            self.event(id, &event_id, data, timestamp);
        }
        Vec::new()
    }

    fn about_to_show(&self, _id: i32) -> bool {
        false
    }

    fn about_to_show_group(&self, _ids: Vec<i32>) -> (Vec<i32>, Vec<i32>) {
        (Vec::new(), Vec::new())
    }

    #[zbus(signal)]
    async fn layout_updated(emitter: &SignalEmitter<'_>, revision: u32, parent: i32) -> zbus::Result<()>;
}

/// Do what a line of the menu says: open the drive in the file manager, the window, its preferences or the question to
/// sign out, or quit.
fn run(action: Action, view: &View) {
    let (program, arguments): (std::path::PathBuf, Vec<String>) = match action {
        Action::OpenDrive => ("xdg-open".into(), vec![view.mount_point.clone()]),
        Action::OpenGallery | Action::OpenSettings | Action::SignOut => {
            let Some(window) = &view.gallery else { return log::warn!("the tray's {action:?}: Verso's window is not installed") };
            let request = match action {
                Action::OpenSettings => Some(OPEN_SETTINGS.to_owned()),
                Action::SignOut => Some(OPEN_SIGN_OUT.to_owned()),
                _ => None,
            };
            (window.clone(), request.into_iter().collect())
        }
        Action::OpenUpdate => match &view.update {
            Some(release) => ("xdg-open".into(), vec![release.page.clone()]),
            None => return,
        },
        // Quit quits Verso: its window closes, and its service stops, which unmounts as it stops (an unmount alone
        // leaves the service running without the drive).
        Action::Quit => {
            let app = view.product.id;
            tokio::spawn(async move {
                quit_window(app).await;
                leave();
            });
            return;
        }
        Action::Unmount => return unmount(),
        Action::TryAgain => return crate::daemon::check_now(),
        Action::CheckForUpdates => return crate::updates::check_now(),
        // The command restarts the service, which mounts; launched in a scope of its own, it outlives this one.
        Action::Mount => match std::env::current_exe() {
            Ok(program) => (program, vec!["mount".to_owned()]),
            Err(error) => return log::warn!("the tray's Mount did not start: {error}"),
        },
    };
    if let Err(error) = launch(&program, &arguments) {
        log::warn!("the tray's {action:?} did not start: {error}");
    }
}

/// Quit the app's window, if it is open, as its own Quit does: its `quit` action, through `org.freedesktop.Application`.
/// A window that is not open is not started for it.
async fn quit_window(app: &'static str) {
    let Ok(connection) = zbus::Connection::session().await else { return };
    let Ok(name) = zbus::names::BusName::try_from(app) else { return };
    let open = match zbus::fdo::DBusProxy::new(&connection).await {
        Ok(bus) => bus.name_has_owner(name).await.unwrap_or(false),
        Err(_) => false,
    };
    if !open {
        return;
    }
    let path = format!("/{}", app.replace('.', "/"));
    let body = ("quit", Vec::<Value>::new(), HashMap::<&str, Value>::new());
    if let Err(error) = connection.call_method(Some(app), path.as_str(), Some("org.freedesktop.Application"), "ActivateAction", &body).await {
        log::warn!("the tray's Quit did not close the window: {error}");
    }
}

/// Quit without a drive (Verso's, switched off): the daemon stops as a `systemctl stop` would have it, and its service
/// does not start it again until the next login.
pub(crate) fn leave() {
    // SAFETY: `kill` with this process's own id and a signal it handles (`daemon::wait_for_stop`).
    unsafe {
        libc::kill(libc::getpid(), libc::SIGTERM);
    }
}

/// Start a program the tray opens (the app, the file manager, a browser) as the desktop would, outside the daemon's
/// service: started as its child, it was in the service's group, which systemd stops whole, so a window the tray
/// opened closed whenever the daemon stopped (signing out, Quit, a change of settings). Its
/// own scope keeps it; where `systemd-run` is missing, it starts as a child. Either way the daemon reaps it.
fn launch(program: &std::path::Path, arguments: &[String]) -> std::io::Result<()> {
    // In a Flatpak, the window opens in an instance of the sandbox of its own (the Flatpak portal's), which outlives
    // this one: a child would close with the service.
    if verso_core::product::current().sandboxed {
        let child = std::process::Command::new("flatpak-spawn").arg(program).args(arguments).spawn()?;
        std::thread::spawn(move || {
            let mut child = child;
            let _ = child.wait();
        });
        return Ok(());
    }
    let scoped = std::process::Command::new("systemd-run")
        .args(["--user", "--scope", "--collect", "--quiet", "--"])
        .arg(program)
        .args(arguments)
        .spawn();
    let child = match scoped {
        Ok(child) => child,
        Err(_) => std::process::Command::new(program).args(arguments).spawn()?,
    };
    std::thread::spawn(move || {
        let mut child = child;
        let _ = child.wait();
    });
    Ok(())
}

/// Unmount Verso Drive: `verso-service unmount`, as the window's Unmount and Files' eject, so the drive leaves cleanly
/// and the service goes on without it until the next login or Mount. It refuses while a file is uploading, and says why
/// in a notification.
fn unmount() {
    let Ok(program) = std::env::current_exe() else { return };
    std::thread::spawn(move || {
        let outcome = std::process::Command::new(program).arg("unmount").output();
        let refusal = match outcome {
            Ok(output) if output.status.success() => return,
            Ok(output) => String::from_utf8_lossy(&output.stderr).trim().trim_start_matches("error:").trim().to_owned(),
            Err(error) => error.to_string(),
        };
        log::warn!("the tray did not unmount: {refusal}");
        if let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() {
            runtime.block_on(crate::notify::notify(verso_core::product::current().name, &refusal));
        }
    });
}

/// Show the tray icon on `connection`, and keep it registered with the desktop's tray, which may start after the
/// daemon or start again. Nothing shows where no tray watches (stock GNOME). The task that keeps it registered holds
/// the connection: whoever stops serving on it aborts the task, or the item stays in the tray.
pub async fn show(connection: &zbus::Connection, view: View) -> Option<tokio::task::JoinHandle<()>> {
    let shared = Arc::new(Shared { view: Mutex::new(view), revision: Mutex::new(1) });
    let server = connection.object_server();
    if server.at(ITEM_PATH, Item { shared: shared.clone() }).await.is_err() || server.at(MENU_PATH, Menu { shared }).await.is_err() {
        log::info!("no tray icon: its D-Bus objects could not be served");
        return None;
    }
    let connection = connection.clone();
    Some(tokio::spawn(async move {
        register(&connection).await;
        let Ok(bus) = zbus::fdo::DBusProxy::new(&connection).await else { return };
        let Ok(mut owners) = bus.receive_name_owner_changed_with_args(&[(0, WATCHER)]).await else { return };
        use futures_util::StreamExt;
        while let Some(change) = owners.next().await {
            if change.args().is_ok_and(|args| args.new_owner().is_some()) {
                register(&connection).await;
            }
        }
    }))
}

async fn register(connection: &zbus::Connection) {
    let outcome = connection
        .call_method(Some(WATCHER), "/StatusNotifierWatcher", Some(WATCHER), "RegisterStatusNotifierItem", &(ITEM_PATH,))
        .await;
    match outcome {
        Ok(_) => log::info!("the tray icon is shown"),
        Err(error) => log::debug!("no tray to show the icon in ({error})"),
    }
}

/// The state changed: the menu and the tooltip follow.
pub async fn update(connection: &zbus::Connection, state: State) {
    change(connection, |view| view.state = state).await;
}

/// A newer release is out: the menu offers it.
pub async fn offer_update(connection: &zbus::Connection, release: &crate::updates::Release) {
    change(connection, |view| view.update = Some(release.clone())).await;
}

/// Draw the icon again: its colour was changed in Preferences (`tray.colour`).
pub async fn refresh_icon(connection: &zbus::Connection) {
    if let Ok(item) = connection.object_server().interface::<_, Item>(ITEM_PATH).await {
        let _ = Item::new_icon(item.signal_emitter()).await;
        let _ = Item::new_tool_tip(item.signal_emitter()).await;
    }
}

async fn change(connection: &zbus::Connection, edit: impl FnOnce(&mut View)) {
    let Ok(menu) = connection.object_server().interface::<_, Menu>(MENU_PATH).await else { return };
    let revision = {
        let menu = menu.get().await;
        edit(&mut menu.shared.view.lock().expect("tray view lock"));
        let mut revision = menu.shared.revision.lock().expect("tray revision lock");
        *revision += 1;
        *revision
    };
    let _ = Menu::layout_updated(menu.signal_emitter(), revision, 0).await;
    if let Ok(item) = connection.object_server().interface::<_, Item>(ITEM_PATH).await {
        let _ = Item::new_tool_tip(item.signal_emitter()).await;
        let _ = Item::new_icon(item.signal_emitter()).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(state: State) -> View {
        View {
            state,
            server_url: "https://photos.example.org:443/".to_owned(),
            server_version: "v3.3.5".to_owned(),
            account: "admin@example.com".to_owned(),
            mount_point: "/home/tester/Verso".to_owned(),
            update: None,
            checks_updates: false,
            gallery: Some("/usr/local/bin/verso".into()),
            product: &verso_core::product::VERSO,
            unmounted: false,
        }
    }

    #[test]
    fn the_menu_reads_as_the_macs() {
        let lines = view(State::Online).lines();
        assert_eq!(lines[0], Line::Text("Connected to photos.example.org".to_owned()));
        assert_eq!(lines[1], Line::Text("Server version: Immich v3.3.5".to_owned()));
        assert_eq!(lines[2], Line::Text("Signed in as: admin@example.com".to_owned()));
        assert_eq!(lines[3], Line::Separator);
        assert_eq!(lines[4], Line::Action("Open Verso".to_owned(), Action::OpenGallery), "the app, first");
        assert_eq!(lines[5], Line::Action("Open in Files".to_owned(), Action::OpenDrive));
        assert_eq!(lines[6], Line::Action("Unmount Verso Drive".to_owned(), Action::Unmount), "the drive's opposite of how it is");
        assert_eq!(lines[7], Line::Action("Preferences…".to_owned(), Action::OpenSettings));
        assert_eq!(lines[8], Line::Separator);
        assert_eq!(lines[9], Line::Action("Sign Out…".to_owned(), Action::SignOut));
        assert_eq!(lines.last(), Some(&Line::Action("Quit Verso".to_owned(), Action::Quit)), "Quit at the foot");
        let offline = view(State::Offline).lines();
        assert_eq!(offline[0], Line::Text("photos.example.org is not reachable".to_owned()));
        assert_eq!(offline[3], Line::Action("Try Again Now".to_owned(), Action::TryAgain), "under the grey lines");
        assert!(!lines.iter().any(|line| matches!(line, Line::Action(_, Action::TryAgain))), "only while offline");
        let release = crate::updates::Release { version: "2.21.0".to_owned(), page: "https://example.org/".to_owned() };
        let behind = View { update: Some(release), ..view(State::Online) };
        let behind = behind.lines();
        assert_eq!(behind[behind.len() - 4], Line::Action("Get Verso 2.21.0…".to_owned(), Action::OpenUpdate));
        assert_eq!(behind.last(), Some(&Line::Action("Quit Verso".to_owned(), Action::Quit)), "Quit stays last");
    }

    #[test]
    fn the_icon_shows_the_state() {
        let unmounted = |state| View { mount_point: String::new(), unmounted: true, ..view(state) };
        assert_eq!(icon_for(&view(State::Online), false), "dev.hviid.Verso-symbolic");
        assert_eq!(icon_for(&view(State::Connecting), false), "dev.hviid.Verso-symbolic");
        assert_eq!(icon_for(&view(State::Offline), false), "dev.hviid.Verso-offline-symbolic");
        assert_eq!(icon_for(&view(State::SignedOut), false), "dev.hviid.Verso-signed-out-symbolic");
        assert_eq!(icon_for(&unmounted(State::Online), false), "dev.hviid.Verso-unmounted-symbolic");
        assert_eq!(icon_for(&unmounted(State::Offline), false), "dev.hviid.Verso-offline-symbolic", "a problem before a choice");
        assert_eq!(icon_for(&unmounted(State::SignedOut), true), "dev.hviid.Verso-tray-signed-out");
        assert_eq!(icon_for(&view(State::Online), true), "dev.hviid.Verso-tray");
        assert_eq!(icon_for(&unmounted(State::Online), true), "dev.hviid.Verso-tray-unmounted");
    }

    #[test]
    fn the_window_is_offered_only_where_it_is_installed_and_the_drive_only_while_it_is_on() {
        let without = View { gallery: None, ..view(State::Online) }.lines();
        assert!(!without.iter().any(|line| matches!(line, Line::Action(_, Action::OpenGallery))));
        assert_eq!(without[4], Line::Action("Open in Files".to_owned(), Action::OpenDrive));
        let off = View { mount_point: String::new(), ..view(State::Online) }.lines();
        assert!(!off.iter().any(|line| matches!(line, Line::Action(_, Action::OpenDrive | Action::Mount | Action::Unmount))), "no drive while it is off");
        assert_eq!(off[5], Line::Action("Preferences…".to_owned(), Action::OpenSettings));
        let unmounted = View { mount_point: String::new(), unmounted: true, ..view(State::Online) }.lines();
        assert_eq!(unmounted[1], Line::Text("Verso Drive is unmounted".to_owned()), "what the icon's pause says");
        assert_eq!(unmounted[6], Line::Action("Mount Verso Drive".to_owned(), Action::Mount));
        let signed_out = view(State::SignedOut).lines();
        assert_eq!(signed_out[signed_out.len() - 2], Line::Action("Sign In…".to_owned(), Action::OpenGallery), "back in, not out");
        let flatpak = View { product: &verso_core::product::VERSO_FLATPAK, ..view(State::Online) }.lines();
        assert!(!flatpak.iter().any(|line| matches!(line, Line::Action(_, Action::Mount | Action::Unmount))), "a Flatpak has no drive");
    }

    #[test]
    fn hosts_are_named_as_on_the_mac() {
        assert_eq!(url_host("https://photos.example.org:443/"), "photos.example.org");
        assert_eq!(url_host("http://192.168.1.10:2283"), "192.168.1.10");
        assert_eq!(url_host("photos.example.org"), "photos.example.org");
    }

    #[test]
    fn the_layout_has_one_child_per_line() {
        let (root, properties, children) = layout(&view(State::Online).lines());
        assert_eq!(root, 0);
        assert!(properties.contains_key("children-display"));
        assert_eq!(children.len(), 11, "three lines, a separator, the window, the drive, Unmount, Preferences, a separator, Sign Out… and Quit");
        // Each child is the structure dbusmenu wants, (ia{sv}av), inside a variant.
        assert_eq!(children[0].value_signature().to_string(), "(ia{sv}av)");
    }
}
