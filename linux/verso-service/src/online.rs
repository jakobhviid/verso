//! The commands that talk to the server: signing in, status, and the daemon itself.

use std::io::{BufRead, IsTerminal, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use immich_api::{CertificatePin, CertificateRefusal, Client, TimelineScope};
use verso_core::immich::ImmichSource;
use verso_core::settings::{self, Config};
use verso_core::sign_in::{self, BrowserSignIn};
use verso_linux::credentials::{read_credential_file, write_credential_file, Credential};
use verso_linux::keyring::{self, KeyringError};
use verso_linux::daemon::{self, StopReason};
use verso_linux::i18n::tr;
use verso_linux::mounts::{mount_state, MountState};
use verso_linux::paths::Paths;
use serde::Serialize;

use crate::commands::{configure_set, configure_unset, load_config};

/// How `login` signs in.
#[derive(Debug, Clone, Copy)]
pub enum LoginMethod {
    /// The server's OIDC sign-in, in the user's own browser.
    Browser,
    ApiKey,
    Password,
}

/// Where a credential is kept (SPEC.md, "Signing in and credentials").
enum CredentialStore {
    Keyring,
    File(PathBuf),
}

fn configured_file(paths: &Paths, config: &Config) -> Option<PathBuf> {
    config.credential_file.as_deref().map(|file| paths.expand(file))
}

/// Whether this runs inside a desktop session, where a keyring can show its unlock prompt.
fn in_graphical_session() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some() || std::env::var_os("DISPLAY").is_some()
}

/// Where a new credential goes: a configured file always; else the keyring in a desktop session; else the 0600 file.
fn store_for_new_credential(paths: &Paths, config: &Config) -> CredentialStore {
    match configured_file(paths, config) {
        Some(file) => CredentialStore::File(file),
        None if in_graphical_session() => CredentialStore::Keyring,
        None => CredentialStore::File(paths.default_credential_file()),
    }
}

/// The stored credential: from a configured file; else from the default file if a headless sign-in left one; else
/// from the keyring, which may bring up its unlock prompt.
fn load_credential(paths: &Paths, config: &Config, server_url: &str, runtime: &tokio::runtime::Runtime) -> Result<Credential> {
    if let Some(file) = configured_file(paths, config) {
        return Ok(read_credential_file(&file)?);
    }
    let default_file = paths.default_credential_file();
    if default_file.exists() {
        return Ok(read_credential_file(&default_file)?);
    }
    match runtime.block_on(keyring::load(server_url)) {
        Ok(Some(credential)) => Ok(credential),
        Ok(None) => bail!("not signed in to {server_url}; sign in with `{}`", verso_core::product::command("login")),
        Err(KeyringError::Unavailable(reason)) => {
            bail!("not signed in: no credential file, and no keyring ({reason}); sign in with `{}`", verso_core::product::command("login"))
        }
        Err(error) => Err(error).context("reading the credential from the keyring"),
    }
}

fn configured_server(config: &Config) -> Result<String> {
    config
        .server_url
        .clone()
        .filter(|url| !url.trim().is_empty())
        .with_context(|| format!("no server is configured; sign in with `{}`", verso_core::product::command("login --server URL")))
}

/// A client for `server_url`, also trusting the certificate `trusted` names for it (`server.certificate_sha256`).
fn client(server_url: &str, credential: Option<&Credential>, trusted: Option<CertificatePin>) -> Result<Client> {
    let credential = credential.map(|credential| match credential {
        Credential::ApiKey(key) => immich_api::Credential::ApiKey(key.clone()),
        Credential::Session(token) => immich_api::Credential::Session(token.clone()),
    });
    Client::trusting(server_url, credential, &verso_core::product::user_agent(), trusted).with_context(|| format!("using the server URL {server_url}"))
}

