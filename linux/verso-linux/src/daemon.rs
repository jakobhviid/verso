//! The daemon's life (ARCHITECTURE.md, "The daemon's lifecycle"): detach a dead mount, mount, serve until stopped
//! or ejected, then unmount cleanly.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use verso_core::content::{BlockCache, ContentSource};
use verso_core::settings::Config;
use verso_core::source::{LibrarySource, SourceError, ThumbnailSource};
use verso_core::folder_uploads::AlbumTarget;
use verso_core::uploads::UploadTarget;
use verso_core::store::MetadataStore;
use verso_core::tree::Tree;

use crate::fuse::{mount, ImmichFilesystem};
use crate::mounts::{mount_state, unmount, MountState};
use crate::dbus::{Actions, State};
use crate::i18n::tr;
use crate::seeding::Seeder;
use crate::staging::Staging;

/// How often the daemon checks whether the user ejected the mount.
const EJECT_POLL: Duration = Duration::from_secs(2);
/// How often the daemon looks at the program it was started from, which an upgrade replaces and an uninstall removes.
const PROGRAM_POLL: Duration = Duration::from_secs(5);
/// How long the program may be missing before the daemon takes it as uninstalled: an upgrade removes the old version
/// before it puts the new one in place.
const UNINSTALL_GRACE: Duration = Duration::from_secs(120);
/// How often the daemon asks Immich what changed, so a change made elsewhere shows within seconds. Unchanged, that
/// costs two 304 answers, and for a session an empty sync stream.
const CHANGE_POLL: Duration = Duration::from_secs(10);
/// How long finding a path's item for its web address may take: a folder the file manager shows is listed already, so
/// this is reached only for a path typed by hand, while the server is slow.
const WEB_LINK_LIMIT: Duration = Duration::from_secs(10);
/// How long finding a received link's item may take: a photo's details and up to four folder listings.
const SHOW_LINK_LIMIT: Duration = Duration::from_secs(20);

/// Asks for the server's state now rather than at the next poll: the top bar's Try Again Now, the window's Try Now
/// (`CheckNow` on D-Bus), and a change of network. A request while no poll waits is kept for the next one.
fn check_requested() -> &'static tokio::sync::Notify {
    static REQUESTED: std::sync::OnceLock<tokio::sync::Notify> = std::sync::OnceLock::new();
    REQUESTED.get_or_init(tokio::sync::Notify::new)
}

/// Ask the server how it is now (see [`check_requested`]).
pub fn check_now() {
    check_requested().notify_one();
}

/// Wait for the next poll: the interval's tick, or a check asked for sooner.
async fn next_poll(interval: &mut tokio::time::Interval) {
    tokio::select! {
        _ = interval.tick() => {}
        _ = check_requested().notified() => {}
    }
}

/// How long after a change of network the server is asked once more: the first check can come before the new
/// network's addresses and names are ready.
const NETWORK_SETTLE: Duration = Duration::from_secs(3);

/// A change of network (connected, disconnected, another one) asks for a check at once and again a moment later,
/// through the desktop's NetworkMonitor portal, which a Flatpak reaches too. Without the portal, the poll's interval is
/// what there is.
async fn follow_network() {
    use futures_util::StreamExt;
    let Ok(connection) = zbus::Connection::session().await else { return };
    let built = async {
        zbus::proxy::Builder::<zbus::Proxy>::new(&connection)
            .destination("org.freedesktop.portal.Desktop")?
            .path("/org/freedesktop/portal/desktop")?
            .interface("org.freedesktop.portal.NetworkMonitor")?
            .cache_properties(zbus::proxy::CacheProperties::No)
            .build()
            .await
    };
    let Ok(proxy) = built.await else { return };
    let Ok(mut changes) = proxy.receive_signal("changed").await else { return };
    while changes.next().await.is_some() {
        log::debug!("the network changed; asking the server now");
        check_now();
        tokio::spawn(async {
            tokio::time::sleep(NETWORK_SETTLE).await;
            check_now();
        });
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DaemonError {
    #[error("{0} is already mounted, probably by another Verso service")]
    AlreadyMounted(PathBuf),
    #[error("could not prepare {path}: {message}")]
    Prepare { path: PathBuf, message: String },
    #[error("could not mount at {path}: {message}")]
    Mount { path: PathBuf, message: String },
}

/// Why the daemon stopped serving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// SIGTERM or Ctrl-C (logout, `systemctl --user stop`).
    Signal,
    /// The user ejected the mount in the file manager. Respected until the next start.
    Ejected,
    /// The program was upgraded: the daemon left once nothing was open or uploading, so its service starts the new one.
    Upgraded,
    /// The program was uninstalled: the daemon left once idle, and its service is to be turned off.
    Uninstalled,
}

/// What became of the program the daemon was started from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramChange {
    Unchanged,
    Upgraded,
    Uninstalled,
}

