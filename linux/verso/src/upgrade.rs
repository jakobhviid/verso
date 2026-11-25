//! Verso upgraded while its window is open (`brew upgrade verso` puts a new program where this one was started from):
//! the window closes, and the new version opens in its place on the page it showed, as the service restarts into the
//! new version by itself (ARCHITECTURE.md, "The window and the service", "Upgrades"). Photos being imported are waited out. Uninstalled,
//! the window closes.

use std::path::Path;
use std::time::{Duration, Instant};

use adw::prelude::*;
use gtk::glib;
use verso_linux::daemon::{ProgramChange, ProgramWatch};

use crate::window::Window;

/// How often the window looks at its program: one file's metadata.
const LOOK: Duration = Duration::from_secs(5);
/// What the new version is opened with to show the page the old one showed (`verso:show:<page>`).
pub const SHOW: &str = "show:";

/// Watch the program this window was started from. A Flatpak is updated by Flatpak, and an AppImage by its file's
/// replacement (a mount of the old file stays as it was); each runs on until closed.
pub fn follow(application: &adw::Application) {
    if !verso_core::product::current().installed() {
        return;
    }
    let Some(mut watch) = ProgramWatch::new() else { return };
    let application = application.downgrade();
    glib::timeout_add_local(LOOK, move || {
        let Some(application) = application.upgrade() else { return glib::ControlFlow::Break };
        let windows: Vec<Window> = application.windows().into_iter().filter_map(|window| window.downcast().ok()).collect();
        match watch.check(Instant::now()) {
            ProgramChange::Unchanged => glib::ControlFlow::Continue,
            ProgramChange::Uninstalled => {
                application.quit();
                glib::ControlFlow::Break
            }
            ProgramChange::Upgraded if windows.iter().any(Window::importing) => glib::ControlFlow::Continue,
            ProgramChange::Upgraded => {
                reopen(&application, &windows, watch.path());
                glib::ControlFlow::Break
            }
        }
    });
}

/// Close this version and open `program`, the new one, once this process is gone: started before, it would hand
/// itself to this one, the app already running, and leave. In a scope of its own, so it outlives this one.
fn reopen(application: &adw::Application, windows: &[Window], program: &Path) {
    let page = windows.iter().find(|window| window.is_active()).or(windows.first()).map(Window::shown_section).unwrap_or_default();
    if !windows.is_empty() {
        let script = r#"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; shift; exec "$@""#;
        let mut arguments = vec!["sh".to_owned(), "-c".to_owned(), script.to_owned(), "sh".to_owned(), std::process::id().to_string()];
        arguments.push(program.to_string_lossy().into_owned());
        if !page.is_empty() {
            arguments.push(format!("verso:{SHOW}{page}"));
        }
        let scoped = std::process::Command::new("systemd-run").args(["--user", "--scope", "--collect", "--quiet", "--"]).args(&arguments).spawn();
        if scoped.is_err() {
            let _ = std::process::Command::new(&arguments[0]).args(&arguments[1..]).spawn();
        }
        eprintln!("Verso was upgraded; the new version opens in this one's place");
    }
    for window in windows {
        window.close();
    }
    // Each window keeps its size as it closes, which takes a moment (`Window::restore_size`).
    let application = application.clone();
    glib::timeout_add_local_once(Duration::from_millis(500), move || application.quit());
}
