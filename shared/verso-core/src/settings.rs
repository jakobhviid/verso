//! The settings table: one source of truth for every user setting.
//!
//! `verso-service configure` and Verso's Preferences both read this table, so they can never disagree
//! about which settings exist or what values are valid (ARCHITECTURE.md, "One layout for every settings window"). Settings live in
//! `config.toml`. Reading is lenient: unknown keys are ignored. Writing goes through `toml_edit`, so comments and
//! the user's own layout survive.

use toml_edit::{value, DocumentMut, Item, Table};

use crate::folder_uploads::FolderChoice;
use crate::layout::{AlbumLayout, GroupingMode};
use crate::naming::FileNaming;

/// The config file format this build writes. Older files are migrated once on load.
pub const CONFIG_FORMAT_VERSION: i64 = 1;

/// The kind of value a setting takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Bool,
    /// Free text, such as a URL.
    Text,
    /// A file system path; `~` is expanded by the caller.
    Path,
    /// A size such as `10GB` or `10GiB`.
    Size,
    /// One of a fixed set of words.
    Choice(&'static [&'static str]),
}

/// One user setting.
#[derive(Debug, Clone, Copy)]
pub struct Setting {
    /// Dotted key, mirroring the TOML path.
    pub key: &'static str,
    pub kind: Kind,
    /// A one-line description, shown by `configure list` and as the settings dialog's subtitle.
    pub description: &'static str,
    /// The default, as text. Empty means "not set".
    pub default: &'static str,
}

const GROUPING_CHOICES: &[&str] = &["never", "atLeast500", "always"];
/// The names the drive may have in a file manager's sidebar, as `mount.name` stores them: Verso's, and Immich Mount's,
/// which Verso knows to read its settings (`Product::drive_names`); each product offers its own.
const MOUNT_NAMES: &[&str] = &["immich-mount", "immich-drive", "immich", "verso-drive", "verso"];
/// The drive's name when none is chosen.
pub const DEFAULT_MOUNT_NAME: &str = "Verso";
/// The app icon's designs, by its picture (DESIGN.md, "The picture's designs"): Mist, the app's own, first.
pub const APP_ICON_DESIGNS: &[&str] = &["mist", "sand", "dark", "paper", "frame", "slate", "sky"];
/// The app icon's looks, as `app.icon` and `app.icon_dark` store them: each design on Day or Night paper, its lens in
/// colour or in graphite, named by the design with `-night` and `-graphite` after it as they apply, in the order
/// `linux/packaging/icons/sources/app-icon.py` draws them. A design's name alone is its Day look in colour.
pub const APP_ICONS: &[&str] = &[
    "mist", "mist-night", "mist-graphite", "mist-night-graphite",
    "sand", "sand-night", "sand-graphite", "sand-night-graphite",
    "dark", "dark-night", "dark-graphite", "dark-night-graphite",
    "paper", "paper-night", "paper-graphite", "paper-night-graphite",
    "frame", "frame-night", "frame-graphite", "frame-night-graphite",
    "slate", "slate-night", "slate-graphite", "slate-night-graphite",
    "sky", "sky-night", "sky-graphite", "sky-night-graphite",
];
/// The app icon in the desktop's light style when none is chosen (`app.icon`): Mist on Day paper, in colour.
pub const DEFAULT_APP_ICON: &str = "mist";
/// The app icon in the desktop's dark style when none is chosen (`app.icon_dark`): Mist on Night paper, in colour.
pub const DEFAULT_APP_ICON_DARK: &str = "mist-night";

/// One of the app icon's looks, by its parts: its design, whether its paper is Night's, and whether its lens is in
/// graphite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppIconLook {
    pub design: &'static str,
    pub night: bool,
    pub graphite: bool,
}

impl AppIconLook {
    /// The look a stored word names; Mist's Day look in colour for a word that names none.
    pub fn parse(word: &str) -> AppIconLook {
        let (rest, graphite) = word.strip_suffix("-graphite").map_or((word, false), |rest| (rest, true));
        let (design, night) = rest.strip_suffix("-night").map_or((rest, false), |design| (design, true));
        match APP_ICON_DESIGNS.iter().find(|known| **known == design) {
            Some(design) => AppIconLook { design, night, graphite },
            None => AppIconLook { design: DEFAULT_APP_ICON, night: false, graphite: false },
        }
    }

    /// The word that stores it, one of [`APP_ICONS`].
    pub fn word(self) -> &'static str {
        let suffix = match (self.night, self.graphite) {
            (false, false) => "",
            (true, false) => "-night",
            (false, true) => "-graphite",
            (true, true) => "-night-graphite",
        };
        APP_ICONS
            .iter()
            .copied()
            .find(|word| word.strip_suffix(suffix).is_some_and(|design| design == self.design))
            .unwrap_or(DEFAULT_APP_ICON)
    }
}

