//! What the app does, without the widgets: probe a server, sign in, keep the credential, and start the daemon.
//!
//! Every network step is async and runs on the app's tokio runtime; the window awaits the result on the main loop.
//! Errors are messages for a toast, written for people.

use std::path::PathBuf;
use std::process::Command;

use immich_api::Client;
use verso_core::settings::{self, Config};
use verso_core::sign_in::{self, BrowserSignIn};
use verso_linux::credentials::{write_credential_file, Credential};
use verso_linux::i18n::tr;
use verso_linux::keyring::{self, KeyringError};
use verso_linux::mounts::{mount_state, MountState};
use verso_linux::paths::Paths;

pub use verso_core::sign_in::ServerOffer;

/// A finished sign-in.
pub struct SignedIn {
    pub credential: Credential,
    pub account: Option<String>,
}

/// What the status page shows.
pub struct Status {
    pub server: String,
    pub mount_point: PathBuf,
    pub mounted: bool,
    pub credential_place: String,
    /// What the running daemon reports over D-Bus: its connection state, and its cache's use and limit.
    pub daemon: Option<DaemonReport>,
}

pub struct DaemonReport {
    pub state: String,
    pub cache_used: u64,
    pub cache_limit: u64,
    /// The Immich version the daemon is connected to, empty when it did not say.
    pub server_version: String,
    /// Uploads in flight: name, phase (`writing` or `uploading`), bytes.
    pub uploads: Vec<(String, String, u64)>,
    /// The signed-in account's email, empty when the credential may not read it.
    pub account: String,
}

impl Status {
    /// The server line of a status page: its address, and Immich's version when the daemon knows it.
    pub fn server_text(&self) -> String {
        match self.daemon.as_ref().map(|report| report.server_version.as_str()).filter(|version| !version.is_empty()) {
            Some(version) => format!("{} (Immich {version})", self.server),
            None => self.server.clone(),
        }
    }

    /// The connection line of a status page, in the user's language.
    pub fn connection_text(&self) -> String {
        match self.daemon.as_ref().map(|report| report.state.as_str()) {
            Some("online") => tr("Online").to_owned(),
            Some("offline") => tr("Server unreachable; files you opened before stay available").to_owned(),
            Some("signed-out") => tr("Signed out; sign in again").to_owned(),
            Some(other) => other.to_owned(),
            None => tr("Not running").to_owned(),
        }
    }

    /// The cache line of a status page, its sizes written by the app's own `format_size`.
    pub fn cache_text(&self, format_size: impl Fn(u64) -> String) -> String {
        match &self.daemon {
            Some(report) => tr("{used} of {limit}")
                .replace("{used}", &format_size(report.cache_used))
                .replace("{limit}", &format_size(report.cache_limit)),
            None => tr("Not running").to_owned(),
        }
    }

    /// The account line of a status page, `None` when the daemon cannot name it.
    pub fn account_text(&self) -> Option<String> {
        self.daemon.as_ref().map(|report| report.account.clone()).filter(|account| !account.is_empty())
    }

    /// The uploads line of a status page, `None` while nothing is being uploaded.
    pub fn uploads_text(&self) -> Option<String> {
        match self.daemon.as_ref().map(|report| report.uploads.as_slice()).unwrap_or_default() {
            [] => None,
            [(name, phase, _)] => {
                let phase = if phase == "writing" { tr("writing") } else { tr("uploading") };
                Some(tr("{name}, {phase}").replace("{name}", name).replace("{phase}", phase))
            }
            [(name, _, _), rest @ ..] => {
                Some(tr("{name} and {count} more").replace("{name}", name).replace("{count}", &rest.len().to_string()))
            }
        }
    }
}

