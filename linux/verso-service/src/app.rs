//! `verso-service app`: open Verso's window (`verso`), handing it what the command was given.

use std::os::unix::process::CommandExt;
use std::process::Command;

/// Whether there is a display to open a window on.
pub fn has_display() -> bool {
    ["WAYLAND_DISPLAY", "DISPLAY"].iter().any(|variable| std::env::var_os(variable).is_some_and(|value| !value.is_empty()))
}

/// Replace this process with Verso's window, handing it `arguments` (a sign-in redirect, from the scheme handler).
/// Returns only when the window cannot start.
pub fn open(arguments: &[String]) -> anyhow::Error {
    let window = verso_core::product::WINDOW;
    let Some(program) = verso_linux::programs::find(window) else {
        return anyhow::anyhow!("Verso's window ({window}) is not installed; the command line is: {}", verso_core::product::command("--help"));
    };
    let error = Command::new(&program).args(arguments).exec();
    anyhow::anyhow!("could not start {}: {error}", program.display())
}