/// The certificate trusted for the server in `server.url` where the system does not trust it: its SHA-256 fingerprint
/// (`immich_api::certificate`), set by a person's choice as they sign in, and replaced or removed with the server.
pub const CERTIFICATE_KEY: &str = "server.certificate_sha256";

/// Every setting, in display order.
pub const SETTINGS: &[Setting] = &[
    Setting { key: "server.url", kind: Kind::Text, description: "The Immich server; /api is added", default: "" },
    Setting { key: CERTIFICATE_KEY, kind: Kind::Text, description: "The SHA-256 fingerprint of the server's own certificate, trusted where the system does not trust it", default: "" },
    Setting { key: "mount.enabled", kind: Kind::Bool, description: "Show the library as a drive in the file manager", default: "false" },
    Setting { key: "mount.path", kind: Kind::Path, description: "Where the mount appears", default: "~/Verso" },
    Setting { key: "mount.name", kind: Kind::Choice(MOUNT_NAMES), description: "The drive's name in the sidebar", default: "verso" },
    Setting { key: "mount.at_login", kind: Kind::Bool, description: "Mount when the session starts", default: "true" },
    Setting { key: "mount.unmount_button", kind: Kind::Bool, description: "List the drive in Files' sidebar as a drive, with its unmount button; off, as a bookmark", default: "true" },
    Setting { key: "sections.photos", kind: Kind::Bool, description: "Show the Photos section", default: "true" },
    Setting { key: "sections.albums", kind: Kind::Bool, description: "Show the Albums section", default: "true" },
    Setting { key: "sections.people", kind: Kind::Bool, description: "Show the People section", default: "true" },
    Setting { key: "sections.places", kind: Kind::Bool, description: "Show the Places section", default: "true" },
    Setting { key: "sections.favorites", kind: Kind::Bool, description: "Show the Favorites section", default: "false" },
    Setting { key: "sections.archive", kind: Kind::Bool, description: "Show the Archive section", default: "false" },
    Setting { key: "grouping.photos", kind: Kind::Choice(GROUPING_CHOICES), description: "Day folders inside months", default: "atLeast500" },
    Setting { key: "grouping.albums", kind: Kind::Choice(GROUPING_CHOICES), description: "Year and month folders inside albums", default: "atLeast500" },
    Setting { key: "grouping.people", kind: Kind::Choice(GROUPING_CHOICES), description: "Year and month folders inside people", default: "atLeast500" },
    Setting { key: "grouping.places", kind: Kind::Choice(GROUPING_CHOICES), description: "Year and month folders inside cities", default: "atLeast500" },
    Setting { key: "grouping.favorites", kind: Kind::Choice(GROUPING_CHOICES), description: "Year and month folders inside favorites", default: "always" },
    Setting { key: "grouping.archive", kind: Kind::Choice(GROUPING_CHOICES), description: "Year and month folders inside the archive", default: "always" },
    Setting { key: "albums.layout", kind: Kind::Choice(&["year-prefix", "year-folders", "flat"]), description: "How album folders are named and grouped", default: "year-prefix" },
    Setting { key: "files.naming", kind: Kind::Choice(&["date-time", "original"]), description: "How files are named", default: "date-time" },
    Setting { key: "cache.limit", kind: Kind::Size, description: "The content cache's size limit", default: "10GB" },
    Setting { key: "uploads.enabled", kind: Kind::Bool, description: "Show the Upload folder, and upload what is copied into it", default: "true" },
    Setting { key: "uploads.folders", kind: Kind::Choice(&["ask", "timeline", "albums"]), description: "Folders copied into Upload", default: "ask" },
    Setting { key: "thumbnails.sharp", kind: Kind::Bool, description: "Also seed 1024 px thumbnails from the preview", default: "true" },
    Setting { key: "thumbnails.safety_net", kind: Kind::Bool, description: "Refuse thumbnailer reads of originals", default: "true" },
    Setting { key: "web.links", kind: Kind::Bool, description: "Open in Immich and Copy Immich Link", default: "true" },
    Setting { key: "tray.double_click", kind: Kind::Choice(&["gallery", "drive", "preferences"]), description: "What a double click on Verso's top bar icon opens", default: "gallery" },
    Setting { key: "tray.colour", kind: Kind::Bool, description: "Verso's top bar icon in colour: the lens's five colours, grey while the server cannot be reached", default: "false" },
    Setting { key: "app.icon", kind: Kind::Choice(APP_ICONS), description: "Verso's app icon in the light style: the picture on its print, its paper and its lens", default: DEFAULT_APP_ICON },
    Setting { key: "app.icon_dark", kind: Kind::Choice(APP_ICONS), description: "Verso's app icon in the dark style: the picture on its print, its paper and its lens", default: DEFAULT_APP_ICON_DARK },
    Setting { key: "crosslink.enabled", kind: Kind::Bool, description: "Show what other apps link to (Immich Crosslink)", default: "true" },
    Setting { key: "crosslink.gallery", kind: Kind::Bool, description: "Verso: take part as Verso Gallery, so other apps show items in it", default: "true" },
    Setting { key: "crosslink.drive", kind: Kind::Bool, description: "Verso: take part as Verso Drive, so other apps show items in Files while the drive is on", default: "true" },
    Setting { key: "crosslink.hidden", kind: Kind::Text, description: "Apps left out of Show in, by their desktop entry or bundle id, separated by ;", default: "" },
    Setting { key: "updates.check", kind: Kind::Bool, description: "Tell me when a new version is out", default: "false" },
    Setting { key: "credential.file", kind: Kind::Path, description: "Headless only: a 0600 file holding the credential", default: "" },
];