/// Ask the running daemon over D-Bus (SPEC.md, "The daemon's D-Bus interface"). `None` when it is not running.
async fn daemon_report() -> Option<DaemonReport> {
    let connection = zbus::Connection::session().await.ok()?;
    use verso_linux::dbus::{bus_name, INTERFACE, OBJECT_PATH};
    let proxy = zbus::Proxy::new(&connection, bus_name(), OBJECT_PATH, INTERFACE).await.ok()?;
    let state: String = proxy.get_property("State").await.ok()?;
    let (cache_used, cache_limit): (u64, u64) = proxy.get_property("CacheUsage").await.ok()?;
    let server_version: String = proxy.get_property("ServerVersion").await.unwrap_or_default();
    let uploads: Vec<(String, String, u64)> = proxy.get_property("Uploads").await.unwrap_or_default();
    let account: String = proxy.get_property("Account").await.unwrap_or_default();
    Some(DaemonReport { state, cache_used, cache_limit, server_version, uploads, account })
}

pub use verso_core::sign_in::normalised_address;

fn client(url: &str, credential: Option<&Credential>) -> Result<Client, String> {
    let credential = credential.map(|credential| match credential {
        Credential::ApiKey(key) => immich_api::Credential::ApiKey(key.clone()),
        Credential::Session(token) => immich_api::Credential::Session(token.clone()),
    });
    Client::new(url, credential, &verso_core::product::user_agent()).map_err(|error| tr("That address cannot be used: {error}").replace("{error}", &error.to_string()))
}

/// Check the server and what sign-in methods it offers. Needs no credential.
pub async fn probe(url: String) -> Result<ServerOffer, String> {
    sign_in::probe(&client(&url, None)?, &url).await
}

/// Start a browser sign-in: the identity provider's address to open.
pub async fn begin_browser_sign_in(url: String, state: String, code_challenge: String) -> Result<String, String> {
    sign_in::begin_browser(&client(&url, None)?, &state, &code_challenge).await
}

/// Finish a browser sign-in with the address the browser was sent to.
pub async fn finish_browser_sign_in(url: String, redirect: String, attempt: BrowserSignIn) -> Result<SignedIn, String> {
    let session = sign_in::finish_browser(&client(&url, None)?, &redirect, &attempt).await?;
    Ok(SignedIn { credential: Credential::Session(session.token), account: Some(session.account) })
}

pub async fn sign_in_with_password(url: String, email: String, password: String) -> Result<SignedIn, String> {
    let session = sign_in::password_session(&client(&url, None)?, &email, &password).await?;
    Ok(SignedIn { credential: Credential::Session(session.token), account: Some(session.account) })
}

pub async fn sign_in_with_api_key(url: String, key: String) -> Result<SignedIn, String> {
    let credential = Credential::ApiKey(key.trim().to_owned());
    sign_in::check_api_key(&client(&url, Some(&credential))?).await?;
    Ok(SignedIn { credential, account: None })
}

/// Keep the credential where the daemon will read it (a configured `credential.file`; else the keyring, or the
/// private file without one), remember the server, and enable the user service so the mount comes at the next login
/// even if setup is left unfinished. Starting it is [`apply_setup`]'s job. Returns where the credential went.
pub async fn save(url: String, credential: Credential) -> Result<String, String> {
    let place = store_credential(url, credential).await?;
    let _ = Command::new("systemctl").args(["--user", "enable", &verso_linux::service::user_service()]).output();
    Ok(place)
}

/// [`save`] without the user service: the credential and the server only, where the daemon will find them once the
/// drive is set up. Immich Gallery signs in this way, so signing in to browse never starts a mount.
pub async fn store_credential(url: String, credential: Credential) -> Result<String, String> {
    let paths = Paths::from_environment();
    let configured_file = config_text(&paths).ok().and_then(|text| Config::from_toml(&text).ok()).and_then(|config| config.credential_file);
    let place = match configured_file {
        Some(file) => {
            let file = paths.expand(&file);
            write_credential_file(&file, &credential).map_err(|error| error.to_string())?;
            tr("Kept in {file}").replace("{file}", &file.display().to_string())
        }
        None => match keyring::store(&url, &credential).await {
            Ok(()) => {
                let _ = std::fs::remove_file(paths.default_credential_file());
                tr("Kept in the keyring").to_owned()
            }
            Err(KeyringError::Unavailable(_)) => {
                let file = paths.default_credential_file();
                write_credential_file(&file, &credential).map_err(|error| error.to_string())?;
                tr("Kept in {file}").replace("{file}", &file.display().to_string())
            }
            Err(KeyringError::Dismissed) => return Err(tr("The keyring stayed locked, so nothing was saved.").to_owned()),
            Err(error) => return Err(error.to_string()),
        },
    };
    remember_server(&paths, &url)?;
    Ok(place)
}