/// How a refused certificate is told on the command line: what the person compares, and how to trust it.
fn certificate_lines(server_url: &str, refusal: &CertificateRefusal) -> String {
    let certificate = &refusal.certificate;
    let opening = if refusal.changed() {
        format!("{server_url} presents another certificate than the one trusted for it ({}).", refusal.trusted.map(|pin| pin.to_string()).unwrap_or_default())
    } else {
        format!("The certificate {server_url} presents is not one this computer trusts ({}).", refusal.why())
    };
    let or_unstated = |text: &str| if text.trim().is_empty() { "not stated".to_owned() } else { text.to_owned() };
    let day = |moment: Option<chrono::DateTime<chrono::Utc>>| moment.map_or_else(|| "?".to_owned(), |moment| moment.format("%Y-%m-%d").to_string());
    let expired = certificate.valid_until.is_some_and(|until| until < chrono::Utc::now());
    format!(
        "{opening}\n  Fingerprint (SHA-256): {}\n  Issued to: {}\n  Issued by: {}\n  Valid: {} to {}{}\nAnyone between this computer and the server could be pretending to be it. Trust it only if this fingerprint is your server's: on the server, `openssl x509 -noout -fingerprint -sha256 -in <its certificate file>` shows it.",
        certificate.sha256,
        or_unstated(&certificate.subject),
        if certificate.self_signed { "itself (self-signed)".to_owned() } else { or_unstated(&certificate.issuer) },
        day(certificate.valid_from),
        day(certificate.valid_until),
        if expired { " (expired)" } else { "" },
    )
}

/// The certificate to trust for `server_url`, whose own the system refused (`refused`, presented without a pin): the
/// one given with `--trust-certificate`, which must be the one presented; the one kept for the server, when it is that
/// one; else the person's answer on a terminal. Without a terminal, how to trust it.
fn certificate_to_trust(server_url: &str, refused: &CertificateRefusal, given: Option<CertificatePin>, kept: Option<CertificatePin>) -> Result<CertificatePin> {
    let presented = refused.certificate.sha256;
    if let Some(given) = given {
        if given != presented {
            bail!("{server_url} presents the certificate {presented}, not {given}; nothing was trusted");
        }
        return Ok(given);
    }
    if kept == Some(presented) {
        return Ok(presented);
    }
    let refusal = CertificateRefusal { trusted: kept, ..refused.clone() };
    if !std::io::stdin().is_terminal() {
        bail!(
            "{}\nIf it is, sign in with `{}`",
            certificate_lines(server_url, &refusal),
            verso_core::product::command(&format!("login --trust-certificate {presented}"))
        );
    }
    eprintln!("{}", certificate_lines(server_url, &refusal));
    let answer = read_line("Trust this certificate? [y/N] ")?;
    if !matches!(answer.to_ascii_lowercase().as_str(), "y" | "yes") {
        bail!("the certificate was not trusted, so nothing was sent to {server_url}");
    }
    Ok(presented)
}

fn runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread().enable_all().build().context("starting the async runtime")
}

/// The name of an account's cache directory: the server's host and port, so it reads well in a file listing.
/// Signing out removes every cache. Signing in as another account without signing out shares the directory: Asset ids
/// are global, so cached bytes stay right, but kept listings show the earlier account's folders until refreshed (SPEC.md,
/// "Files on disk").
fn account_name(client: &Client) -> String {
    let url = client.api_url();
    let host = url.host_str().unwrap_or("server");
    let name = match url.port_or_known_default() {
        Some(port) => format!("{host}-{port}"),
        None => host.to_owned(),
    };
    name.chars().map(|character| if character.is_ascii_alphanumeric() || ".-".contains(character) { character } else { '_' }).collect()
}

/// A line from stdin, prompting only on a terminal.
fn read_line(prompt: &str) -> Result<String> {
    if std::io::stdin().is_terminal() {
        eprint!("{prompt}");
        std::io::stderr().flush().ok();
    }
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line).context("reading stdin")?;
    Ok(line.trim().to_owned())
}