/// The cache sizes the settings windows offer, in decimal units as the file managers count; any other size set in
/// `config.toml` shows as itself.
pub const CACHE_SIZES: &[&str] = &["5GB", "10GB", "25GB", "50GB", "100GB"];

/// Where a setting is shown (ARCHITECTURE.md, "One layout for every settings window"). The apps lay their windows out
/// from this, each in its own platform's way; the Mac leaves out what means nothing there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pane {
    /// Opening at login, the drive's place and name, the cache, thumbnails and updates.
    General,
    /// The sections with their date folders, Upload, album and file names.
    Folders,
    /// Immich Crosslink, the apps that take part, and Immich's web app.
    OtherApps,
    /// Only in `config.toml` and `verso-service configure`: set another way (the server, by signing in; the apps left
    /// out of Show in, by each app's switch), for headless machines only, or a safeguard no window should offer.
    CommandLine,
}

/// Every setting's pane. A test keeps it whole: a setting added to the table without a place here fails it.
pub const PANES: &[(&str, Pane)] = &[
    ("server.url", Pane::CommandLine),
    // Set by trusting the certificate as one signs in; Verso's Account page shows it, and forgets it.
    (CERTIFICATE_KEY, Pane::CommandLine),
    // Verso Drive's switch, on its status page.
    ("mount.enabled", Pane::CommandLine),
    ("mount.path", Pane::General),
    ("mount.name", Pane::General),
    ("mount.at_login", Pane::General),
    ("mount.unmount_button", Pane::General),
    ("sections.photos", Pane::Folders),
    ("sections.albums", Pane::Folders),
    ("sections.people", Pane::Folders),
    ("sections.places", Pane::Folders),
    ("sections.favorites", Pane::Folders),
    ("sections.archive", Pane::Folders),
    ("grouping.photos", Pane::Folders),
    ("grouping.albums", Pane::Folders),
    ("grouping.people", Pane::Folders),
    ("grouping.places", Pane::Folders),
    ("grouping.favorites", Pane::Folders),
    ("grouping.archive", Pane::Folders),
    ("albums.layout", Pane::Folders),
    ("files.naming", Pane::Folders),
    ("cache.limit", Pane::General),
    ("uploads.enabled", Pane::Folders),
    ("uploads.folders", Pane::Folders),
    ("thumbnails.sharp", Pane::General),
    // Off, a thumbnailer may download every original it is shown, gigabytes for icons: no window offers that.
    ("thumbnails.safety_net", Pane::CommandLine),
    ("web.links", Pane::OtherApps),
    // Verso's, on its General page.
    ("tray.double_click", Pane::CommandLine),
    ("tray.colour", Pane::CommandLine),
    ("app.icon", Pane::CommandLine),
    ("app.icon_dark", Pane::CommandLine),
    ("crosslink.enabled", Pane::OtherApps),
    // Verso's own Crosslink page.
    ("crosslink.gallery", Pane::CommandLine),
    ("crosslink.drive", Pane::CommandLine),
    ("crosslink.hidden", Pane::CommandLine),
    ("updates.check", Pane::General),
    ("credential.file", Pane::CommandLine),
];

/// A setting's pane.
pub fn pane(key: &str) -> Option<Pane> {
    PANES.iter().find(|(placed, _)| *placed == key).map(|(_, pane)| *pane)
}