/// The first-run choices: which sections show, and where the mount goes.
#[derive(Debug, Clone)]
pub struct Setup {
    pub photos: bool,
    pub albums: bool,
    pub people: bool,
    pub places: bool,
    pub favorites: bool,
    pub archive: bool,
    pub location: String,
}

/// The choices as the configuration has them now (the defaults on a first run).
pub fn current_setup() -> Setup {
    let paths = Paths::from_environment();
    let config = config_text(&paths).ok().and_then(|text| Config::from_toml(&text).ok()).unwrap_or_else(|| Config::from_toml("").expect("the defaults parse"));
    Setup {
        photos: config.show_photos,
        albums: config.show_albums,
        people: config.show_people,
        places: config.show_places,
        favorites: config.show_favorites,
        archive: config.show_archive,
        location: config.mount_path,
    }
}

/// Store the first-run choices, then start (or restart) the mount.
pub fn apply_setup(setup: &Setup) -> Result<(), String> {
    let paths = Paths::from_environment();
    let flag = |on: bool| if on { "true" } else { "false" };
    let mut text = config_text(&paths)?;
    for (key, value) in [
        ("sections.photos", flag(setup.photos)),
        ("sections.albums", flag(setup.albums)),
        ("sections.people", flag(setup.people)),
        ("sections.places", flag(setup.places)),
        ("sections.favorites", flag(setup.favorites)),
        ("sections.archive", flag(setup.archive)),
        ("mount.path", setup.location.trim()),
    ] {
        text = settings::set_value(&text, key, value).map_err(|error| error.to_string())?;
    }
    std::fs::create_dir_all(&paths.config_directory).map_err(|error| error.to_string())?;
    let temporary = paths.config_file().with_extension("toml.tmp");
    std::fs::write(&temporary, text).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, paths.config_file()).map_err(|error| error.to_string())?;
    start_daemon()
}

fn config_text(paths: &Paths) -> Result<String, String> {
    match std::fs::read_to_string(paths.config_file()) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(error.to_string()),
    }
}

fn remember_server(paths: &Paths, url: &str) -> Result<(), String> {
    let updated = settings::set_value(&config_text(paths)?, "server.url", url).map_err(|error| error.to_string())?;
    std::fs::create_dir_all(&paths.config_directory).map_err(|error| error.to_string())?;
    let temporary = paths.config_file().with_extension("toml.tmp");
    std::fs::write(&temporary, updated).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, paths.config_file()).map_err(|error| error.to_string())
}

/// Enable Verso's service and restart it, so the tray (and the drive, when it is on) comes now and at every login,
/// with the new credential and settings.
pub fn start_service() -> Result<(), String> {
    if verso_core::product::current().sandboxed {
        crate::sandbox::run_at_login(tr("Verso shows its icon in the top bar while you are signed in."));
        return crate::sandbox::restart().map_err(|error| tr("Signed in, but the background service did not start: {error}").replace("{error}", &error));
    }
    let unit = verso_linux::service::ensure_user_service(&Paths::from_environment())
        .map_err(|error| tr("Signed in, but the background service cannot start: {error}.").replace("{error}", &error.to_string()))?;
    restart(&unit, tr("Signed in, but the background service did not start: {error}"))
}

/// Start the service if it is installed and not running (Verso's tray, quit from its menu, comes back with the window),
/// and have it start at every login, with the drive while it is on.
pub fn wake_service() {
    if verso_core::product::current().sandboxed {
        let _ = crate::sandbox::start();
        return;
    }
    if let Some(unit) = verso_linux::service::installed_user_service() {
        let _ = Command::new("systemctl").args(["--user", "enable", "--now", &unit]).output();
    }
}

/// Whether the drive is on (`mount.enabled`): Verso's is off until switched on in its preferences.
pub fn drive_enabled() -> bool {
    // A Flatpak has no drive (`Product::sandboxed`).
    if verso_core::product::current().sandboxed {
        return false;
    }
    let paths = Paths::from_environment();
    config_text(&paths).ok().and_then(|text| Config::from_toml(&text).ok()).is_some_and(|config| config.mount_enabled)
}