/// A secret from stdin: without echo on a terminal, else the first line.
fn read_secret(prompt: &str) -> Result<String> {
    let secret = if std::io::stdin().is_terminal() {
        rpassword::prompt_password(prompt).context("reading from the terminal")?
    } else {
        read_line(prompt)?
    };
    let secret = secret.trim().to_owned();
    if secret.is_empty() {
        bail!("nothing was entered");
    }
    Ok(secret)
}

#[derive(Serialize)]
pub struct LoginReport {
    pub server: String,
    pub server_version: String,
    pub method: &'static str,
    pub user: Option<String>,
    /// `the keyring`, or the credential file's path.
    pub stored_in: String,
    /// The certificate trusted for the server where this computer does not trust it, as its SHA-256 fingerprint.
    pub certificate: Option<String>,
}

/// Sign in, check the credential against the server, and store it with the server's URL, and with the certificate
/// trusted for it where the system does not trust the server's own (`trust_certificate`, else the person's answer).
pub fn login(paths: &Paths, method: LoginMethod, server: Option<String>, trust_certificate: Option<CertificatePin>) -> Result<LoginReport> {
    let config = load_config(paths)?;
    let server_url = match server {
        Some(server) => server,
        None => configured_server(&config)?,
    };
    let same = |address: &str| address.trim().trim_end_matches('/').to_owned();
    let kept = config.server_certificate.filter(|_| config.server_url.as_deref().is_some_and(|configured| same(configured) == same(&server_url)));
    let runtime = runtime()?;
    // Asked first as the system judges it, so a certificate given or kept is trusted only where the system refuses the
    // one presented, and only when it is that one.
    let unpinned = client(&server_url, None, None)?;
    let (anonymous, version, trusted) = match runtime.block_on(unpinned.server_version()) {
        Ok(version) => {
            if trust_certificate.is_some() {
                crate::ui::warn(&format!("this computer trusts {server_url}'s certificate, so --trust-certificate is not needed; no certificate is kept"));
            }
            (unpinned, version, None)
        }
        Err(error) => {
            let Some(refused) = error.certificate_refusal() else { return Err(error).with_context(|| format!("reaching {server_url}")) };
            let trusted = certificate_to_trust(&server_url, refused, trust_certificate, kept)?;
            let anonymous = client(&server_url, None, Some(trusted))?;
            let version = runtime.block_on(anonymous.server_version()).with_context(|| format!("reaching {server_url}"))?;
            (anonymous, version, Some(trusted))
        }
    };
    if !version.is_supported() {
        bail!("{server_url} runs Immich {version}; {} needs {} or later", verso_core::product::current().name, immich_api::version::MINIMUM_SUPPORTED);
    }

    let (credential, user) = match method {
        LoginMethod::ApiKey => {
            let credential = Credential::ApiKey(read_secret("API key: ")?);
            runtime
                .block_on(client(&server_url, Some(&credential), trusted)?.api_key_permissions())
                .context("the server did not accept the API key")?;
            (credential, None)
        }
        LoginMethod::Browser => {
            let features = runtime.block_on(anonymous.server_features()).context("asking the server how it signs in")?;
            if !features.oauth {
                bail!("{server_url} has no OIDC sign-in; use --password or --api-key");
            }
            let attempt = BrowserSignIn::new().context("making the sign-in secrets")?;
            let address = runtime
                .block_on(anonymous.oauth_authorize(sign_in::REDIRECT_URI, &attempt.state, &attempt.code_challenge))
                .context("starting the browser sign-in")?;
            eprintln!("Open this address in your browser and sign in:\n\n  {address}\n");
            eprintln!("The browser then ends on an address starting with app.immich:// (it may show an error page).");
            let redirect = read_line("Copy that whole address and paste it here: ")?;
            if !sign_in::is_redirect_for(&redirect, &attempt.state) {
                bail!("that is not the address this sign-in ends on; run `{}` again", verso_core::product::command("login"));
            }
            let answer = runtime
                .block_on(anonymous.oauth_callback(&redirect, &attempt.state, &attempt.code_verifier))
                .context("finishing the browser sign-in")?;
            (Credential::Session(answer.access_token), Some(answer.user_email))
        }
        LoginMethod::Password => {
            if server_url.trim_start().to_ascii_lowercase().starts_with("http://") {
                crate::ui::warn(&format!("{server_url} is plain http: the password crosses the network unencrypted"));
            }
            let email = read_line("Email: ")?;
            let password = read_secret("Password: ")?;
            let answer = runtime.block_on(anonymous.login_password(&email, &password)).context("signing in")?;
            (Credential::Session(answer.access_token), Some(answer.user_email))
        }
    };

    let stored_in = match store_for_new_credential(paths, &config) {
        CredentialStore::File(file) => {
            write_credential_file(&file, &credential)?;
            file.display().to_string()
        }
        CredentialStore::Keyring => match runtime.block_on(keyring::store(&server_url, &credential)) {
            Ok(()) => {
                // A credential file from an earlier headless sign-in would be read first; this one replaces it.
                let _ = std::fs::remove_file(paths.default_credential_file());
                "the keyring".to_owned()
            }
            Err(KeyringError::Unavailable(reason)) => {
                crate::ui::warn(&format!("no keyring ({reason}); keeping the credential in a file readable only by you"));
                let file = paths.default_credential_file();
                write_credential_file(&file, &credential)?;
                file.display().to_string()
            }
            Err(error) => return Err(error).context("storing the credential in the keyring"),
        },
    };
    configure_set(paths, "server.url", &server_url)?;
    // The certificate belongs to this server: one trusted for another, or one the system no longer needs, goes.
    match trusted {
        Some(certificate) => configure_set(paths, settings::CERTIFICATE_KEY, &certificate.to_string())?,
        None => configure_unset(paths, settings::CERTIFICATE_KEY)?,
    };
    Ok(LoginReport { server: server_url, server_version: version.to_string(), method: credential.kind(), user, stored_in, certificate: trusted.map(|certificate| certificate.to_string()) })
}