/// How a choice reads in a dialog, in every edition's app.
pub fn choice_label(word: &str) -> &str {
    match word {
        "never" => "Never",
        "atLeast500" => "From 500 Items",
        "always" => "Always",
        "year-prefix" => "Year in the Name (2023 - Trip)",
        "year-folders" => "Year Folders (2023/Trip)",
        "flat" => "Name Only (Trip)",
        "date-time" => "Date and Time Taken",
        "original" => "Original File Names",
        "ask" => "Ask Each Time",
        "timeline" => "Timeline Only",
        "albums" => "Make Albums",
        "immich-mount" | "immich-drive" | "immich" | "verso-drive" | "verso" => mount_name(word),
        "gallery" => "Verso",
        "drive" => "Verso Drive in Files",
        "preferences" => "Preferences",
        "mist" => "Mist",
        "sand" => "Sand",
        "dark" => "Dark",
        "paper" => "Paper",
        "frame" => "Frame",
        "slate" => "Slate",
        "sky" => "Sky",
        other => other,
    }
}

/// The name a `mount.name` choice shows in the sidebar. It names the drive only: the mount point is `mount.path`.
pub fn mount_name(choice: &str) -> &'static str {
    match choice {
        "immich-drive" => "Immich Drive",
        "immich" => "Immich",
        "verso-drive" => "Verso Drive",
        "verso" => "Verso",
        "immich-mount" => "Immich Mount",
        _ => DEFAULT_MOUNT_NAME,
    }
}

/// Every name the drive may have, so a sidebar entry under any of them is known as ours.
pub fn mount_names() -> impl Iterator<Item = &'static str> {
    MOUNT_NAMES.iter().map(|choice| mount_name(choice))
}

/// A setting's default for the product this program is (`crate::product`): its own where it has one.
pub fn default_value(setting: &Setting) -> &'static str {
    default_value_for(setting, crate::product::current())
}

fn default_value_for(setting: &Setting, product: &crate::product::Product) -> &'static str {
    product.default_for(setting.key).unwrap_or(setting.default)
}

/// The words a choice setting offers in this product's windows: the drive's names are each product's own.
pub fn choices(setting: &Setting) -> &'static [&'static str] {
    match setting.kind {
        Kind::Choice(_) if setting.key == "mount.name" => crate::product::current().drive_names,
        // A Flatpak has no drive to open.
        Kind::Choice(_) if setting.key == "tray.double_click" && crate::product::current().sandboxed => &["gallery", "preferences"],
        Kind::Choice(words) => words,
        _ => &[],
    }
}

/// Why a setting could not be read or changed.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SettingError {
    #[error("unknown setting `{0}` (see `verso-service configure keys`)")]
    UnknownKey(String),
    #[error("`{key}` must be {expected}, not `{given}`")]
    InvalidValue { key: String, expected: String, given: String },
    #[error("the config file is not valid TOML: {0}")]
    Unparsable(String),
}

/// Look a setting up by key.
pub fn setting(key: &str) -> Result<&'static Setting, SettingError> {
    SETTINGS.iter().find(|setting| setting.key == key).ok_or_else(|| SettingError::UnknownKey(key.to_string()))
}

/// Check that `given` is a valid value for `key`.
pub fn validate(key: &str, given: &str) -> Result<(), SettingError> {
    let setting = setting(key)?;
    let invalid = |expected: String| SettingError::InvalidValue { key: key.to_string(), expected, given: given.to_string() };
    if key == CERTIFICATE_KEY && immich_api::CertificatePin::parse(given).is_none() {
        return Err(invalid("a SHA-256 fingerprint: 64 hexadecimal digits, in pairs separated by colons or not".into()));
    }
    match setting.kind {
        Kind::Bool => given.parse::<bool>().map(|_| ()).map_err(|_| invalid("`true` or `false`".into())),
        Kind::Text | Kind::Path => if given.trim().is_empty() { Err(invalid("non-empty".into())) } else { Ok(()) },
        Kind::Size => parse_size(given).map(|_| ()).ok_or_else(|| invalid("a size such as `10GB` or `500MiB`".into())),
        Kind::Choice(choices) => if choices.contains(&given) { Ok(()) } else { Err(invalid(format!("one of {}", choices.join(", ")))) },
    }
}

/// Parse a size: a whole number of bytes, or a number with a decimal unit (`KB`, `MB`, `GB`, `TB`, as file managers
/// count) or a binary one (`KiB`, `MiB`, `GiB`, `TiB`).
pub fn parse_size(text: &str) -> Option<u64> {
    let text = text.trim();
    let units = [
        ("TiB", 1u64 << 40),
        ("GiB", 1 << 30),
        ("MiB", 1 << 20),
        ("KiB", 1 << 10),
        ("TB", 1_000_000_000_000),
        ("GB", 1_000_000_000),
        ("MB", 1_000_000),
        ("KB", 1_000),
        ("B", 1),
    ];
    for (unit, multiplier) in units {
        if let Some(number) = text.strip_suffix(unit) {
            return number.trim().parse::<u64>().ok()?.checked_mul(multiplier);
        }
    }
    text.parse().ok()
}