/// Switch the drive on or off (`mount.enabled`), and restart the service, which then mounts it, or takes it away and
/// keeps the tray.
pub fn set_drive(enabled: bool) -> Result<(), String> {
    if verso_core::product::current().sandboxed {
        return Err(tr("Verso Drive is not part of this version of Verso.").to_owned());
    }
    let paths = Paths::from_environment();
    let text = settings::set_value(&config_text(&paths)?, "mount.enabled", if enabled { "true" } else { "false" }).map_err(|error| error.to_string())?;
    write_config(&paths, &text)?;
    let unit = verso_linux::service::ensure_user_service(&paths).map_err(|error| error.to_string())?;
    restart(&unit, tr("The background service did not restart: {error}"))
}

/// Immich Mount's account on this computer, which Verso offers to take over: its server, when it has a sign-in.
pub async fn immich_mount_account() -> Option<String> {
    // A sandbox cannot read Immich Mount's settings or keyring items.
    if verso_core::product::current().sandboxed {
        return None;
    }
    let product = &verso_core::product::IMMICH_MOUNT;
    let paths = Paths::from_environment_of(product);
    let config = Config::from_toml_for(&config_text(&paths).ok()?, product).ok()?;
    let server = config.server_url.clone().filter(|url| !url.trim().is_empty())?;
    let signed_in = match immich_mount_file(&paths, &config) {
        Some(file) => file.exists(),
        None => keyring::is_stored_by(product, &server).await,
    };
    signed_in.then_some(server)
}

/// Immich Mount's credential file, where it keeps one: a configured `credential.file`, else its own without a keyring.
fn immich_mount_file(paths: &Paths, config: &Config) -> Option<PathBuf> {
    match &config.credential_file {
        Some(file) => Some(paths.expand(file)),
        None => Some(paths.default_credential_file()).filter(|file| file.exists()),
    }
}

/// Take Immich Mount's account over: its server, a sign-in of Verso's own (a new session made with Immich Mount's, so
/// signing out of either leaves the other; an API key is shared as it is), and its drive's settings
/// (`taken_over_settings`). Immich Mount is left as it is. Returns where the credential went.
pub async fn take_over_immich_mount(url: String) -> Result<String, String> {
    let product = &verso_core::product::IMMICH_MOUNT;
    let theirs = Paths::from_environment_of(product);
    let text = config_text(&theirs)?;
    let config = Config::from_toml_for(&text, product).map_err(|error| error.to_string())?;
    let credential = match immich_mount_file(&theirs, &config) {
        Some(file) => verso_linux::credentials::read_credential_file(&file).map_err(|error| error.to_string())?,
        None => keyring::load_of(product, &url)
            .await
            .map_err(|error| error.to_string())?
            .ok_or_else(|| tr("Immich Mount is no longer signed in.").to_owned())?,
    };
    let own = match credential {
        Credential::Session(_) => {
            let made = client(&url, Some(&credential))?.create_session("Verso", "Linux", None).await.map_err(|error| match error {
                immich_api::ApiError::Unauthorized => tr("Immich no longer accepts Immich Mount's sign-in; sign in instead.").to_owned(),
                error => error.to_string(),
            })?;
            Credential::Session(made.token.expose().to_owned())
        }
        key @ Credential::ApiKey(_) => key,
    };
    let place = store_credential(url, own).await?;
    let paths = Paths::from_environment();
    write_config(&paths, &taken_over_settings(&text, &config_text(&paths)?)?)?;
    Ok(place)
}

/// Verso's settings (`ours`) with Immich Mount's (`theirs`) taken over: its drive's settings, but its place, name and
/// switch, its sign-in, its start at login and its update check, which stay Verso's own, so the two drives never
/// mount over each other. Verso Drive is switched on: whoever used Immich Mount's drive keeps one.
fn taken_over_settings(theirs: &str, ours: &str) -> Result<String, String> {
    let mut ours = ours.to_owned();
    for (key, value) in settings::stored_values(theirs).map_err(|error| error.to_string())? {
        if !matches!(key, "server.url" | "mount.enabled" | "mount.path" | "mount.name" | "credential.file" | "mount.at_login" | "updates.check") {
            ours = settings::set_value(&ours, key, &value).map_err(|error| error.to_string())?;
        }
    }
    settings::set_value(&ours, "mount.enabled", "true").map_err(|error| error.to_string())
}