/// The shape WORKFLOWS.md documents for `verso-service status --json`.
#[derive(Serialize)]
pub struct StatusReport {
    /// `unconfigured`, `online`, `offline`, `untrusted-certificate`, `signed-out`, `missing-permission` or `unmounted`.
    pub state: &'static str,
    /// Why, when the state is not `online`.
    pub detail: Option<String>,
    pub server: Option<ServerStatus>,
    pub account: AccountStatus,
    /// How the daemon learns about changes: `sync-stream` with a session, `polling` with an API key.
    pub change_feed: &'static str,
    pub mount: MountStatus,
    pub cache: CacheStatus,
    /// Originals fetched from the server since the mount started, from the running daemon.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched: Option<FetchedStatus>,
}

#[derive(Serialize)]
pub struct FetchedStatus {
    pub bytes: u64,
    pub requests: u64,
}

#[derive(Serialize)]
pub struct ServerStatus {
    pub url: String,
    pub version: Option<String>,
    /// The certificate trusted for the server where this computer does not trust it (`server.certificate_sha256`).
    pub certificate: Option<String>,
}

#[derive(Serialize)]
pub struct AccountStatus {
    pub email: Option<String>,
    /// `session` or `api-key`, when signed in.
    pub credential: Option<&'static str>,
}

#[derive(Serialize)]
pub struct MountStatus {
    pub path: PathBuf,
    pub mounted: bool,
    /// The mount's process is gone and the mount must be detached (`verso-service unmount`).
    pub stale: bool,
}

#[derive(Serialize)]
pub struct CacheStatus {
    pub used_bytes: u64,
    pub limit_bytes: u64,
}

