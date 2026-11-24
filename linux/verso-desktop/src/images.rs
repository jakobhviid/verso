//! Thumbnails and previews: fetched from Immich once, kept on disk per account, and decoded off the main thread into
//! RGBA that either toolkit turns into a texture. Originals are never fetched for a grid (principle 2).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use immich_api::content::ThumbnailSize;
use immich_api::Client;
use tokio::sync::Semaphore;

/// A decoded picture: straight RGBA, row by row, four bytes a pixel.
#[derive(Clone, PartialEq, Eq)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for Picture {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "Picture({}x{})", self.width, self.height)
    }
}

/// Decode WebP, JPEG or PNG bytes, scaled down so the longer side is at most `max_side` when one is given.
pub fn decode(bytes: &[u8], max_side: Option<u32>) -> Result<Picture, String> {
    let mut image = image::load_from_memory(bytes).map_err(|error| format!("cannot read the picture: {error}"))?;
    if let Some(max_side) = max_side {
        if image.width().max(image.height()) > max_side {
            image = image.resize(max_side, max_side, image::imageops::FilterType::Triangle);
        }
    }
    let rgba = image.into_rgba8();
    Ok(Picture { width: rgba.width(), height: rgba.height(), rgba: rgba.into_raw() })
}

/// Decode WebP, JPEG or PNG bytes, scaled to fit within `width` by `height`, its shape kept.
pub fn decode_within(bytes: &[u8], width: u32, height: u32) -> Result<Picture, String> {
    let image = image::load_from_memory(bytes).map_err(|error| format!("cannot read the picture: {error}"))?;
    let rgba = image.resize(width.max(1), height.max(1), image::imageops::FilterType::Triangle).into_rgba8();
    Ok(Picture { width: rgba.width(), height: rgba.height(), rgba: rgba.into_raw() })
}

/// Which picture of an Asset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// 250 pixels on the short side, WebP: the grid's.
    Thumbnail,
    /// 1440 pixels on the short side, JPEG: the viewer's.
    Preview,
    /// A person's face, by the person's id.
    Person,
}

impl Kind {
    fn folder(self) -> &'static str {
        match self {
            Kind::Thumbnail => "thumbnails",
            Kind::Preview => "previews",
            Kind::Person => "people",
        }
    }

    /// How much of this kind the cache keeps before the least recently used go.
    fn budget(self) -> u64 {
        match self {
            Kind::Thumbnail => 1_000_000_000,
            Kind::Preview => 500_000_000,
            Kind::Person => 100_000_000,
        }
    }
}

/// The account's picture cache. Cheap to clone; network fetches are limited to a few at a time, so a fast scroll
/// does not queue hundreds of requests ahead of what is on screen.
#[derive(Clone)]
pub struct Cache {
    directory: PathBuf,
    client: Client,
    fetches: Arc<Semaphore>,
}