/// The program the user service started: the path it ran (`argv[0]`, which systemd gives absolute) and the file this
/// process runs. A package manager replaces a program by putting a new file in its place, so the path then names a
/// file other than the running one; an uninstall leaves nothing there. Verso's window watches its own program too, or,
/// behind the tarball's launcher, the launcher.
pub struct ProgramWatch {
    path: PathBuf,
    running: (u64, u64),
    missing_since: Option<Instant>,
}

impl ProgramWatch {
    /// `None` when started by a relative name (from a terminal), where there is no path to watch. A program in a
    /// `libexec` folder (the tarball's window) watches the launcher in front of it (`programs::launcher`), the file it
    /// was when the watch began: the launcher is what was started and what an upgrade replaces, while the program's own
    /// path is one version's folder under Homebrew, gone after an upgrade.
    pub fn new() -> Option<ProgramWatch> {
        // A Flatpak and an AppImage are replaced as a whole, never program by program under a running one.
        if !verso_core::product::current().installed() {
            return None;
        }
        if let Some(launcher) = crate::programs::launcher() {
            let file = std::fs::metadata(&launcher).ok()?;
            return Some(ProgramWatch { path: launcher, running: (file.dev(), file.ino()), missing_since: None });
        }
        let path = PathBuf::from(std::env::args_os().next()?);
        if !path.is_absolute() {
            return None;
        }
        let running = std::fs::metadata("/proc/self/exe").ok()?;
        Some(ProgramWatch { path, running: (running.dev(), running.ino()), missing_since: None })
    }

    /// The path the program was started by, which names the new version after an upgrade.
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn check(&mut self, now: Instant) -> ProgramChange {
        let found = std::fs::metadata(&self.path).ok().map(|metadata| (metadata.dev(), metadata.ino()));
        self.judge(found, now)
    }

    /// The change, given the file now at the path (device and inode), if any.
    fn judge(&mut self, found: Option<(u64, u64)>, now: Instant) -> ProgramChange {
        match found {
            Some(file) if file == self.running => {
                self.missing_since = None;
                ProgramChange::Unchanged
            }
            Some(_) => {
                self.missing_since = None;
                ProgramChange::Upgraded
            }
            None => {
                let since = *self.missing_since.get_or_insert(now);
                if now.duration_since(since) >= UNINSTALL_GRACE {
                    ProgramChange::Uninstalled
                } else {
                    ProgramChange::Unchanged
                }
            }
        }
    }
}

/// The server the daemon serves, as the app sees it over D-Bus.
pub struct ServerInfo {
    pub url: String,
    /// `None` when the server could not be reached at start.
    pub version: Option<String>,
    /// The signed-in account's email, when the credential may read it.
    pub account: Option<String>,
    /// The signed-in user's Immich id, when the credential may read it: a crosslink for another user is refused.
    pub user_id: Option<String>,
}