/// How long the daemon's start and `status` wait for the server's version (ARCHITECTURE.md, "The daemon's lifecycle").
const VERSION_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The server's version, or an error once `VERSION_WAIT` has passed without one.
async fn server_version_soon(client: &Client) -> Result<immich_api::version::ServerVersion, immich_api::ApiError> {
    match tokio::time::timeout(VERSION_WAIT, client.server_version()).await {
        Ok(outcome) => outcome,
        Err(_) => Err(immich_api::ApiError::Offline(format!("no answer within {} s", VERSION_WAIT.as_secs()))),
    }
}

/// What the daemon would see: the server, the credential, the mount and the cache.
pub fn status(paths: &Paths) -> Result<StatusReport> {
    let config = load_config(paths)?;
    let path = paths.expand(&config.mount_path);
    let state_of_mount = mount_state(&path);
    let mut report = StatusReport {
        state: "unconfigured",
        detail: None,
        server: config
            .server_url
            .clone()
            .filter(|url| !url.trim().is_empty())
            .map(|url| ServerStatus { url, version: None, certificate: config.server_certificate.map(|certificate| certificate.to_string()) }),
        account: AccountStatus { email: None, credential: None },
        change_feed: "polling",
        // Set below once the credential is read: a session also follows the sync stream.
        mount: MountStatus { path, mounted: state_of_mount == MountState::Mounted, stale: state_of_mount == MountState::Stale },
        cache: CacheStatus { used_bytes: disk_usage(&paths.cache_directory), limit_bytes: config.cache_limit_bytes },
        fetched: runtime()
            .ok()
            .and_then(|runtime| runtime.block_on(verso_linux::dbus::fetched()))
            .map(|(bytes, requests)| FetchedStatus { bytes, requests }),
    };
    let Some(server_url) = report.server.as_ref().map(|server| server.url.clone()) else {
        return Ok(report);
    };
    let runtime = runtime()?;
    let credential = match load_credential(paths, &config, &server_url, &runtime) {
        Ok(credential) => credential,
        Err(error) => {
            report.state = "signed-out";
            report.detail = Some(format!("{error:#}"));
            return Ok(report);
        }
    };
    report.account.credential = Some(credential.kind());
    if matches!(credential, Credential::Session(_)) {
        report.change_feed = "sync-stream";
    }
    let client = client(&server_url, Some(&credential), config.server_certificate)?;
    match runtime.block_on(server_version_soon(&client)) {
        Ok(version) => {
            if let Some(server) = report.server.as_mut() {
                server.version = Some(version.to_string());
            }
            report.account.email = runtime.block_on(client.my_email()).ok();
        }
        Err(error) => {
            report.state = "offline";
            report.detail = Some(error.to_string());
            if let Some(refusal) = error.certificate_refusal() {
                report.state = "untrusted-certificate";
                report.detail = Some(format!(
                    "{error}: it presents {}; if that is your server's, sign in again in the app, or with `{}`",
                    refusal.certificate.sha256,
                    verso_core::product::command(&format!("login --trust-certificate {}", refusal.certificate.sha256))
                ));
            }
            return Ok(report);
        }
    }
    // The timeline is what the mount reads first, so it is the honest probe of the credential.
    report.state = match runtime.block_on(client.time_buckets(&TimelineScope::Library)) {
        Ok(_) if report.mount.mounted => "online",
        Ok(_) => "unmounted",
        Err(immich_api::ApiError::Unauthorized) => "signed-out",
        Err(immich_api::ApiError::Forbidden { missing_permission }) => {
            report.detail = missing_permission.map(|permission| format!("the credential lacks `{permission}`"));
            "missing-permission"
        }
        Err(error) => {
            report.detail = Some(error.to_string());
            "offline"
        }
    };
    Ok(report)
}

