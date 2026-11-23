//! The account the gallery shows: the server and credential the drive uses (`config.toml` and the keyring, as
//! `verso-service login` and the window keep them), so one sign-in serves both.

use std::path::PathBuf;

use immich_api::{CertificatePin, Client, UserDetails};
use verso_core::settings::Config;
use verso_linux::credentials::{read_credential_file, Credential};
use verso_linux::i18n::tr;
use verso_linux::keyring::{self, KeyringError};
use verso_linux::paths::Paths;
use sha1::{Digest, Sha1};

/// What the gallery tells the server it is.
pub fn user_agent() -> String {
    format!("verso/{}", verso_core::product::VERSION)
}

/// A signed-in account.
#[derive(Clone)]
pub struct Connection {
    /// The server's address as configured (`server.url`).
    pub server: String,
    pub client: Client,
    /// The account, when the credential may read it (a scoped API key may not).
    pub account: Option<UserDetails>,
    /// Signed in with an API key rather than a session: the Locked Folder and some account pages need a session.
    pub with_api_key: bool,
}

impl Connection {
    /// Where this account's pictures are cached: one folder per server and account, so another account's never show.
    pub fn cache_directory(&self) -> PathBuf {
        let mut hasher = Sha1::new();
        hasher.update(self.server.as_bytes());
        hasher.update(b"\n");
        hasher.update(self.account.as_ref().map_or("", |account| account.id.as_str()).as_bytes());
        let digest = hasher.finalize();
        let key: String = digest.iter().take(10).map(|byte| format!("{byte:02x}")).collect();
        gallery_cache_root().join(key)
    }

    /// The account's name for what is kept for each account (the recent searches, Verso's notifications): its cache
    /// folder's, one per server and account.
    pub fn account_key(&self) -> String {
        self.cache_directory().file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
    }

    pub fn user_id(&self) -> Option<&str> {
        self.account.as_ref().map(|account| account.id.as_str())
    }

    pub fn is_admin(&self) -> bool {
        self.account.as_ref().is_some_and(|account| account.is_admin)
    }
}

/// `$XDG_CACHE_HOME/verso/gallery`, beside the drive's caches (which are named for their server, never `gallery`).
pub fn gallery_cache_root() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".cache"))
        .join("verso")
        .join("gallery")
}

/// A client for `server` with `credential`, also trusting the certificate `trusted` names for it.
pub fn client(server: &str, credential: Option<&Credential>, trusted: Option<CertificatePin>) -> Result<Client, String> {
    let credential = credential.map(|credential| match credential {
        Credential::ApiKey(key) => immich_api::Credential::ApiKey(key.clone()),
        Credential::Session(token) => immich_api::Credential::Session(token.clone()),
    });
    Client::trusting(server, credential, &user_agent(), trusted).map_err(|error| tr("That address cannot be used: {error}").replace("{error}", &error.to_string()))
}

/// The stored credential, looked for where the daemon looks: a configured `credential.file`, the default file a
/// headless sign-in leaves, then the keyring (which may bring up its unlock prompt). `None` when signed out.
async fn stored_credential(paths: &Paths, config: &Config, server: &str) -> Result<Option<Credential>, String> {
    if let Some(file) = config.credential_file.as_deref().map(|file| paths.expand(file)) {
        return match read_credential_file(&file) {
            Ok(credential) => Ok(Some(credential)),
            Err(_) if !file.exists() => Ok(None),
            Err(error) => Err(error.to_string()),
        };
    }
    let default_file = paths.default_credential_file();
    if default_file.exists() {
        return read_credential_file(&default_file).map(Some).map_err(|error| error.to_string());
    }
    match keyring::load(server).await {
        Ok(credential) => Ok(credential),
        Err(KeyringError::Unavailable(_)) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// Connect with the stored server, credential and trusted certificate. `Ok(None)` when nobody is signed in. A server
/// that cannot be reached, or whose certificate is not the one trusted for it, gives a connection without its account,
/// which the window asks again (and asks the person about the certificate).
pub async fn connect() -> Result<Option<Connection>, String> {
    let paths = Paths::from_environment();
    let text = match std::fs::read_to_string(paths.config_file()) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    let config = Config::from_toml(&text).map_err(|error| error.to_string())?;
    let Some(server) = config.server_url.clone().filter(|url| !url.trim().is_empty()) else { return Ok(None) };
    let Some(credential) = stored_credential(&paths, &config, &server).await? else { return Ok(None) };
    let client = client(&server, Some(&credential), config.server_certificate)?;
    let with_api_key = matches!(credential, Credential::ApiKey(_));
    let account = match client.me().await {
        Ok(account) => Some(account),
        Err(immich_api::ApiError::Unauthorized) => return Err(tr("The server refused the stored sign-in. Sign in again.").to_owned()),
        Err(_) => None,
    };
    Ok(Some(Connection { server, client, account, with_api_key }))
}