/// Mount the library at `mount_point` and serve it until stopped. `account_cache` holds this account's metadata store,
/// content cache and seeding ledger; `thumbnail_directory` is the freedesktop thumbnail cache seeds go into.
/// `updates`, where this install learns of new releases from Verso's page (the rpm and the deb), is the look and the
/// file that keeps the version last told of (`crate::updates`).
#[allow(clippy::too_many_arguments)]
pub fn serve<Source>(
    source: Arc<Source>,
    server: ServerInfo,
    config: Config,
    mount_point: &Path,
    account_cache: &Path,
    thumbnail_directory: &Path,
    not_uploaded_directory: &Path,
    updates: Option<(crate::updates::Check, PathBuf)>,
    runtime: &tokio::runtime::Runtime,
) -> Result<StopReason, DaemonError>
where
    Source: LibrarySource + ContentSource + ThumbnailSource + UploadTarget + AlbumTarget + 'static,
{
    let prepare_error = |path: &Path, message: String| DaemonError::Prepare { path: path.to_path_buf(), message };
    match mount_state(mount_point) {
        MountState::Mounted => return Err(DaemonError::AlreadyMounted(mount_point.to_path_buf())),
        MountState::Stale => {
            log::warn!("detaching a dead mount at {}", mount_point.display());
            unmount(mount_point, true).map_err(|message| prepare_error(mount_point, message))?;
        }
        MountState::NotMounted => {}
    }
    std::fs::create_dir_all(mount_point).map_err(|error| prepare_error(mount_point, error.to_string()))?;
    // Mounting over a folder with files would hide them (FUSE mounts over non-empty folders), and the home folder or a
    // folder holding the daemon's own cache would hide far more.
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    if home.as_deref().is_some_and(|home| crate::mounts::canonical_mount_point(home) == crate::mounts::canonical_mount_point(mount_point))
        || account_cache.starts_with(mount_point)
    {
        return Err(prepare_error(mount_point, "this folder cannot hold the mount; choose an empty folder such as ~/Immich".to_owned()));
    }
    if std::fs::read_dir(mount_point).map_err(|error| prepare_error(mount_point, error.to_string()))?.next().is_some() {
        return Err(prepare_error(mount_point, "the folder is not empty, and mounting over it would hide its files; choose an empty folder".to_owned()));
    }
    // The mount table and GVfs use the resolved path; comparing against anything else would read as an eject at once.
    // Where home is reached through a symlink, file managers browsing from home use the configured one, so
    // thumbnails are seeded under both.
    let configured_mount_point = mount_point.to_path_buf();
    let mount_point = &crate::mounts::canonical_mount_point(mount_point);
    let mut thumbnail_roots = vec![mount_point.clone()];
    if configured_mount_point != *mount_point {
        thumbnail_roots.push(configured_mount_point);
    }

    let store = MetadataStore::open(&account_cache.join("metadata.redb")).map_err(|error| prepare_error(account_cache, error.to_string()))?;
    let (sharp_thumbnails, safety_net, cache_limit_bytes) = (config.sharp_thumbnails, config.thumbnail_safety_net, config.cache_limit_bytes);
    let (uploads_enabled, upload_folders, drive_name) = (config.uploads_enabled, config.upload_folders, config.mount_name);
    let (crosslink_enabled, crosslink_hidden, web_links) = (config.crosslink_enabled, config.crosslink_hidden.clone(), config.web_links);
    let tree = Arc::new(Tree::new(source.clone(), store, config));
    let content_directory = account_cache.join("content");
    let seeder = Seeder::new(Arc::new(source.clone()), thumbnail_directory, account_cache, sharp_thumbnails)
        .map_err(|error| prepare_error(account_cache, error.to_string()))?;
    let disk = content_directory.clone();
    let disk_room: verso_core::content::DiskRoomProbe = Arc::new(move || {
        let space = crate::fuse::free_space(&disk)?;
        let block_size = u64::from(space.block_size);
        Some(verso_core::content::DiskRoom { available: space.available * block_size, total: space.blocks * block_size })
    });
    let content = Arc::new(
        BlockCache::new(source.clone(), &content_directory, cache_limit_bytes)
            .map_err(|error| prepare_error(&content_directory, error.to_string()))?
            .with_disk_floor(disk_room),
    );
    let mut filesystem = ImmichFilesystem::new(tree.clone(), content.clone(), runtime.handle().clone())
        .with_drive_name(drive_name)
        .with_thumbnails(Arc::new(seeder), &thumbnail_roots, safety_net);
    let mut staging = None;
    if uploads_enabled {
        let staging_directory = account_cache.join("staging");
        let area = Arc::new(Staging::new(&staging_directory, not_uploaded_directory).map_err(|error| prepare_error(&staging_directory, error.to_string()))?);
        // The server's own list of media types; the built-in one when it cannot be asked yet.
        let media = runtime.block_on(async { tokio::time::timeout(Duration::from_secs(10), source.media_types()).await }).ok().and_then(Result::ok);
        // The folders copied into Upload, followed for their albums (ARCHITECTURE.md, "Folders copied into Upload"),
        // and kept in the account's cache, so a restart asks again what was being asked.
        let copies_file = account_cache.join("folder-copies.json");
        let folders = Arc::new(std::sync::Mutex::new(crate::folders::kept_copies(&copies_file)));
        filesystem = filesystem.with_uploads(area.clone(), media.unwrap_or_default(), Arc::new(source.clone()), folders.clone());
        runtime.spawn(crate::folders::follow(folders, copies_file, area.clone(), Arc::new(source.clone()), upload_folders));
        staging = Some(area);
    }
    // The daemon leaves for an upgrade or an uninstall only when nothing is open or uploading.
    let open_files = filesystem.open_files();
    let staging_for_idle = staging.clone();
    let idle = move || open_files.load(Ordering::Relaxed) == 0 && staging_for_idle.as_ref().is_none_or(|area| area.is_idle());
    let session = mount(filesystem, mount_point).map_err(|error| DaemonError::Mount { path: mount_point.to_path_buf(), message: error.to_string() })?;
    log::info!("mounted at {}", mount_point.display());

    let state = Arc::new(std::sync::Mutex::new(if server.version.is_some() { State::Online } else { State::Offline }));
    let actions = {
        let (usage_cache, clear_cache, refresh_tree, unmount_point) = (content.clone(), content.clone(), tree.clone(), mount_point.to_path_buf());
        Actions {
            cache_usage: Box::new(move || (usage_cache.used_bytes(), usage_cache.limit_bytes())),
            fetched: Box::new({
                let content = content.clone();
                move || content.fetched()
            }),
            uploads: Box::new(move || staging.as_ref().map(|area| area.in_flight()).unwrap_or_default()),
            refresh: Box::new(move || refresh_tree.forget_all()),
            clear_cache: Box::new(move || clear_cache.clear()),
            unmount: Box::new(move || unmount(&unmount_point, false)),
            show_link: Box::new({
                let (tree, mount_point, server_url, user_id) = (tree.clone(), mount_point.to_path_buf(), server.url.clone(), server.user_id.clone());
                move |link, select, notify| {
                    let (tree, mount_point, server_url, user_id) = (tree.clone(), mount_point.clone(), server_url.clone(), user_id.clone());
                    Box::pin(async move {
                        let (result, detail) = show_link(&tree, &link, &mount_point, &server_url, user_id.as_deref(), crosslink_enabled, select).await;
                        if notify && result != "show" {
                            let (summary, body) = refusal_message(result, &detail);
                            crate::notify::notify(&summary, &body).await;
                        }
                        (result.to_owned(), detail)
                    })
                }
            }),
            links: Box::new({
                let (tree, mount_point, server_url, user_id) = (tree.clone(), mount_point.to_path_buf(), server.url.clone(), server.user_id.clone());
                move |path| {
                    let (tree, names, server_url, user_id) = (tree.clone(), crate::mounts::names_below(&path, &mount_point), server_url.clone(), user_id.clone());
                    let hidden = crosslink_hidden.clone();
                    Box::pin(async move {
                        let names = names?;
                        let names: Vec<&str> = names.iter().map(String::as_str).collect();
                        let key = tokio::time::timeout(WEB_LINK_LIMIT, tree.key_at(&names)).await.ok()?.ok()??;
                        // With web links off, the address is left out and the menus offer Show in alone.
                        let web = verso_core::links::web_address(&server_url, &key)?;
                        let web = if web_links { web } else { String::new() };
                        let kind = verso_core::links::kind(&key)?.as_str().to_owned();
                        let crosslink = if crosslink_enabled {
                            verso_core::links::crosslink(&server_url, user_id.as_deref(), &key).unwrap_or_default()
                        } else {
                            String::new()
                        };
                        Some((web, crosslink, kind, hidden))
                    })
                }
            }),
            web_link: Box::new({
                let (tree, mount_point, server_url) = (tree.clone(), mount_point.to_path_buf(), server.url.clone());
                move |path| {
                    let (tree, names, server_url) = (tree.clone(), crate::mounts::names_below(&path, &mount_point), server_url.clone());
                    Box::pin(async move {
                        let names = names?;
                        let names: Vec<&str> = names.iter().map(String::as_str).collect();
                        let key = tokio::time::timeout(WEB_LINK_LIMIT, tree.key_at(&names)).await.ok()?.ok()??;
                        verso_core::links::web_address(&server_url, &key).filter(|_| web_links)
                    })
                }
            }),
        }
    };
    let mount_text = mount_point.display().to_string();
    let version = server.version.clone().unwrap_or_default();
    let account = server.account.clone().unwrap_or_default();
    let connection = runtime.block_on(crate::dbus::serve(state.clone(), &mount_text, &server.url, &version, &account, actions));
    let mut tray = None;
    if let Some(connection) = &connection {
        let view = crate::tray::View {
            state: *state.lock().expect("state lock"),
            server_url: server.url.clone(),
            server_version: version.clone(),
            account: account.clone(),
            mount_point: mount_text.clone(),
            update: None,
            checks_updates: updates.is_some(),
            gallery: crate::tray::gallery_program(),
            product: verso_core::product::current(),
            unmounted: false,
        };
        tray = runtime.block_on(crate::tray::show(connection, view));
    }
    let mut tasks = vec![runtime.spawn(follow_changes(source.clone(), tree.clone(), state, connection.clone())), runtime.spawn(follow_network())];
    tasks.extend(tray);
    if let Some((check, told)) = updates {
        tasks.push(runtime.spawn(crate::updates::follow(check, verso_core::product::VERSION, connection.clone(), told)));
    }

    let reason = runtime.block_on(wait_for_stop(Some(mount_point), idle));
    // What served the drive stops with it: Verso's service goes on without the drive once it is unmounted, and these
    // held this connection, and with it a second top bar item beside the new one.
    for task in tasks {
        task.abort();
    }
    match reason {
        StopReason::Signal => log::info!("stopping"),
        StopReason::Ejected => log::info!("{} was unmounted from outside (eject); stopping", mount_point.display()),
        StopReason::Upgraded => log::info!("{} was upgraded and nothing is open or uploading; stopping so the new version starts", verso_core::product::current().name),
        StopReason::Uninstalled => log::info!("{} was uninstalled and nothing is open or uploading; stopping", verso_core::product::current().name),
    }
    drop(session);
    drop(connection);
    Ok(reason)
}