/// End the session on the server, so the device leaves Immich's "Authorized devices". Best effort: signing out
/// locally never depends on reaching the server. Returns whether a session was ended.
pub fn revoke_session(paths: &Paths) -> bool {
    let Ok(config) = load_config(paths) else { return false };
    let Ok(server_url) = configured_server(&config) else { return false };
    let Ok(runtime) = runtime() else { return false };
    let Ok(credential @ Credential::Session(_)) = load_credential(paths, &config, &server_url, &runtime) else { return false };
    let Ok(client) = client(&server_url, Some(&credential), config.server_certificate) else { return false };
    // The timeout must be created inside the runtime, which owns the timer.
    let ended = runtime.block_on(async { tokio::time::timeout(std::time::Duration::from_secs(5), client.logout()).await });
    matches!(ended, Ok(Ok(())))
}

/// Bytes actually used under `directory`. Content cache files are sparse, so this counts blocks, not lengths.
fn disk_usage(directory: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(metadata) if metadata.is_dir() => disk_usage(&entry.path()),
            Ok(metadata) => metadata.blocks() * 512,
            Err(_) => 0,
        })
        .sum()
}

/// What the drive's absence means to the daemon that goes on without it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Without {
    /// The drive is off (`mount.enabled`): what it left in Files goes.
    Off,
    /// The drive was unmounted (Files' unmount button, or Unmount in the app): it comes back with Mount or at the next
    /// login, so its bookmark and folder stay.
    Unmounted,
}

/// The daemon without its drive (Verso's, until it is switched on, or once it was unmounted): the tray and the D-Bus
/// interface alone, until stopped. With the drive off, what it left in Files goes: its bookmark, and its folder while
/// empty.
#[allow(clippy::too_many_arguments)]
fn daemon_without_drive(
    paths: &Paths,
    config: &Config,
    mount_point: &Path,
    server_url: String,
    version: Option<String>,
    client: &Client,
    runtime: &tokio::runtime::Runtime,
    without: Without,
) -> Result<Option<StopReason>> {
    use verso_linux::dbus::State;
    use verso_linux::mounts::canonical_mount_point;
    // Not in a Flatpak, which never had a drive and cannot reach the host's sidebar or home.
    let sandboxed = verso_core::product::current().sandboxed;
    if without == Without::Off && !sandboxed && mount_state(&canonical_mount_point(mount_point)) == MountState::NotMounted {
        let _ = verso_linux::gnome::set_sidebar_entry(paths, mount_point, config.mount_name, verso_linux::gnome::SidebarEntry::Drive);
        let _ = std::fs::remove_dir(mount_point);
    }
    let account = version.is_some().then(|| runtime.block_on(client.my_email()).ok()).flatten();
    let server = daemon::ServerInfo { url: server_url, version, account, user_id: None };
    let client = client.clone();
    // The account's own record: it says when the sign-in is no longer accepted, which the server's ping cannot.
    let check = move || {
        let client = client.clone();
        async move {
            match client.my_email().await {
                Err(immich_api::ApiError::Unauthorized) => (State::SignedOut, false),
                // Out of reach until the person decides about the certificate, in Verso.
                Err(immich_api::ApiError::UntrustedCertificate(_) | immich_api::ApiError::CertificateChanged(_)) => (State::Offline, true),
                Err(immich_api::ApiError::Offline(_) | immich_api::ApiError::Transient { .. }) => (State::Offline, false),
                _ => (State::Online, false),
            }
        }
    };
    match daemon::serve_without_drive(server, check, runtime, without == Without::Unmounted) {
        StopReason::Uninstalled => {
            if let Some(unit) = verso_linux::service::own_unit() {
                let _ = std::process::Command::new("systemctl").args(["--user", "disable", &unit]).output();
            }
            verso_linux::participants::remove_all(paths);
            Ok(Some(StopReason::Uninstalled))
        }
        reason => Ok(Some(reason)),
    }
}