impl Cache {
    pub fn new(directory: PathBuf, client: Client) -> Cache {
        Cache { directory, client, fetches: Arc::new(Semaphore::new(6)) }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Where a picture is kept: by its id, and by its version where there is one (the photo's ThumbHash, which
    /// changes when Immich makes its pictures anew, after an edit), so an edited photo never shows an old picture.
    fn path(&self, kind: Kind, id: &str, version: Option<&str>) -> Option<PathBuf> {
        // Ids are Immich's UUIDs; anything else never becomes a path.
        if !is_id(id) {
            return None;
        }
        let name = match version.filter(|version| !version.is_empty()) {
            Some(version) => format!("{id}.{}", short_hash(version)),
            None => id.to_owned(),
        };
        Some(self.directory.join(kind.folder()).join(name))
    }

    /// The picture's bytes: from the disk cache, else from Immich (then kept).
    pub async fn bytes(&self, kind: Kind, id: &str, version: Option<&str>) -> Result<Vec<u8>, String> {
        let path = self.path(kind, id, version).ok_or_else(|| format!("not an Immich id: {id}"))?;
        if let Ok(bytes) = tokio::fs::read(&path).await {
            // Touch it, so the least recently used go first when the cache is trimmed.
            let _ = std::fs::File::options().append(true).open(&path).and_then(|file| file.set_modified(std::time::SystemTime::now()));
            return Ok(bytes);
        }
        let _permit = self.fetches.acquire().await.map_err(|error| error.to_string())?;
        let bytes = match kind {
            // As Immich's web app shows them, edits applied.
            Kind::Thumbnail => self.client.edited_thumbnail(id, ThumbnailSize::Thumbnail).await.map(|(bytes, _)| bytes),
            Kind::Preview => self.client.edited_thumbnail(id, ThumbnailSize::Preview).await.map(|(bytes, _)| bytes),
            Kind::Person => self.client.person_thumbnail(id).await.map(|media| media.bytes),
        }
        .map_err(|error| error.to_string())?;
        if let Some(folder) = path.parent() {
            let _ = tokio::fs::create_dir_all(folder).await;
            let temporary = partial_path(&path);
            if tokio::fs::write(&temporary, &bytes).await.is_ok() {
                let _ = settle(&temporary, &path);
            }
        }
        Ok(bytes.to_vec())
    }

    /// The picture, decoded off the async threads. `max_side` scales it down first.
    pub async fn picture(&self, kind: Kind, id: &str, version: Option<&str>, max_side: Option<u32>) -> Result<Picture, String> {
        let bytes = self.bytes(kind, id, version).await?;
        tokio::task::spawn_blocking(move || decode(&bytes, max_side)).await.map_err(|error| error.to_string())?
    }

    /// Trim each kind to its budget, least recently used first, and the videos and originals played and opened.
    /// Run now and then, off the main thread.
    pub fn trim(&self) {
        for kind in [Kind::Thumbnail, Kind::Preview, Kind::Person] {
            trim_folder(&self.directory.join(kind.folder()), kind.budget());
        }
        trim_folder(&self.directory.join(VIDEOS), 2_000_000_000);
        trim_folder(&self.directory.join(ORIGINALS), 2_000_000_000);
    }

    /// Forget the thumbnails and previews of these photos, every version (after a photo was turned, say).
    pub fn forget_pictures(&self, ids: &[String]) {
        for kind in [Kind::Thumbnail, Kind::Preview] {
            let folder = self.directory.join(kind.folder());
            let Ok(entries) = std::fs::read_dir(&folder) else { continue };
            for entry in entries.filter_map(Result::ok) {
                let name = entry.file_name().to_string_lossy().into_owned();
                let id = name.split('.').next().unwrap_or_default();
                if ids.iter().any(|forgotten| forgotten == id) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }

    /// Forget every picture, video and original of these photos (the Locked Folder's, once it is left or locked).
    pub fn forget(&self, ids: &[String]) {
        self.forget_pictures(ids);
        for id in ids.iter().filter(|id| is_id(id)) {
            let _ = std::fs::remove_file(self.directory.join(VIDEOS).join(format!("{id}.mp4")));
            let _ = std::fs::remove_dir_all(self.directory.join(ORIGINALS).join(id));
        }
    }
}

/// Where played videos are kept, by id, and opened originals, in a folder per id with the original's name.
pub const VIDEOS: &str = "videos";
pub const ORIGINALS: &str = "originals";

/// A partial file beside `path`, its name its own, so two writers of one file never write into each other's.
pub fn partial_path(path: &Path) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    path.with_file_name(format!(".{name}.{}-{}.part", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)))
}

/// An Immich id: a UUID's characters only, so it never names a path elsewhere.
fn is_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|character| character.is_ascii_hexdigit() || character == '-')
}

/// The first eight hex digits of a text's SHA-1, to tell versions apart in a file name.
fn short_hash(text: &str) -> String {
    use sha1::{Digest, Sha1};
    Sha1::digest(text.as_bytes()).iter().take(4).map(|byte| format!("{byte:02x}")).collect()
}

/// Put a finished partial file at `target` unless something is there already: `Ok(true)` when it was put there,
/// `Ok(false)` when `target` was taken (the partial file stays, for the caller to try another name or drop). Never
/// replaces a file. A hard link does it at once where the file system has them; elsewhere (FAT and exFAT sticks, most
/// network shares) the target is made new and the bytes copied.
pub fn place(partial: &Path, target: &Path) -> std::io::Result<bool> {
    match std::fs::hard_link(partial, target) {
        Ok(()) => {
            std::fs::remove_file(partial)?;
            return Ok(true);
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(_) => {}
    }
    let mut made = match std::fs::OpenOptions::new().write(true).create_new(true).open(target) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(error) => return Err(error),
    };
    let copied = std::fs::File::open(partial).and_then(|mut source| std::io::copy(&mut source, &mut made)).and_then(|_| made.sync_all());
    if let Err(error) = copied {
        drop(made);
        let _ = std::fs::remove_file(target);
        return Err(error);
    }
    std::fs::remove_file(partial)?;
    Ok(true)
}

/// Move a finished partial file to `target`, unless another writer got there first (then theirs is kept, and this
/// one goes). Never replaces a file.
pub fn settle(partial: &Path, target: &Path) -> std::io::Result<()> {
    match place(partial, target) {
        Ok(true) => Ok(()),
        Ok(false) => std::fs::remove_file(partial),
        Err(error) => {
            let _ = std::fs::remove_file(partial);
            Err(error)
        }
    }
}