/// Serve without a drive (Verso's, until it is switched on, `mount.enabled`, or once it was unmounted, `unmounted`,
/// when the tray offers to mount it): the D-Bus interface, so the app finds the daemon and how the server is, and the
/// tray, until stopped, or the program is upgraded or uninstalled. `check` asks the server how it is, as the change
/// polling does with a drive, and whether it is out of reach because its certificate was refused. `updates` is the look
/// for a newer release, as `serve` has it, so an install without the drive is told too.
pub fn serve_without_drive<Check, Answer>(
    server: ServerInfo,
    check: Check,
    updates: Option<(crate::updates::Check, PathBuf)>,
    runtime: &tokio::runtime::Runtime,
    unmounted: bool,
) -> StopReason
where
    Check: Fn() -> Answer + Send + 'static,
    Answer: std::future::Future<Output = (State, bool)> + Send,
{
    let state = Arc::new(std::sync::Mutex::new(if server.version.is_some() { State::Online } else { State::Offline }));
    let version = server.version.clone().unwrap_or_default();
    let account = server.account.clone().unwrap_or_default();
    let actions = crate::dbus::Actions::without_drive();
    let connection = runtime.block_on(crate::dbus::serve(state.clone(), "", &server.url, &version, &account, actions));
    // In a Flatpak or an AppImage, each start is a new instance, and nothing keeps a second one from starting: one
    // whose name is taken leaves, so there is one service and one tray.
    if connection.is_none() && !verso_core::product::current().installed() {
        log::info!("another Verso service runs; this one leaves");
        return StopReason::Signal;
    }
    let mut tray = None;
    if let Some(connection) = &connection {
        let view = crate::tray::View {
            state: *state.lock().expect("state lock"),
            server_url: server.url.clone(),
            server_version: version,
            account,
            mount_point: String::new(),
            update: None,
            checks_updates: updates.is_some(),
            gallery: crate::tray::gallery_program(),
            product: verso_core::product::current(),
            unmounted,
        };
        tray = runtime.block_on(crate::tray::show(connection, view));
    }
    log::info!("serving without the drive");
    let follow = {
        let (state, connection) = (state.clone(), connection.clone());
        async move {
            let mut interval = tokio::time::interval(CHANGE_POLL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut refused = false;
            loop {
                next_poll(&mut interval).await;
                let previous = *state.lock().expect("state lock");
                let (current, certificate) = check().await;
                if current != previous || certificate != refused {
                    refused = certificate;
                    changed_state(&state, current, certificate, connection.as_ref()).await;
                }
            }
        }
    };
    let mut tasks = [Some(runtime.spawn(follow)), Some(runtime.spawn(follow_network())), tray].into_iter().flatten().collect::<Vec<_>>();
    if let Some((check, told)) = updates {
        tasks.push(runtime.spawn(crate::updates::follow(check, verso_core::product::VERSION, connection.clone(), told)));
    }
    let reason = runtime.block_on(wait_for_stop(None, || true));
    log::info!("stopping ({reason:?})");
    for task in tasks {
        task.abort();
    }
    drop(connection);
    reason
}

/// A received link's result and detail (`dbus::Actions::show_link`): the item's path, selected in the file manager
/// with `select`. Only ever shows: nothing is fetched but the item's listings and, for a photo, its details.
async fn show_link<Source, Names>(
    tree: &Tree<Arc<Source>, Names>,
    link: &str,
    mount_point: &Path,
    server_url: &str,
    user_id: Option<&str>,
    enabled: bool,
    select: bool,
) -> (&'static str, String)
where
    Source: LibrarySource + 'static,
    Names: verso_core::tree::NameMemory + 'static,
{
    if !enabled {
        return ("off", String::new());
    }
    let item = match verso_core::links::receive(link, server_url, user_id) {
        Ok(item) => item,
        Err(verso_core::links::Refusal::OtherServer(host)) => return ("other-server", host),
        Err(refusal) => return (refusal.as_str(), String::new()),
    };
    let found = async {
        let Some(key) = tree.locate(&item).await? else { return Ok(None) };
        tree.path_of(&key).await
    };
    let names = match tokio::time::timeout(SHOW_LINK_LIMIT, found).await {
        Ok(Ok(Some(names))) => names,
        Ok(Ok(None)) | Ok(Err(SourceError::NotFound)) => return ("not-found", String::new()),
        Ok(Err(error)) => {
            log::info!("a received link could not be followed: {error}");
            return ("unreachable", String::new());
        }
        Err(_) => return ("unreachable", String::new()),
    };
    let path = names.iter().fold(mount_point.to_path_buf(), |path, name| path.join(name));
    if select {
        // A file manager that hangs as it starts must not hold the link's answer.
        match tokio::time::timeout(Duration::from_secs(10), crate::dbus::show_in_file_manager(&path)).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => log::warn!("could not show {} in the file manager: {error}", path.display()),
            Err(_) => log::warn!("the file manager did not answer within 10 s for {}", path.display()),
        }
    }
    ("show", path.display().to_string())
}

/// The notification for a received link that shows nothing, in the user's language.
pub fn refusal_message(result: &str, detail: &str) -> (String, String) {
    let (summary, body) = match result {
        "off" => (tr("Links from other apps are off"), tr("Turn on Immich Crosslink in Verso's settings to show what other apps link to.")),
        "no-drive" => (tr("Verso Drive is not mounted"), tr("Switch it on in Verso's Preferences, then open the link again.")),
        "invalid" => (tr("A link from another app cannot be opened"), tr("It is not a valid Immich link.")),
        "cannot-show" => (tr("Nothing to show"), tr("Verso Drive has no place for what this link points to.")),
        "other-server" => (tr("Not signed in to {host}"), tr("Verso is signed in to another Immich server.")),
        "other-user" => (tr("Another Immich account"), tr("The link is for another account than the one Verso is signed in with.")),
        "not-found" => (
            tr("Nothing to show"),
            tr("The drive does not show this. It may be hidden, in a section that is switched off, or not shared with you."),
        ),
        _ => (tr("Immich is unreachable"), tr("The Immich server cannot be reached. Try the link again later.")),
    };
    (summary.replace("{host}", detail), body.to_owned())
}

/// Poll for changes for as long as the daemon runs, and forget the listings they touch. The freshness windows stay
/// on underneath, for whatever polling cannot see.
/// It also tracks the connection state for D-Bus, telling the desktop once when the server becomes unreachable or
/// the credential stops working.
async fn follow_changes<Source, Names>(
    source: Arc<Source>,
    tree: Arc<Tree<Arc<Source>, Names>>,
    state: Arc<std::sync::Mutex<State>>,
    connection: Option<zbus::Connection>,
) where
    Source: LibrarySource + 'static,
    Names: verso_core::tree::NameMemory + 'static,
{
    let mut interval = tokio::time::interval(CHANGE_POLL);
    // A poll can take up to its 25-second limit; the next one then waits a full interval, rather than following at
    // once to catch up.
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // Whether the server is out of reach because its certificate was refused, which is told apart.
    let mut refused = false;
    loop {
        next_poll(&mut interval).await;
        let outcome = source.changes(tree.watched()).await;
        let previous = *state.lock().expect("state lock");
        let current = match &outcome {
            Ok(_) => State::Online,
            Err(SourceError::Offline(_) | SourceError::Busy) => State::Offline,
            Err(SourceError::SignedOut) => State::SignedOut,
            Err(_) => previous,
        };
        let certificate = outcome.as_ref().err().is_some_and(SourceError::is_certificate);
        if current != previous || certificate != refused {
            refused = certificate;
            changed_state(&state, current, certificate, connection.as_ref()).await;
        }
        match outcome {
            Ok(changes) if !changes.is_empty() => {
                let forgotten = tree.apply_changes(&changes);
                if changes.everything {
                    log::info!("Immich changed in a way that touches everything; {forgotten} folder(s) will be read again");
                } else {
                    log::info!(
                        "Immich changed: {} month(s), {} album(s){}{}; {forgotten} folder(s) will be read again",
                        changes.months.len(),
                        changes.albums.len(),
                        if changes.favorites_changed { ", the favorites" } else { "" },
                        if changes.archive_changed { ", the archive" } else { "" }
                    );
                }
            }
            Ok(_) => {}
            Err(error) => log::debug!("change poll failed: {error}"),
        }
    }
}

/// Keep the connection's new state, and tell D-Bus, the tray and, when something went wrong, the user. `certificate`:
/// the server is out of reach because its certificate is not trusted, or not the one trusted for it.
async fn changed_state(state: &std::sync::Mutex<State>, current: State, certificate: bool, connection: Option<&zbus::Connection>) {
    *state.lock().expect("state lock") = current;
    let product = verso_core::product::current().name;
    let message = match current {
        State::Offline if certificate => format!("The Immich server presented a certificate {product} does not trust, so nothing is sent to it. Open {product} to check the certificate. Files you opened before stay available."),
        State::Offline => "The Immich server cannot be reached. Files you opened before stay available.".to_owned(),
        State::SignedOut => format!("Immich no longer accepts this sign-in. Open {product} to sign in again."),
        State::Online | State::Connecting => "Connected to Immich.".to_owned(),
    };
    log::info!("{}: {message}", current.as_str());
    if current == State::Online {
        crate::notify::reachable_again();
    }
    if let Some(connection) = connection {
        let _ = tokio::time::timeout(Duration::from_secs(3), crate::dbus::announce(connection, current, &message)).await;
        let _ = tokio::time::timeout(Duration::from_secs(3), crate::tray::update(connection, current)).await;
    }
    // The log and D-Bus keep the message in English; the notification says it in the user's language.
    match current {
        State::Offline if certificate => crate::notify::notify_in_background(
            tr("Immich's certificate is not trusted").to_owned(),
            tr("The Immich server presented a certificate {app} does not trust, so nothing is sent to it. Open {app} to check the certificate. Files you opened before stay available.").replace("{app}", product),
        ),
        State::Offline => crate::notify::notify_in_background(
            tr("Immich is unreachable").to_owned(),
            tr("The Immich server cannot be reached. Files you opened before stay available.").to_owned(),
        ),
        State::SignedOut => crate::notify::notify_in_background(
            tr("Signed out of Immich").to_owned(),
            tr("Immich no longer accepts this sign-in. Open {app} to sign in again.").replace("{app}", product),
        ),
        State::Online | State::Connecting => {}
    }
}

/// Wait until the daemon is to stop: a signal, the mount ejected (where there is one), or the program upgraded or
/// uninstalled once `idle`.
async fn wait_for_stop(mount_point: Option<&Path>, idle: impl Fn() -> bool) -> StopReason {
    let mut terminate = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
        Ok(signal) => signal,
        Err(error) => {
            log::error!("cannot listen for SIGTERM: {error}");
            return StopReason::Signal;
        }
    };
    let mut ticker = tokio::time::interval(EJECT_POLL);
    let mut program = ProgramWatch::new();
    let mut last_look = Instant::now();
    let mut change = ProgramChange::Unchanged;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return StopReason::Signal,
            _ = terminate.recv() => return StopReason::Signal,
            _ = ticker.tick() => {
                if mount_point.is_some_and(|mount_point| mount_state(mount_point) == MountState::NotMounted) {
                    return StopReason::Ejected;
                }
                if let Some(watch) = program.as_mut().filter(|_| last_look.elapsed() >= PROGRAM_POLL) {
                    last_look = Instant::now();
                    let seen = watch.check(last_look);
                    // An upgrade seen once stays seen; a program missing then back counts as an upgrade.
                    if change != ProgramChange::Upgraded {
                        if change == ProgramChange::Unchanged && seen != ProgramChange::Unchanged {
                            log::info!("{} was {}; leaving once nothing is open or uploading", watch.path.display(), match seen {
                                ProgramChange::Upgraded => "replaced by an upgrade",
                                _ => "uninstalled",
                            });
                        }
                        change = seen;
                    }
                }
                match change {
                    ProgramChange::Upgraded if idle() => return StopReason::Upgraded,
                    ProgramChange::Uninstalled if idle() => return StopReason::Uninstalled,
                    _ => {}
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replaced_program_is_an_upgrade_and_a_long_missing_one_an_uninstall() {
        let start = Instant::now();
        let mut watch = ProgramWatch { path: PathBuf::from("/usr/bin/verso-service"), running: (1, 10), missing_since: None };
        assert_eq!(watch.judge(Some((1, 10)), start), ProgramChange::Unchanged);
        assert_eq!(watch.judge(Some((1, 11)), start), ProgramChange::Upgraded);
        // Missing for a while is an upgrade in progress, not yet an uninstall.
        assert_eq!(watch.judge(None, start), ProgramChange::Unchanged);
        assert_eq!(watch.judge(None, start + UNINSTALL_GRACE / 2), ProgramChange::Unchanged);
        assert_eq!(watch.judge(None, start + UNINSTALL_GRACE), ProgramChange::Uninstalled);
        // Back in place, as a new file: the upgrade finished.
        assert_eq!(watch.judge(Some((1, 12)), start + UNINSTALL_GRACE), ProgramChange::Upgraded);
        assert_eq!(watch.missing_since, None);
    }
}