/// The effective settings, typed.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub server_url: Option<String>,
    /// The certificate trusted for that server where the system does not trust it ([`CERTIFICATE_KEY`]).
    pub server_certificate: Option<immich_api::CertificatePin>,
    pub mount_path: String,
    /// Whether the library is mounted as a drive at all (`mount.enabled`): Verso's drive is off until switched on.
    pub mount_enabled: bool,
    /// The drive's name in the sidebar (`mount.name`).
    pub mount_name: &'static str,
    pub mount_at_login: bool,
    /// GNOME Files lists the drive as a drive, with an unmount button; off, as a bookmark (`mount.unmount_button`).
    pub mount_unmount_button: bool,
    pub show_photos: bool,
    pub show_albums: bool,
    pub show_people: bool,
    pub show_places: bool,
    pub show_favorites: bool,
    pub show_archive: bool,
    pub grouping_photos: GroupingMode,
    pub grouping_albums: GroupingMode,
    pub grouping_people: GroupingMode,
    pub grouping_places: GroupingMode,
    pub grouping_favorites: GroupingMode,
    pub grouping_archive: GroupingMode,
    pub album_layout: AlbumLayout,
    pub file_naming: FileNaming,
    pub cache_limit_bytes: u64,
    pub uploads_enabled: bool,
    /// What a folder copied into Upload becomes besides its timeline uploads (`uploads.folders`).
    pub upload_folders: FolderChoice,
    pub sharp_thumbnails: bool,
    pub thumbnail_safety_net: bool,
    /// Linux packages from the download page: tell of a newer release (ARCHITECTURE.md, "Updates on Linux").
    pub update_check: bool,
    /// Immich Crosslink: show in the file manager what another app links to, and offer the other apps (ROADMAP.md,
    /// "Open in Immich, and links between apps").
    pub crosslink_enabled: bool,
    /// Open in Immich and Copy Immich Link in the file managers' menus (Immich Crosslink, "Copying links").
    pub web_links: bool,
    /// What a double click on Verso's top bar icon opens: `gallery`, `drive` (in Files) or `preferences`.
    pub tray_double_click: String,
    /// Verso's top bar icon in colour rather than in the desktop's one colour.
    pub tray_colour: bool,
    /// The app icon's look in the desktop's light style, one of [`APP_ICONS`] (`app.icon`).
    pub app_icon: &'static str,
    /// The app icon's look in the desktop's dark style, one of [`APP_ICONS`] (`app.icon_dark`).
    pub app_icon_dark: &'static str,
    /// The apps left out of Show in *app*, by desktop entry or bundle id, separated by `;`.
    pub crosslink_hidden: String,
    /// Verso's participants, Verso Gallery and Verso Drive, each announced while its switch is on (`participants`).
    pub crosslink_gallery: bool,
    pub crosslink_drive: bool,
    pub credential_file: Option<String>,
}

impl Config {
    /// Read a config file's text. Unknown keys are ignored; a known key with an invalid value is an error.
    pub fn from_toml(text: &str) -> Result<Config, SettingError> {
        Config::from_toml_for(text, crate::product::current())
    }

