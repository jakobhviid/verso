//! Verso's background service as a Flatpak (`verso_core::product::VERSO_FLATPAK`): a sandbox has no systemd
//! unit to start it, so it starts as an instance of the app's sandbox of its own, through the Flatpak portal
//! (`flatpak-spawn`), which outlives the window that started it; at login through the Background portal, which the
//! user may refuse in their settings; and it stops when asked over D-Bus (`Quit`). ARCHITECTURE.md, "Verso as a
//! Flatpak".

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::time::Duration;

use verso_linux::dbus;

/// The service, as the Flatpak names its command.
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
    Command::new("flatpak-spawn")
        .args(SERVICE)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(drop)
        .map_err(|error| format!("flatpak-spawn: {error}"))
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

/// Ask that the service start at every login (the Background portal), giving `reason`; the desktop asks the user the
/// first time.
pub fn run_at_login(reason: &str) {
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