/// Run the daemon in the foreground until it is stopped or the mount is ejected. `None` when it never started because
/// the user dismissed the keyring's unlock prompt: that ends the run cleanly, so the service is not restarted into
/// prompting again.
pub fn daemon(paths: &Paths) -> Result<Option<StopReason>> {
    let config = load_config(paths)?;
    let server_url = configured_server(&config)?;
    let runtime = runtime()?;
    let credential = match load_credential(paths, &config, &server_url, &runtime) {
        Ok(credential) => credential,
        Err(error) if matches!(error.downcast_ref::<KeyringError>(), Some(KeyringError::Dismissed)) => {
            let product = verso_core::product::current();
            log::error!("the keyring stayed locked, so Immich is not mounted; run `systemctl --user start {}` after unlocking it", product.service());
            let body = tr("The keyring stayed locked. Open {app}, or run “{command}”, to try again.").replace("{app}", product.name).replace("{command}", &verso_core::product::command("mount"));
            runtime.block_on(verso_linux::notify::notify(tr("Immich is not mounted"), &body));
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let client = client(&server_url, Some(&credential), config.server_certificate)?;
    // The mount comes first: a server that drops requests would otherwise hold it back for the client's retries (four
    // minutes, on Bazzite), with the mount point an empty folder all along.
    let version = match runtime.block_on(server_version_soon(&client)) {
        Ok(version) if !version.is_supported() => {
            bail!("{server_url} runs Immich {version}; {} needs {} or later", verso_core::product::current().name, immich_api::version::MINIMUM_SUPPORTED)
        }
        Ok(version) => {
            log::info!("Immich {version} at {server_url}");
            Some(version.to_string())
        }
        Err(error) => {
            log::warn!("cannot reach {server_url} yet ({error}); mounting anyway");
            None
        }
    };
    let mount_point = paths.expand(&config.mount_path);
    // Verso's participants in Immich Crosslink, as the settings want them; and the app icon chosen for the desktop's
    // style, in the launcher's entry, which an upgrade replaces with the install's own, named again at each change of
    // colour scheme while the service runs. A Flatpak cannot reach its entry.
    verso_linux::participants::sync(paths, &config);
    if !verso_core::product::current().sandboxed {
        runtime.spawn(verso_linux::app_icon::follow_style(paths.clone()));
    }
    if !config.mount_enabled {
        return daemon_without_drive(paths, &config, &mount_point, server_url, version, &client, &runtime, Without::Off);
    }
    // The drive's icon in Files' sidebar (ARCHITECTURE.md, "The drive's icon"): the volume monitor's fstab lists the
    // mount from before it is mounted, so GVfs has its volume when the mount appears, and until it stops. Another
    // daemon serving the mount keeps its line: this one then stops at once, and touches none of it.
    let served_elsewhere = verso_linux::mounts::mount_state(&verso_linux::mounts::canonical_mount_point(&mount_point))
        == verso_linux::mounts::MountState::Mounted;
    if !served_elsewhere {
        if let Err(error) = verso_linux::gnome::list_mount_in_fstab(paths, Some((&mount_point, config.mount_name, config.mount_unmount_button))) {
            log::warn!("could not list the mount in the volume monitor's fstab: {error}");
        }
    }
    // Without its unmount button, GVfs no longer lists the drive: a bookmark takes its place (`mount.unmount_button`).
    let entry = if config.mount_unmount_button { verso_linux::gnome::SidebarEntry::Drive } else { verso_linux::gnome::SidebarEntry::Bookmark };
    match verso_linux::gnome::set_sidebar_entry(paths, &mount_point, config.mount_name, entry) {
        Ok(true) => log::info!("listed the drive in Files' sidebar as a {entry:?}"),
        Ok(false) => {}
        Err(error) => log::warn!("could not change how Files lists the drive: {error}"),
    }
    // GVfs lists no mount in a home reached through a symlink until its volume monitor has the resolved home.
    match verso_linux::gnome::show_mounts_in_sidebar(paths, &mount_point) {
        Ok(true) => log::info!("set GVfs's volume monitor up, so Files lists the mount as a drive with its icon"),
        Ok(false) => {}
        Err(error) => log::warn!("could not set GVfs up for this home, so Files may not list the mount: {error}"),
    }
    // The drive's name, in the sidebar entry the apps' setup made, after it changed (`mount.name`).
    match verso_linux::gnome::retitle_bookmark(paths, &mount_point, config.mount_name) {
        Ok(true) => log::info!("named the mount's sidebar entry \"{}\"", config.mount_name),
        Ok(false) => {}
        Err(error) => log::warn!("could not name the mount's sidebar entry \"{}\": {error}", config.mount_name),
    }
    let account_cache = paths.account_cache(&account_name(&client));
    // Shown by the apps; an API key without `user.read` is simply not named.
    // The id checks a crosslink's user; the full record is read first, and the email alone where it does not decode.
    let (account, user_id) = match version.is_some().then(|| runtime.block_on(client.me()).ok()).flatten() {
        Some(me) => (Some(me.email), Some(me.id)),
        None => (version.is_some().then(|| runtime.block_on(client.my_email()).ok()).flatten(), None),
    };
    // Kept for Verso, which goes on without the drive once it is unmounted.
    let (kept_config, kept_url, kept_version, kept_client) = (config.clone(), server_url.clone(), version.clone(), client.clone());
    let source = Arc::new(ImmichSource::new(client));
    let server = daemon::ServerInfo { url: server_url, version, account, user_id };
    let updates = crate::updates::wanted(&config).then(|| (crate::updates::check(), paths.state_directory.join("update-told")));
    // The mount point's folder icon in Files, as the folder is seen unmounted and, once up, mounted.
    if std::fs::create_dir_all(&mount_point).is_ok() {
        verso_linux::gnome::set_folder_icon(&mount_point);
    }
    let watched = mount_point.clone();
    std::thread::spawn(move || {
        let resolved = verso_linux::mounts::canonical_mount_point(&watched);
        for _ in 0..240 {
            if verso_linux::mounts::mount_state(&resolved) == verso_linux::mounts::MountState::Mounted {
                verso_linux::gnome::set_folder_icon(&watched);
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
    });
    let served = daemon::serve(source, server, config, &mount_point, &account_cache, &paths.thumbnail_directory, &paths.not_uploaded_directory(), updates, &runtime);
    if !served_elsewhere {
        if let Err(error) = verso_linux::gnome::list_mount_in_fstab(paths, None) {
            log::warn!("could not take the mount out of the volume monitor's fstab: {error}");
        }
    }
    match served {
        // Another daemon serves it (the packages' service and Homebrew's both on): this one leaves cleanly, so its
        // service is not restarted every few seconds.
        Err(daemon::DaemonError::AlreadyMounted(path)) => {
            log::warn!("{} is already mounted by another Verso service; this one stops", path.display());
            Ok(None)
        }
        // Its program is gone: turn off the service that started it, so it does not fail at every login, and take
        // away what points at a mount that will not come back (the credential and the caches stay for `logout`).
        Ok(StopReason::Uninstalled) => {
            if let Some(unit) = verso_linux::service::own_unit() {
                let _ = std::process::Command::new("systemctl").args(["--user", "disable", &unit]).output();
            }
            if let Err(error) = crate::commands::remove_desktop_traces(paths, &mount_point) {
                log::warn!("could not take the mount out of the desktop: {error:#}");
            }
            Ok(Some(StopReason::Uninstalled))
        }
        // Unmounted from Files or from the window: the tray and the window's service stay, the drive switched on as it
        // was.
        Ok(StopReason::Ejected) => {
            log::info!("the drive was unmounted; going on without it until Mount or the next login");
            daemon_without_drive(paths, &kept_config, &mount_point, kept_url, kept_version, &kept_client, &runtime, Without::Unmounted)
        }
        outcome => Ok(Some(outcome?)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_names_are_the_servers_host_and_port() {
        let named = |url: &str| account_name(&client(url, None, None).unwrap());
        assert_eq!(named("http://192.168.1.20:2283"), "192.168.1.20-2283");
        assert_eq!(named("https://photos.example.org"), "photos.example.org-443");
    }
}