    /// [`Config::from_toml`] with `product`'s defaults.
    pub fn from_toml_for(text: &str, product: &crate::product::Product) -> Result<Config, SettingError> {
        let document: DocumentMut = text.parse().map_err(|error: toml_edit::TomlError| SettingError::Unparsable(error.to_string()))?;
        let effective = |key: &str| -> Result<String, SettingError> {
            match read_value(&document, key).filter(|_| product.shows(key)) {
                Some(given) => {
                    validate(key, &given)?;
                    Ok(given)
                }
                None => Ok(default_value_for(setting(key)?, product).to_string()),
            }
        };
        let flag = |key: &str| -> Result<bool, SettingError> { Ok(effective(key)? == "true") };
        let optional = |key: &str| -> Result<Option<String>, SettingError> {
            let given = effective(key)?;
            Ok(if given.is_empty() { None } else { Some(given) })
        };
        Ok(Config {
            server_url: optional("server.url")?,
            server_certificate: optional(CERTIFICATE_KEY)?.and_then(|text| immich_api::CertificatePin::parse(&text)),
            mount_path: effective("mount.path")?,
            mount_enabled: flag("mount.enabled")?,
            mount_name: mount_name(&effective("mount.name")?),
            mount_at_login: flag("mount.at_login")?,
            mount_unmount_button: flag("mount.unmount_button")?,
            show_photos: flag("sections.photos")?,
            show_albums: flag("sections.albums")?,
            show_people: flag("sections.people")?,
            show_places: flag("sections.places")?,
            show_favorites: flag("sections.favorites")?,
            show_archive: flag("sections.archive")?,
            grouping_photos: grouping(&effective("grouping.photos")?),
            grouping_albums: grouping(&effective("grouping.albums")?),
            grouping_people: grouping(&effective("grouping.people")?),
            grouping_places: grouping(&effective("grouping.places")?),
            grouping_favorites: grouping(&effective("grouping.favorites")?),
            grouping_archive: grouping(&effective("grouping.archive")?),
            album_layout: match effective("albums.layout")?.as_str() {
                "year-folders" => AlbumLayout::YearFolders,
                "flat" => AlbumLayout::Flat,
                _ => AlbumLayout::YearPrefix,
            },
            file_naming: if effective("files.naming")? == "original" { FileNaming::Original } else { FileNaming::DateTime },
            cache_limit_bytes: parse_size(&effective("cache.limit")?).unwrap_or(10 << 30),
            uploads_enabled: flag("uploads.enabled")?,
            upload_folders: FolderChoice::from_setting(&effective("uploads.folders")?),
            sharp_thumbnails: flag("thumbnails.sharp")?,
            thumbnail_safety_net: flag("thumbnails.safety_net")?,
            update_check: flag("updates.check")?,
            crosslink_enabled: flag("crosslink.enabled")?,
            web_links: flag("web.links")?,
            tray_double_click: effective("tray.double_click")?,
            tray_colour: flag("tray.colour")?,
            app_icon: {
                let look = effective("app.icon")?;
                APP_ICONS.iter().copied().find(|known| *known == look).unwrap_or(DEFAULT_APP_ICON)
            },
            app_icon_dark: {
                let look = effective("app.icon_dark")?;
                APP_ICONS.iter().copied().find(|known| *known == look).unwrap_or(DEFAULT_APP_ICON_DARK)
            },
            crosslink_hidden: optional("crosslink.hidden")?.unwrap_or_default(),
            crosslink_gallery: flag("crosslink.gallery")?,
            crosslink_drive: flag("crosslink.drive")?,
            credential_file: optional("credential.file")?,
        })
    }
}

fn grouping(choice: &str) -> GroupingMode {
    match choice {
        "never" => GroupingMode::Never,
        "always" => GroupingMode::Always,
        _ => GroupingMode::AtLeast500,
    }
}

/// The value stored for `key`, as text, if the file sets it.
pub fn read_value(document: &DocumentMut, key: &str) -> Option<String> {
    let (table, leaf) = key.split_once('.')?;
    let item = document.get(table)?.get(leaf)?;
    if let Some(flag) = item.as_bool() {
        return Some(flag.to_string());
    }
    item.as_str().map(str::to_string)
}

/// The values a config file's text sets explicitly, by key. Keys the file does not set are absent.
pub fn stored_values(text: &str) -> Result<std::collections::HashMap<&'static str, String>, SettingError> {
    let document: DocumentMut = text.parse().map_err(|error: toml_edit::TomlError| SettingError::Unparsable(error.to_string()))?;
    Ok(SETTINGS.iter().filter_map(|setting| read_value(&document, setting.key).map(|value| (setting.key, value))).collect())
}

/// Set `key` to `given` in a config file's text, keeping everything else as it was.
pub fn set_value(text: &str, key: &str, given: &str) -> Result<String, SettingError> {
    validate(key, given)?;
    let mut document: DocumentMut = text.parse().map_err(|error: toml_edit::TomlError| SettingError::Unparsable(error.to_string()))?;
    let (table_name, leaf) = key.split_once('.').expect("every setting key is dotted");
    if document.get("version").is_none() {
        document["version"] = value(CONFIG_FORMAT_VERSION);
    }
    if !document.contains_table(table_name) {
        document[table_name] = Item::Table(Table::new());
    }
    document[table_name][leaf] = match setting(key)?.kind {
        Kind::Bool => value(given == "true"),
        _ => value(given),
    };
    Ok(document.to_string())
}

