//! Verso's background service where no systemd unit can run it: as a Flatpak (`verso_core::product::VERSO_FLATPAK`) and
//! as an AppImage (`VERSO_APPIMAGE`). It starts as an instance of the app of its own that outlives the window that
//! started it: the Flatpak's through the Flatpak portal (`flatpak-spawn`), the AppImage's by running the AppImage file
//! again (`$APPIMAGE verso-service daemon`), whose mount is then the service's own and does not go with the window's.
//! At login the Flatpak asks the Background portal, which the user may refuse in their settings, and the AppImage
//! writes an autostart entry naming its file as it is now. The service stops when asked over D-Bus (`Quit`).
//! ARCHITECTURE.md, "Verso as a Flatpak" and "Verso as an AppImage".

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::time::Duration;

use verso_linux::dbus;
use verso_linux::paths::Paths;

/// The service, as the Flatpak names its command and as the AppImage is given it.
const SERVICE: [&str; 2] = ["verso-service", "daemon"];

/// Run `work` on a runtime and a thread of its own: callers may be on the app's runtime already.
pub(crate) fn run<T: Send + 'static>(work: impl std::future::Future<Output = T> + Send + 'static) -> Option<T> {
    std::thread::spawn(move || tokio::runtime::Builder::new_current_thread().enable_all().build().ok().map(|runtime| runtime.block_on(work)))
        .join()
        .ok()
        .flatten()
}

/// Whether the service holds its name on the session bus.
async fn running(connection: &zbus::Connection) -> bool {
    let Ok(proxy) = zbus::fdo::DBusProxy::new(connection).await else { return false };
    let Ok(name) = zbus::names::BusName::try_from(dbus::bus_name()) else { return false };
    proxy.name_has_owner(name).await.unwrap_or(false)
}

fn spawn() -> Result<(), String> {
    use std::os::unix::process::CommandExt;
    let mut command = if verso_core::product::current().appimage {
        let mut command = Command::new(verso_linux::autostart::image()?);
        // A process group of its own, so a terminal closing with the window does not take the service with it.
        command.process_group(0);
        command.args(SERVICE);
        command
    } else {
        let mut command = Command::new("flatpak-spawn");
        command.args(SERVICE);
        command
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(drop)
        .map_err(|error| format!("the service did not start: {error}"))
}

/// Start the service, unless it runs.
pub fn start() -> Result<(), String> {
    let running = run(async {
        match zbus::Connection::session().await {
            Ok(connection) => running(&connection).await,
            Err(_) => false,
        }
    });
    if running == Some(true) { Ok(()) } else { spawn() }
}

/// Stop the service, and wait for its name to go, up to three seconds.
pub fn stop() {
    run(async {
        let Ok(connection) = zbus::Connection::session().await else { return };
        let name = dbus::bus_name();
        let _ = connection.call_method(Some(name.as_str()), dbus::OBJECT_PATH, Some(dbus::INTERFACE), "Quit", &()).await;
        for _ in 0..30 {
            if !running(&connection).await {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    });
}

/// Start the service again, which reads its settings and sign-in as it starts.
pub fn restart() -> Result<(), String> {
    stop();
    spawn()
}

/// Ask that the service start at every login, giving `reason`: the Background portal for the Flatpak, where the desktop
/// asks the user the first time, and an autostart entry for the AppImage.
pub fn run_at_login(reason: &str) {
    if verso_core::product::current().appimage {
        match verso_linux::autostart::write(&Paths::from_environment()) {
            Ok(()) => {}
            Err(error) => log::warn!("could not ask to start at login: {error}"),
        }
        return;
    }
    let reason = reason.to_owned();
    run(async move {
        let Ok(connection) = zbus::Connection::session().await else { return };
        let mut options: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
        options.insert("reason", reason.as_str().into());
        options.insert("autostart", true.into());
        options.insert("commandline", SERVICE.to_vec().into());
        options.insert("dbus-activatable", false.into());
        let asked = connection
            .call_method(Some("org.freedesktop.portal.Desktop"), "/org/freedesktop/portal/desktop", Some("org.freedesktop.portal.Background"), "RequestBackground", &("", options))
            .await;
        if let Err(error) = asked {
            log::warn!("could not ask to start at login: {error}");
        }
    });
}

/// Name the AppImage file's place as it is now in the autostart entry, where there is one.
pub fn refresh_login() {
    verso_linux::autostart::refresh(&Paths::from_environment());
}

/// Take the AppImage's autostart entry away (signing out), so the service no longer starts at login.
pub fn stop_at_login() {
    verso_linux::autostart::remove(&Paths::from_environment());
}