fn write_config(paths: &Paths, text: &str) -> Result<(), String> {
    std::fs::create_dir_all(&paths.config_directory).map_err(|error| error.to_string())?;
    let temporary = paths.config_file().with_extension("toml.tmp");
    std::fs::write(&temporary, text).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, paths.config_file()).map_err(|error| error.to_string())
}

/// Enable `unit` and restart it; `failed` is the message, with `{error}` for systemctl's.
fn restart(unit: &str, failed: &str) -> Result<(), String> {
    for arguments in [["--user", "enable", unit], ["--user", "restart", unit]] {
        let outcome = Command::new("systemctl").args(arguments).output().map_err(|error| format!("systemctl: {error}"))?;
        if !outcome.status.success() {
            return Err(failed.replace("{error}", String::from_utf8_lossy(&outcome.stderr).trim()));
        }
    }
    Ok(())
}

/// Enable the user service and restart it, so it picks up the new credential. Where no service is installed (the app
/// from Homebrew's cask, the daemon from its formula), the app writes the packages' one for the daemon it finds, so
/// nobody has to start a service by hand.
fn start_daemon() -> Result<(), String> {
    let unit = verso_linux::service::ensure_user_service(&Paths::from_environment())
        .map_err(|error| tr("Signed in, but the mount cannot start: {error}.").replace("{error}", &error.to_string()))?;
    for arguments in [["--user", "enable", unit.as_str()], ["--user", "restart", unit.as_str()]] {
        let outcome = Command::new("systemctl").args(arguments).output().map_err(|error| format!("systemctl: {error}"))?;
        if !outcome.status.success() {
            return Err(tr("Signed in, but the mount did not start: {error}")
                .replace("{error}", String::from_utf8_lossy(&outcome.stderr).trim()));
        }
    }
    Ok(())
}

/// Where a browser sign-in waits for its redirect, for apps that cannot route the redirect to the running instance
/// (Qt has no single-instance service): the runtime directory, readable by the user only, and removed once used.
/// Inside a Flatpak each instance has a runtime directory of its own, and only the app's folder in it is shared.
fn pending_attempt_path() -> Option<PathBuf> {
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
    let directory = match std::env::var_os("FLATPAK_ID") {
        Some(app) => runtime.join("app").join(app),
        None => runtime,
    };
    Some(directory.join(format!("{}-sign-in", verso_core::product::current().folder)))
}

fn write_attempt_file(text: &str) -> Result<(), String> {
    write_attempt_file_at(&pending_attempt_path().ok_or("no runtime directory to keep the sign-in in")?, text)
}

fn write_attempt_file_at(path: &std::path::Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(path).map_err(|error| error.to_string())?;
    file.write_all(text.as_bytes()).map_err(|error| error.to_string())
}

/// Keep a browser sign-in's secrets until its redirect arrives, possibly in another process of the app.
pub fn remember_attempt(url: &str, attempt: &BrowserSignIn) -> Result<(), String> {
    write_attempt_file(&format!("{url}\n{}\n{}\n{}\n", attempt.state, attempt.code_verifier, attempt.code_challenge))
}