/// Trim a folder of files, or of folders (the originals, one folder per photo), to `budget` bytes, the least
/// recently changed first.
fn trim_folder(folder: &Path, budget: u64) {
    let Ok(entries) = std::fs::read_dir(folder) else { return };
    let size_of = |path: &Path, metadata: &std::fs::Metadata| -> u64 {
        if metadata.is_dir() {
            std::fs::read_dir(path).map(|inside| inside.filter_map(Result::ok).filter_map(|entry| entry.metadata().ok()).filter(|metadata| metadata.is_file()).map(|metadata| metadata.len()).sum()).unwrap_or(0)
        } else {
            metadata.len()
        }
    };
    let mut items: Vec<(std::time::SystemTime, u64, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            let path = entry.path();
            (metadata.is_file() || metadata.is_dir()).then(|| (metadata.modified().unwrap_or(std::time::UNIX_EPOCH), size_of(&path, &metadata), path))
        })
        .collect();
    let mut total: u64 = items.iter().map(|(_, size, _)| size).sum();
    items.sort_by_key(|(modified, _, _)| *modified);
    for (_, size, path) in items {
        if total <= budget {
            break;
        }
        let removed = if path.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
        if removed.is_ok() {
            total -= size;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoding_scales_down_to_the_longer_side() {
        let mut png = Vec::new();
        image::RgbaImage::from_pixel(400, 200, image::Rgba([10, 20, 30, 255]))
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let picture = decode(&png, Some(100)).unwrap();
        assert_eq!((picture.width, picture.height), (100, 50));
        assert_eq!(&picture.rgba[..4], &[10, 20, 30, 255]);
        assert_eq!(decode(&png, None).unwrap().width, 400);
        assert!(decode(b"not a picture", None).is_err());
    }

    #[test]
    fn only_immich_ids_become_paths() {
        let cache = Cache::new(PathBuf::from("/cache"), Client::new("http://localhost:2283", None, "test").unwrap());
        assert_eq!(
            cache.path(Kind::Thumbnail, "2d6e3655-50dd-40f5-b8cf-f7d3f56aa95e", None),
            Some(PathBuf::from("/cache/thumbnails/2d6e3655-50dd-40f5-b8cf-f7d3f56aa95e"))
        );
        assert_eq!(cache.path(Kind::Preview, "../../etc/passwd", None), None);
        assert_eq!(cache.path(Kind::Preview, "", Some("x")), None);
        let first = cache.path(Kind::Thumbnail, "2d6e3655", Some("HQgKDQIDSW2VuGdnh3p3h/+a0a8p")).unwrap();
        let edited = cache.path(Kind::Thumbnail, "2d6e3655", Some("FwgKFQS/eoOIKIeIZneYh4pfpPkl")).unwrap();
        assert_ne!(first, edited, "a new ThumbHash is a new file");
        assert!(first.file_name().unwrap().to_string_lossy().starts_with("2d6e3655."), "{first:?}");
    }

    #[test]
    fn a_partial_file_never_replaces_a_finished_one() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("IMG_1.jpg");
        let (first, second) = (partial_path(&target), partial_path(&target));
        assert_ne!(first, second, "two writers, two partial files");
        std::fs::write(&first, b"first").unwrap();
        std::fs::write(&second, b"second").unwrap();
        settle(&first, &target).unwrap();
        settle(&second, &target).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"first", "the file first finished is kept");
        assert!(!first.exists() && !second.exists());
    }

    #[test]
    fn placing_never_replaces_and_says_when_the_name_was_taken() {
        let directory = tempfile::tempdir().unwrap();
        let (partial, target) = (directory.path().join("p"), directory.path().join("IMG_1.jpg"));
        std::fs::write(&partial, b"new").unwrap();
        std::fs::write(&target, b"old").unwrap();
        assert!(!place(&partial, &target).unwrap(), "taken");
        assert_eq!(std::fs::read(&target).unwrap(), b"old");
        assert!(partial.exists(), "kept for another name");
        let other = directory.path().join("IMG_1 (2).jpg");
        assert!(place(&partial, &other).unwrap());
        assert_eq!(std::fs::read(&other).unwrap(), b"new");
        assert!(!partial.exists());
    }

    #[test]
    fn forgetting_pictures_takes_every_version_and_leaves_others() {
        let directory = tempfile::tempdir().unwrap();
        let cache = Cache::new(directory.path().to_path_buf(), Client::new("http://localhost:2283", None, "test").unwrap());
        let folder = directory.path().join("thumbnails");
        std::fs::create_dir_all(&folder).unwrap();
        for name in ["aaaa", "aaaa.12345678", "bbbb.12345678"] {
            std::fs::write(folder.join(name), b"x").unwrap();
        }
        cache.forget_pictures(&["aaaa".to_owned()]);
        let left: Vec<String> = std::fs::read_dir(&folder).unwrap().map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(left, ["bbbb.12345678"]);
    }

    #[test]
    fn trimming_removes_the_least_recently_used_first() {
        let directory = tempfile::tempdir().unwrap();
        for (index, name) in ["old", "middle", "new"].iter().enumerate() {
            let path = directory.path().join(name);
            std::fs::write(&path, vec![0u8; 100]).unwrap();
            let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000 + index as u64 * 1000);
            std::fs::File::options().append(true).open(&path).unwrap().set_modified(when).unwrap();
        }
        trim_folder(directory.path(), 150);
        assert!(!directory.path().join("old").exists());
        assert!(!directory.path().join("middle").exists());
        assert!(directory.path().join("new").exists());
    }
}