/// Remove `key` from a config file's text, so its default applies again.
pub fn unset_value(text: &str, key: &str) -> Result<String, SettingError> {
    setting(key)?;
    let mut document: DocumentMut = text.parse().map_err(|error: toml_edit::TomlError| SettingError::Unparsable(error.to_string()))?;
    let (table_name, leaf) = key.split_once('.').expect("every setting key is dotted");
    if let Some(table) = document.get_mut(table_name).and_then(Item::as_table_mut) {
        table.remove(leaf);
    }
    Ok(document.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verso_has_its_own_defaults_and_its_drive_is_off_until_switched_on() {
        use crate::product::{IMMICH_MOUNT, VERSO};
        let verso = Config::from_toml_for("", &VERSO).unwrap();
        assert_eq!((verso.mount_enabled, verso.mount_path.as_str(), verso.mount_name), (false, "~/Verso", "Verso"));
        assert!(!verso.update_check);
        let mount = Config::from_toml_for("", &IMMICH_MOUNT).unwrap();
        assert_eq!((mount.mount_enabled, mount.mount_path.as_str(), mount.mount_name), (true, "~/Immich", "Immich Mount"));
        assert!(Config::from_toml_for("[mount]\nenabled = true\n", &VERSO).unwrap().mount_enabled);
        // What Verso hides is Verso's, whatever an earlier version stored: its drive starts at login while it is on.
        assert!(Config::from_toml_for("[mount]\nat_login = false\n", &VERSO).unwrap().mount_at_login);
        assert!(!Config::from_toml_for("[mount]\nat_login = false\n", &IMMICH_MOUNT).unwrap().mount_at_login);
        for (key, value) in VERSO.defaults.iter().chain(IMMICH_MOUNT.defaults) {
            assert_eq!(validate(key, value), Ok(()), "{key}");
        }
        for name in VERSO.drive_names.iter().chain(IMMICH_MOUNT.drive_names) {
            assert_eq!(validate("mount.name", name), Ok(()), "{name}");
        }
    }

    #[test]
    fn the_certificate_trusted_for_the_server_is_a_fingerprint() {
        let pin = immich_api::CertificatePin::of(b"a certificate");
        assert!(set_value("", CERTIFICATE_KEY, "trust me").is_err());
        assert!(set_value("", CERTIFICATE_KEY, "AB:CD").is_err());
        let text = set_value("[server]\nurl = \"https://photos.home.arpa\"\n", CERTIFICATE_KEY, &pin.to_string()).unwrap();
        assert_eq!(Config::from_toml(&text).unwrap().server_certificate, Some(pin));
        let written_without_colons = set_value("", CERTIFICATE_KEY, &pin.to_string().replace(':', "").to_lowercase()).unwrap();
        assert_eq!(Config::from_toml(&written_without_colons).unwrap().server_certificate, Some(pin));
        assert_eq!(Config::from_toml(&unset_value(&text, CERTIFICATE_KEY).unwrap()).unwrap().server_certificate, None);
        assert_eq!(Config::from_toml("").unwrap().server_certificate, None);
    }

    #[test]
    fn every_default_is_valid() {
        for setting in SETTINGS.iter().filter(|setting| !setting.default.is_empty()) {
            assert_eq!(validate(setting.key, setting.default), Ok(()), "{}", setting.key);
        }
    }

    #[test]
    fn an_empty_file_gives_the_defaults() {
        let config = Config::from_toml("").unwrap();
        assert_eq!(config.mount_path, "~/Verso");
        assert_eq!(config.mount_name, "Verso");
        assert!(!config.mount_enabled, "Verso Drive is off until switched on");
        assert_eq!(config.album_layout, AlbumLayout::YearPrefix);
        assert_eq!(config.file_naming, FileNaming::DateTime);
        assert_eq!(config.grouping_photos, GroupingMode::AtLeast500);
        assert!(!config.show_archive && !config.show_favorites, "the archive and favorites are shown only when asked for");
        assert_eq!((config.grouping_archive, config.grouping_favorites), (GroupingMode::Always, GroupingMode::Always));
        assert_eq!(config.cache_limit_bytes, 10_000_000_000, "10 GB, as Files counts");
        assert!(config.server_url.is_none());
        assert_eq!(config.upload_folders, FolderChoice::Ask, "a folder copied into Upload asks before it makes albums");
    }

    #[test]
    fn the_drive_is_named_by_a_choice_and_the_mount_point_stays() {
        let config = Config::from_toml("[mount]\nname = \"immich\"\n").unwrap();
        assert_eq!((config.mount_name, config.mount_path.as_str()), ("Immich", "~/Verso"));
        assert_eq!(Config::from_toml("[mount]\nname = \"immich-drive\"\n").unwrap().mount_name, "Immich Drive");
        assert_eq!(choice_label("immich-mount"), "Immich Mount");
        assert!(Config::from_toml("[mount]\nname = \"Photos\"\n").is_err());
        assert_eq!(mount_names().collect::<Vec<_>>(), ["Immich Mount", "Immich Drive", "Immich", "Verso Drive", "Verso"]);
    }

    #[test]
    fn the_app_icon_is_mist_by_day_and_by_night_until_others_are_chosen() {
        let config = Config::from_toml("").unwrap();
        assert_eq!((config.app_icon, config.app_icon_dark), ("mist", "mist-night"));
        let chosen = Config::from_toml("[app]\nicon = \"sand\"\nicon_dark = \"slate-night-graphite\"\n").unwrap();
        assert_eq!((chosen.app_icon, chosen.app_icon_dark), ("sand", "slate-night-graphite"));
        assert!(Config::from_toml("[app]\nicon = \"neon\"\n").is_err());
        assert!(Config::from_toml("[app]\nicon_dark = \"sand-dusk\"\n").is_err());
        assert_eq!(APP_ICONS[0], DEFAULT_APP_ICON);
        assert_eq!(APP_ICONS.len(), APP_ICON_DESIGNS.len() * 4, "every design in four looks");
        for design in APP_ICON_DESIGNS {
            assert_ne!(choice_label(design), *design, "{design} has no name");
        }
        // The Flatpak offers no choice, and reads none.
        let flatpak = Config::from_toml_for("[app]\nicon = \"sand\"\nicon_dark = \"sky\"\n", &crate::product::VERSO_FLATPAK).unwrap();
        assert_eq!((flatpak.app_icon, flatpak.app_icon_dark), ("mist", "mist-night"));
    }

    #[test]
    fn a_look_is_its_design_its_paper_and_its_lens() {
        for word in APP_ICONS {
            assert_eq!(AppIconLook::parse(word).word(), *word);
        }
        assert_eq!(AppIconLook::parse("sand"), AppIconLook { design: "sand", night: false, graphite: false });
        assert_eq!(AppIconLook::parse("dark-night-graphite"), AppIconLook { design: "dark", night: true, graphite: true });
        assert_eq!(AppIconLook::parse("sky-graphite"), AppIconLook { design: "sky", night: false, graphite: true });
        assert_eq!(AppIconLook::parse("neon-night").word(), DEFAULT_APP_ICON, "a word that names no look is Mist's");
        assert_eq!(AppIconLook { design: "frame", night: true, graphite: false }.word(), "frame-night");
    }

    #[test]
    fn unknown_keys_are_ignored_and_invalid_values_are_reported() {
        assert!(Config::from_toml("[old]\nthing = 1\n").is_ok());
        let invalid = Config::from_toml("[albums]\nlayout = \"sideways\"\n");
        assert!(matches!(invalid, Err(SettingError::InvalidValue { .. })));
    }

    #[test]
    fn setting_a_value_keeps_comments_and_unsetting_restores_the_default() {
        let original = "# my notes\n[server]\nurl = \"https://photos.example.org\" # home\n";
        let updated = set_value(original, "albums.layout", "flat").unwrap();
        assert!(updated.contains("# my notes"));
        assert!(updated.contains("# home"));
        assert_eq!(Config::from_toml(&updated).unwrap().album_layout, AlbumLayout::Flat);
        let restored = unset_value(&updated, "albums.layout").unwrap();
        assert_eq!(Config::from_toml(&restored).unwrap().album_layout, AlbumLayout::YearPrefix);
    }

    #[test]
    fn values_are_validated_before_writing() {
        assert!(matches!(set_value("", "files.naming", "camera"), Err(SettingError::InvalidValue { .. })));
        assert!(matches!(set_value("", "no.such", "x"), Err(SettingError::UnknownKey(_))));
        assert!(set_value("", "mount.at_login", "false").unwrap().contains("at_login = false"));
    }

    #[test]
    fn every_setting_has_one_pane_and_every_pane_entry_a_setting() {
        for setting in SETTINGS {
            assert_eq!(PANES.iter().filter(|(key, _)| *key == setting.key).count(), 1, "{} needs exactly one pane", setting.key);
        }
        for (key, _) in PANES {
            assert!(SETTINGS.iter().any(|setting| setting.key == *key), "{key} is placed but not a setting");
        }
        for size in CACHE_SIZES {
            assert!(validate("cache.limit", size).is_ok(), "{size}");
        }
    }

    #[test]
    fn sizes_parse_with_decimal_units() {
        assert_eq!(parse_size("10GB"), Some(10_000_000_000));
        assert_eq!(parse_size("500 MB"), Some(500_000_000));
        assert_eq!(parse_size("1TB"), Some(1_000_000_000_000));
    }

    #[test]
    fn sizes_parse_with_binary_units() {
        assert_eq!(parse_size("10GiB"), Some(10 << 30));
        assert_eq!(parse_size("500 MiB"), Some(500 << 20));
        assert_eq!(parse_size("4096"), Some(4096));
        assert_eq!(parse_size("ten"), None);
    }
}