/// Drop a waiting browser sign-in (the user went back, or signed in another way), so a late redirect finds nothing.
pub fn forget_attempt() {
    if let Some(path) = pending_attempt_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// What a redirect means for the waiting browser sign-in.
pub enum Redirect {
    /// It carries the code: finish with these, then `report_attempt`.
    SignIn { url: String, attempt: BrowserSignIn },
    /// The identity provider refused (the user cancelled, for instance): `report_attempt` with this message.
    Refused(String),
}

/// The waiting browser sign-in a redirect belongs to. Used once: it is claimed by renaming its file away, so a
/// redirect delivered twice is finished by one process only, and `report_attempt` later writes the outcome in its
/// place. `None` when nothing waits, the redirect is for another attempt, or another process claimed it first.
pub fn take_attempt_for(redirect: &str) -> Option<Redirect> {
    take_attempt_at(&pending_attempt_path()?, redirect)
}

fn take_attempt_at(path: &std::path::Path, redirect: &str) -> Option<Redirect> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut lines = text.lines();
    let (url, state, code_verifier, code_challenge) = (lines.next()?, lines.next()?, lines.next()?, lines.next()?);
    let claimed = if sign_in::is_redirect_for(redirect, state) {
        Redirect::SignIn {
            url: url.to_owned(),
            attempt: BrowserSignIn { state: state.to_owned(), code_verifier: code_verifier.to_owned(), code_challenge: code_challenge.to_owned() },
        }
    } else {
        Redirect::Refused(sign_in::provider_error(redirect, state)?)
    };
    let mine = path.with_extension(format!("claimed-{}", std::process::id()));
    std::fs::rename(path, &mine).ok()?;
    let _ = std::fs::remove_file(&mine);
    Some(claimed)
}

/// Tell the waiting app how the browser sign-in ended, where the claimed attempt was.
pub fn report_attempt(outcome: &Result<(), String>) {
    let text = match outcome {
        Ok(()) => "done\n".to_owned(),
        Err(message) => format!("failed\n{message}\n"),
    };
    let _ = write_attempt_file(&text);
}

/// How a browser sign-in finished in another process of the app, once: `None` while it still waits. A credential
/// already in the keyring says nothing here, because signing in again starts with the old one still stored.
pub fn attempt_outcome() -> Option<Result<(), String>> {
    attempt_outcome_at(&pending_attempt_path()?)
}

fn attempt_outcome_at(path: &std::path::Path) -> Option<Result<(), String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let outcome = match text.split_once('\n')? {
        ("done", _) => Ok(()),
        ("failed", message) => Err(message.trim().to_owned()),
        _ => return None,
    };
    let _ = std::fs::remove_file(path);
    Some(outcome)
}

/// The configured server, to offer it again after signing out.
pub fn configured_server() -> Option<String> {
    let paths = Paths::from_environment();
    Config::from_toml(&config_text(&paths).ok()?).ok()?.server_url.filter(|url| !url.trim().is_empty())
}

/// The status of the mount, or `None` when not signed in. Reads no secret, so it never brings up a prompt.
pub async fn current_status() -> Option<Status> {
    let paths = Paths::from_environment();
    let config = Config::from_toml(&config_text(&paths).ok()?).ok()?;
    let server = config.server_url.clone().filter(|url| !url.trim().is_empty())?;
    let mount_point = paths.expand(&config.mount_path);
    let credential_place = match &config.credential_file {
        // A credential file that is gone (signing out removes it) is no sign-in, though the setting stays.
        Some(file) if paths.expand(file).exists() => tr("Kept in {file}").replace("{file}", &paths.expand(file).display().to_string()),
        Some(_) => return None,
        None if paths.default_credential_file().exists() => {
            tr("Kept in {file}").replace("{file}", &paths.default_credential_file().display().to_string())
        }
        None if keyring::is_stored(&server).await => tr("Kept in the keyring").to_owned(),
        None => return None,
    };
    Some(Status {
        server,
        mounted: mount_state(&mount_point) == MountState::Mounted,
        mount_point,
        credential_place,
        daemon: daemon_report().await,
    })
}

/// Mount, or unmount as an eject does, with the command line's `mount` and `unmount`, so the app takes the steps a
/// terminal would: mounting starts the user service, written first where no install brought one; unmounting lets the
/// daemon leave cleanly, and its service is not restarted until the next login.
pub fn set_mounted(mounted: bool) -> Result<(), String> {
    let program = daemon_program();
    let verb = if mounted { "mount" } else { "unmount" };
    let outcome = Command::new(&program).arg(verb).output().map_err(|error| format!("{}: {error}", program.display()))?;
    if !outcome.status.success() {
        let message = String::from_utf8_lossy(&outcome.stderr);
        return Err(message.trim().trim_start_matches("error:").trim().to_owned());
    }
    Ok(())
}

