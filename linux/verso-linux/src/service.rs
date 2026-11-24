//! The user service that runs the daemon (ARCHITECTURE.md, "The daemon's lifecycle"): `verso.service`, which the
//! packages install, or the window and `mount` write where nothing did.

use std::path::Path;

use verso_core::product;

use crate::paths::Paths;

/// The unit the .rpm, the .deb and the tarball install, or the app writes: the product's.
pub fn packaged() -> String {
    product::current().service()
}

/// The units that may run the daemon: the packages' alone.
pub fn user_services() -> Vec<String> {
    vec![packaged()]
}

/// The installed unit, if any.
pub fn installed_user_service() -> Option<String> {
    user_services().into_iter().find(|unit| installed(unit))
}

/// The unit to enable, start and restart: the installed one, else the packages' name, so an error names the unit the
/// packages provide.
pub fn user_service() -> String {
    installed_user_service().unwrap_or_else(packaged)
}

/// The packages' unit, running `daemon`.
pub fn unit_text(daemon: &Path) -> String {
    include_str!("../../../linux/packaging/systemd/verso.service.in").replace("@BINDIR@/verso-service", &format!("\"{}\"", daemon.display()))
}

/// The installed unit, else the packages' unit written for the daemon found on this system: what the app and `mount`
/// start, so an install that brought no unit (Homebrew, a build from source) mounts all the same.
pub fn ensure_user_service(paths: &Paths) -> std::io::Result<String> {
    if let Some(unit) = installed_user_service() {
        return Ok(unit);
    }
    let program = product::current().program;
    let daemon = crate::programs::find(program)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, format!("{program} is not installed")))?;
    write_user_service(paths, &daemon)
}

/// Write the packages' unit into the user's own systemd folder, running `daemon`, and have systemd read it. Returns the
/// unit's name.
pub fn write_user_service(paths: &Paths, daemon: &Path) -> std::io::Result<String> {
    let config_home = paths.config_directory.parent().unwrap_or(&paths.home);
    let directory = config_home.join("systemd").join("user");
    std::fs::create_dir_all(&directory)?;
    let unit = packaged();
    std::fs::write(directory.join(&unit), unit_text(daemon))?;
    let _ = std::process::Command::new("systemctl").args(["--user", "daemon-reload"]).output();
    Ok(unit)
}

/// The user service this process runs in, from its control group (`.../app.slice/verso.service`), so the
/// daemon turns off the unit that started it and no other. `None` outside a service.
pub fn own_unit() -> Option<String> {
    unit_of_cgroup(&std::fs::read_to_string("/proc/self/cgroup").ok()?)
}

fn unit_of_cgroup(cgroup: &str) -> Option<String> {
    let last = cgroup.lines().last()?.rsplit('/').next()?;
    (last.ends_with(".service") && !last.starts_with("user@")).then(|| last.to_owned())
}

/// Whether the user service `unit` exists, installed by anyone: by its load state, which a drop-in removed without a
/// reload does not change (`systemctl cat` then fails, chasing the missing file).
pub fn is_installed(unit: &str) -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "show", "--property=LoadState", "--value", "--", unit])
        .output()
        .is_ok_and(|outcome| outcome.status.success() && String::from_utf8_lossy(&outcome.stdout).trim() == "loaded")
}

fn installed(unit: &str) -> bool {
    std::process::Command::new("systemctl").args(["--user", "cat", "--", unit]).output().is_ok_and(|outcome| outcome.status.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_unit_is_read_from_the_control_group() {
        let service = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/verso.service\n";
        assert_eq!(unit_of_cgroup(service).as_deref(), Some("verso.service"));
        let terminal = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-1.scope\n";
        assert_eq!(unit_of_cgroup(terminal), None);
        assert_eq!(unit_of_cgroup("0::/user.slice/user-1000.slice/user@1000.service\n"), None);
    }

    #[test]
    fn the_written_unit_runs_the_daemon_it_was_given() {
        let unit = unit_text(Path::new("/home/linuxbrew/.linuxbrew/bin/verso-service"));
        assert!(unit.contains("ExecStart=\"/home/linuxbrew/.linuxbrew/bin/verso-service\" daemon"), "{unit}");
        assert!(unit.contains("Description=Verso: "), "{unit}");
        assert!(unit.contains("Restart=on-failure"));
        assert!(unit.contains("RestartForceExitStatus=75"));
        assert!(!unit.contains('@'));
    }
}