/// Verso's service and command line (`verso-service`), installed with the window.
fn daemon_program() -> PathBuf {
    let name = verso_core::product::current().program;
    verso_linux::programs::find(name).unwrap_or_else(|| PathBuf::from(name))
}

/// Sign out through the command line's `logout`, which unmounts and removes the credential, the caches and the
/// seeded thumbnails. The two programs ship together, so the command is found where this one is installed.
pub fn disconnect() -> Result<(), String> {
    let program = daemon_program();
    let outcome = Command::new(&program).arg("logout").output().map_err(|error| format!("{}: {error}", program.display()))?;
    // `logout` also turns the user service off, once signed out; a failed logout keeps the mount at the next login.
    if !outcome.status.success() {
        return Err(String::from_utf8_lossy(&outcome.stderr).trim().to_owned());
    }
    // A Flatpak's service has no systemd to turn it off: it is asked to stop.
    if verso_core::product::current().sandboxed {
        crate::sandbox::stop();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attempt_text(attempt: &BrowserSignIn) -> String {
        format!("https://photos.example.org\n{}\n{}\n{}\n", attempt.state, attempt.code_verifier, attempt.code_challenge)
    }

    #[test]
    fn a_redirect_claims_its_attempt_once_and_the_outcome_is_read_once() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("verso-sign-in");
        let attempt = BrowserSignIn::new().unwrap();
        write_attempt_file_at(&path, &attempt_text(&attempt)).unwrap();
        let redirect = format!("app.immich:///oauth-callback?code=abc&state={}", attempt.state);

        assert!(take_attempt_at(&path, "app.immich:///oauth-callback?code=abc&state=other").is_none(), "another attempt's");
        match take_attempt_at(&path, &redirect) {
            Some(Redirect::SignIn { url, attempt: claimed }) => {
                assert_eq!(url, "https://photos.example.org");
                assert_eq!(claimed.code_verifier, attempt.code_verifier);
            }
            _ => panic!("the redirect should claim its attempt"),
        }
        assert!(take_attempt_at(&path, &redirect).is_none(), "a redirect delivered twice is finished once");
        assert_eq!(attempt_outcome_at(&path), None, "nothing to report while the sign-in runs");

        write_attempt_file_at(&path, "done\n").unwrap();
        assert_eq!(attempt_outcome_at(&path), Some(Ok(())));
        assert_eq!(attempt_outcome_at(&path), None, "an outcome is read once");
    }

    #[test]
    fn a_provider_refusal_ends_the_attempt_with_its_message() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("verso-sign-in");
        let attempt = BrowserSignIn::new().unwrap();
        write_attempt_file_at(&path, &attempt_text(&attempt)).unwrap();
        let refusal = format!("app.immich:///oauth-callback?error=access_denied&state={}", attempt.state);
        match take_attempt_at(&path, &refusal) {
            Some(Redirect::Refused(message)) => assert!(message.contains("access_denied"), "{message}"),
            _ => panic!("a refusal for this attempt should end it"),
        }
        write_attempt_file_at(&path, "failed\nthe sign-in was refused (access_denied)\n").unwrap();
        assert_eq!(attempt_outcome_at(&path), Some(Err("the sign-in was refused (access_denied)".to_owned())));
    }

    #[test]
    fn a_takeover_keeps_the_drive_settings_and_switches_verso_drive_on() {
        let theirs = "[server]\nurl = \"https://photos.example.org\"\n[mount]\nenabled = false\npath = \"~/Immich\"\nname = \"Photos\"\n[cache]\nlimit = \"5GB\"\n[sections]\npeople = false\n";
        let ours = "[mount]\nenabled = false\n";
        let taken = settings::stored_values(&taken_over_settings(theirs, ours).unwrap()).unwrap();
        assert_eq!(taken.get("mount.enabled").map(String::as_str), Some("true"), "Verso Drive is on whatever either said");
        assert_eq!(taken.get("cache.limit").map(String::as_str), Some("5GB"));
        assert_eq!(taken.get("sections.people").map(String::as_str), Some("false"));
        for own in ["server.url", "mount.path", "mount.name"] {
            assert!(!taken.contains_key(own), "{own} stays Verso's own");
        }
    }
}
