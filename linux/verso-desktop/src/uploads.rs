//! Importing files: each is checked by its checksum first, so a photo the library has is never sent twice, then
//! uploaded unchanged (principle 3). A duplicate waiting in the trash is restored, as adding it again asks for it.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use immich_api::{Client, Sha1Checksum, UploadCheck, UploadOutcome};
use verso_linux::i18n::tr;

use crate::notifications::File;

/// What happened to one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Imported {
    /// A new photo or video, by id.
    New(String),
    /// The library had it already.
    AlreadyThere(String),
    /// It was in the trash, and is back.
    Restored(String),
    /// Immich does not take it, with its reason.
    Refused(String),
}

impl Imported {
    /// The Asset it is now, where there is one.
    pub fn asset_id(&self) -> Option<&str> {
        match self {
            Imported::New(id) | Imported::AlreadyThere(id) | Imported::Restored(id) => Some(id),
            Imported::Refused(_) => None,
        }
    }
}

/// The times Immich wants with an upload: when the file was made and changed, from the file itself. Immich reads the
/// photo's own date from its metadata and prefers that.
fn file_times(path: &Path) -> (DateTime<Utc>, DateTime<Utc>) {
    let metadata = std::fs::metadata(path).ok();
    let modified = metadata.as_ref().and_then(|metadata| metadata.modified().ok()).map(DateTime::<Utc>::from).unwrap_or_else(Utc::now);
    let created = metadata.as_ref().and_then(|metadata| metadata.created().ok()).map(DateTime::<Utc>::from).unwrap_or(modified);
    (created.min(modified), modified)
}

/// Import one file.
pub async fn import(client: &Client, path: &Path) -> Result<Imported, String> {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).ok_or_else(|| tr("Not a file").to_owned())?;
    let checksum = Sha1Checksum::of_file(path).await.map_err(|error| error.to_string())?;
    let checks = client.bulk_upload_check(&[checksum.to_base64()]).await.map_err(|error| error.to_string())?;
    match checks.into_iter().next() {
        Some(UploadCheck::Duplicate { asset_id, trashed: true }) => {
            client.restore_assets(std::slice::from_ref(&asset_id)).await.map_err(|error| error.to_string())?;
            return Ok(Imported::Restored(asset_id));
        }
        Some(UploadCheck::Duplicate { asset_id, trashed: false }) => return Ok(Imported::AlreadyThere(asset_id)),
        Some(UploadCheck::Reject { reason }) => return Ok(Imported::Refused(reason)),
        Some(UploadCheck::Accept) | None => {}
    }
    let (created, modified) = file_times(path);
    match client.upload_asset(path, &name, created, modified).await.map_err(|error| error.to_string())? {
        UploadOutcome::Created(id) => Ok(Imported::New(id)),
        UploadOutcome::Duplicate { id, trashed: true } => {
            client.restore_assets(std::slice::from_ref(&id)).await.map_err(|error| error.to_string())?;
            Ok(Imported::Restored(id))
        }
        UploadOutcome::Duplicate { id, trashed: false } => Ok(Imported::AlreadyThere(id)),
    }
}

/// What was found to import in what was chosen or dropped.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Found {
    pub files: Vec<PathBuf>,
    /// Files and folders that could not be read (no permission, or gone, a link to nowhere among them): counted, as
    /// the import says it, and left out.
    pub unreadable: usize,
}

/// The files to import from what was chosen or dropped: files as they are, and the files inside folders, hidden
/// ones left out. A link to a folder inside a dropped folder is not followed, so a link to `..` or `/` imports nothing
/// more.
pub fn files_in(paths: &[PathBuf]) -> Found {
    let mut found = Found::default();
    let mut waiting: Vec<(PathBuf, bool)> = paths.iter().map(|path| (path.clone(), true)).collect();
    while let Some((path, chosen)) = waiting.pop() {
        let hidden = path.file_name().is_some_and(|name| name.to_string_lossy().starts_with('.'));
        if hidden {
            continue;
        }
        let Ok(metadata) = std::fs::metadata(&path) else {
            found.unreadable += 1;
            continue;
        };
        let linked_folder = !chosen && metadata.is_dir() && std::fs::symlink_metadata(&path).is_ok_and(|link| link.file_type().is_symlink());
        if linked_folder {
            continue;
        }
        if metadata.is_dir() {
            let Ok(entries) = std::fs::read_dir(&path) else {
                found.unreadable += 1;
                continue;
            };
            let mut inside = Vec::new();
            for entry in entries {
                match entry {
                    Ok(entry) => inside.push(entry.path()),
                    Err(_) => found.unreadable += 1,
                }
            }
            inside.sort();
            inside.reverse();
            waiting.extend(inside.into_iter().map(|path| (path, false)));
        } else if metadata.is_file() {
            found.files.push(path);
        }
    }
    found
}

/// Whether Immich takes a file, by its extension, from the server's list (`GET /server/media-types`, extensions
/// such as `.jpg`). An empty list takes everything, and the server decides.
pub fn accepted(path: &Path, extensions: &[String]) -> bool {
    if extensions.is_empty() {
        return true;
    }
    let Some(extension) = path.extension().map(|extension| format!(".{}", extension.to_string_lossy().to_lowercase())) else { return false };
    extensions.iter().any(|accepted| accepted.eq_ignore_ascii_case(&extension))
}

/// A summary of an import, for a toast.
pub fn summary(outcomes: &[Result<Imported, String>]) -> String {
    let count = |wanted: fn(&Imported) -> bool| outcomes.iter().filter(|outcome| matches!(outcome, Ok(imported) if wanted(imported))).count();
    let new = count(|imported| matches!(imported, Imported::New(_) | Imported::Restored(_)));
    let there = count(|imported| matches!(imported, Imported::AlreadyThere(_)));
    let refused = count(|imported| matches!(imported, Imported::Refused(_))) + outcomes.iter().filter(|outcome| outcome.is_err()).count();
    let mut parts = vec![tr("Imported {count}").replace("{count}", &new.to_string())];
    if there > 0 {
        parts.push(tr("{count} already in the library").replace("{count}", &there.to_string()));
    }
    if refused > 0 {
        parts.push(tr("{count} not imported").replace("{count}", &refused.to_string()));
    }
    parts.join(", ")
}

/// Where one file of an import is, as the Mac gallery's import panel lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Waiting,
    Sending,
    Done(Imported),
    Failed(String),
    Cancelled,
}

impl State {
    pub fn title(&self) -> &'static str {
        match self {
            State::Waiting => tr("Waiting"),
            State::Sending => tr("Importing…"),
            State::Done(Imported::New(_)) => tr("Imported"),
            State::Done(Imported::AlreadyThere(_)) => tr("Already in the library"),
            State::Done(Imported::Restored(_)) => tr("Back from Recently Deleted"),
            State::Done(Imported::Refused(_)) | State::Failed(_) => tr("Not imported"),
            State::Cancelled => tr("Cancelled"),
        }
    }

    /// Why it was not imported, when it was not.
    pub fn error(&self) -> Option<&str> {
        match self {
            State::Done(Imported::Refused(reason)) | State::Failed(reason) => Some(reason),
            _ => None,
        }
    }

    fn finished(&self) -> bool {
        !matches!(self, State::Waiting | State::Sending)
    }

    fn failed(&self) -> bool {
        matches!(self, State::Failed(_) | State::Done(Imported::Refused(_)))
    }
}

/// One file of an import, and the album it goes into.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub path: PathBuf,
    pub album: Option<String>,
    pub state: State,
    /// Added to its album already.
    added: bool,
}

/// The files being imported, one at a time, as the Mac gallery's import queue: they wait, are sent, and end
/// imported, already there, not imported or cancelled; failed ones can be tried again.
#[derive(Debug, Default)]
pub struct Queue {
    pub items: Vec<Item>,
    /// Files left out: Immich does not take them.
    pub unsupported: usize,
    /// Files and folders that could not be read (`Found::unreadable`).
    pub unreadable: usize,
}

impl Queue {
    /// Queue `files` for `album`, leaving out what Immich does not take (by the server's `extensions`).
    pub fn enqueue(&mut self, files: Vec<PathBuf>, album: Option<String>, extensions: &[String]) {
        for path in files {
            if accepted(&path, extensions) {
                self.items.push(Item { path, album: album.clone(), state: State::Waiting, added: false });
            } else {
                self.unsupported += 1;
            }
        }
    }

    /// The next file to send, now marked as being sent.
    pub fn take_next(&mut self) -> Option<(usize, PathBuf)> {
        let index = self.items.iter().position(|item| item.state == State::Waiting)?;
        self.items[index].state = State::Sending;
        Some((index, self.items[index].path.clone()))
    }

    pub fn finish(&mut self, index: usize, outcome: Result<Imported, String>) {
        if let Some(item) = self.items.get_mut(index) {
            item.state = match outcome {
                Ok(imported) => State::Done(imported),
                Err(error) => State::Failed(error),
            };
        }
    }

    pub fn is_running(&self) -> bool {
        self.items.iter().any(|item| !item.state.finished())
    }

    pub fn sending(&self) -> bool {
        self.items.iter().any(|item| item.state == State::Sending)
    }

    pub fn completed(&self) -> usize {
        self.items.iter().filter(|item| item.state.finished()).count()
    }

    pub fn failed(&self) -> usize {
        self.items.iter().filter(|item| item.state.failed() || item.state == State::Cancelled).count()
    }

    /// Cancel All: what waits is cancelled; the file being sent finishes.
    pub fn cancel_all(&mut self) {
        for item in &mut self.items {
            if item.state == State::Waiting {
                item.state = State::Cancelled;
            }
        }
    }

    /// Retry Failed: what failed or was cancelled waits again.
    pub fn retry_failed(&mut self) {
        for item in &mut self.items {
            if item.state.failed() || item.state == State::Cancelled {
                item.state = State::Waiting;
            }
        }
    }

    /// Clear: the finished files leave the list.
    pub fn clear(&mut self) {
        self.items.retain(|item| !item.state.finished());
        self.unsupported = 0;
        self.unreadable = 0;
    }

    /// The photos to add to each album, once: those imported, already there or restored.
    pub fn album_additions(&mut self) -> Vec<(String, Vec<String>)> {
        let mut additions: Vec<(String, Vec<String>)> = Vec::new();
        for item in &mut self.items {
            let (Some(album), State::Done(imported)) = (&item.album, &item.state) else { continue };
            let Some(id) = imported.asset_id().filter(|_| !item.added) else { continue };
            item.added = true;
            match additions.iter_mut().find(|(known, _)| known == album) {
                Some((_, ids)) => ids.push(id.to_owned()),
                None => additions.push((album.clone(), vec![id.to_owned()])),
            }
        }
        additions
    }

    /// What the import came to, as the panel and a toast say it.
    pub fn summary(&self) -> String {
        let outcomes: Vec<Result<Imported, String>> = self
            .items
            .iter()
            .filter_map(|item| match &item.state {
                State::Done(imported) => Some(Ok(imported.clone())),
                State::Failed(error) => Some(Err(error.clone())),
                _ => None,
            })
            .collect();
        let mut text = summary(&outcomes);
        let cancelled = self.items.iter().filter(|item| item.state == State::Cancelled).count();
        if cancelled > 0 {
            text = format!("{text}, {}", tr("{count} cancelled").replace("{count}", &cancelled.to_string()));
        }
        if self.is_running() {
            text = tr("{done} of {total} done").replace("{done}", &self.completed().to_string()).replace("{total}", &self.items.len().to_string()) + ". " + &text;
        }
        text
    }

    /// The import as the foot of the sidebar shows it: "Looking for files…" until the first are found (`looking`),
    /// then "Importing 3 of 12" with how far, then what it came to (`outcome`).
    pub fn status(&self, looking: bool, error: Option<&str>) -> Status {
        if looking || self.is_running() {
            let total = self.items.len();
            if total == 0 {
                return Status { phase: Phase::Working, title: tr("Looking for files…").to_owned(), caption: None, progress: None, can_retry: false };
            }
            let done = self.completed();
            let title = tr("Importing {done} of {total}").replace("{done}", &done.to_string()).replace("{total}", &total.to_string());
            return Status { phase: Phase::Working, title, caption: None, progress: Some(done as f64 / total as f64), can_retry: false };
        }
        let outcome = self.outcome(error);
        Status { phase: if outcome.needs_look { Phase::NeedsLook } else { Phase::Done }, title: outcome.title, caption: outcome.caption, progress: None, can_retry: self.failed() > 0 }
    }

    /// What the import came to, as the sidebar says it once it ended and its notification keeps it: "Imported 12" over
    /// what else ("2 already in the library"), "Nothing new" when every file was there already, or "Nothing imported"
    /// over why (`error`, when something stopped it before any file). The same words as on the Mac. It needs a look
    /// when something failed, was cancelled or could not be read, or nothing came in at all.
    pub fn outcome(&self, error: Option<&str>) -> Outcome {
        if let Some(error) = error {
            return Outcome { title: tr("Nothing imported").to_owned(), caption: Some(error.to_owned()), needs_look: true, files: Vec::new() };
        }
        let count = |wanted: fn(&State) -> bool| self.items.iter().filter(|item| wanted(&item.state)).count();
        let imported = count(|state| matches!(state, State::Done(Imported::New(_) | Imported::Restored(_))));
        let there = count(|state| matches!(state, State::Done(Imported::AlreadyThere(_))));
        let not_imported = count(State::failed);
        let cancelled = count(|state| *state == State::Cancelled);
        let mut others = Vec::new();
        let mut add = |number: usize, text: &str| {
            if number > 0 {
                others.push(text.replace("{count}", &number.to_string()));
            }
        };
        add(there, tr("{count} already in the library"));
        add(not_imported, tr("{count} not imported"));
        add(cancelled, tr("{count} cancelled"));
        add(self.unsupported, tr("{count} not photos or videos"));
        add(self.unreadable, tr("{count} could not be read"));
        let title = if imported > 0 {
            tr("Imported {count}").replace("{count}", &imported.to_string())
        } else if not_imported + cancelled == 0 && there > 0 {
            tr("Nothing new").to_owned()
        } else {
            tr("Nothing imported").to_owned()
        };
        let files = self
            .items
            .iter()
            .filter(|item| item.state.failed() || item.state == State::Cancelled)
            .map(|item| File {
                name: item.path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
                reason: item.state.error().unwrap_or(item.state.title()).to_owned(),
            })
            .collect();
        Outcome {
            title,
            caption: (!others.is_empty()).then(|| others.join(", ")),
            needs_look: not_imported + cancelled + self.unreadable > 0 || imported + there == 0,
            files,
        }
    }
}

/// How an import is going, as the foot of the sidebar shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Files are being found or sent.
    Working,
    /// It ended, and everything came in (or was there already).
    Done,
    /// It ended, and something needs a look: it failed, was cancelled, could not be read, or nothing came in.
    NeedsLook,
}

/// The import at the foot of the sidebar (`Queue::status`).
#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub phase: Phase,
    pub title: String,
    /// The quieter line under the title once it ended: what else it came to, or why it stopped.
    pub caption: Option<String>,
    /// While it works: how far, from 0 to 1, or `None` while files are still being looked for.
    pub progress: Option<f64>,
    /// Something failed or was cancelled, to send again.
    pub can_retry: bool,
}

/// What an import came to (`Queue::outcome`): the status's words once it ended, and its notification's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub title: String,
    pub caption: Option<String>,
    pub needs_look: bool,
    /// Each file not imported or cancelled, and why.
    pub files: Vec<File>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_queue_sends_one_at_a_time_and_retries_what_failed() {
        let mut queue = Queue::default();
        let extensions = vec![".jpg".to_owned()];
        queue.enqueue(vec!["/a.jpg".into(), "/b.jpg".into(), "/notes.pdf".into(), "/c.jpg".into()], Some("album".into()), &extensions);
        assert_eq!((queue.items.len(), queue.unsupported), (3, 1));
        let (first, path) = queue.take_next().unwrap();
        assert_eq!((first, path), (0, PathBuf::from("/a.jpg")));
        assert!(queue.sending() && queue.is_running());
        queue.finish(first, Ok(Imported::New("1".into())));
        let (second, _) = queue.take_next().unwrap();
        queue.finish(second, Err("offline".into()));
        queue.cancel_all();
        assert_eq!(queue.items[2].state, State::Cancelled);
        assert_eq!(queue.summary(), "Imported 1, 1 not imported, 1 cancelled");
        assert!(!queue.is_running() && queue.take_next().is_none());
        assert_eq!((queue.completed(), queue.failed()), (3, 2));
        assert_eq!(queue.album_additions(), vec![("album".to_owned(), vec!["1".to_owned()])]);
        assert!(queue.album_additions().is_empty(), "added once");
        queue.retry_failed();
        assert_eq!(queue.items.iter().filter(|item| item.state == State::Waiting).count(), 2);
        while let Some((index, _)) = queue.take_next() {
            queue.finish(index, Ok(Imported::AlreadyThere("2".into())));
        }
        assert_eq!(queue.summary(), "Imported 1, 2 already in the library");
        queue.clear();
        assert!(queue.items.is_empty() && queue.unsupported == 0);
    }

    #[test]
    fn folders_give_their_files_and_hidden_ones_stay_out() {
        let directory = tempfile::tempdir().unwrap();
        let inner = directory.path().join("Trip");
        std::fs::create_dir(&inner).unwrap();
        for name in ["a.jpg", ".DS_Store", "Trip/b.jpg", "Trip/.hidden.jpg"] {
            std::fs::write(directory.path().join(name), b"x").unwrap();
        }
        let found = files_in(&[directory.path().join("a.jpg"), inner, directory.path().join(".DS_Store")]);
        let names: Vec<String> = found.files.iter().map(|file| file.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names.len(), 2, "{names:?}");
        assert!(names.contains(&"a.jpg".to_owned()) && names.contains(&"b.jpg".to_owned()));
    }

    #[test]
    fn a_linked_folder_inside_is_not_followed() {
        let directory = tempfile::tempdir().unwrap();
        let trip = directory.path().join("Trip");
        std::fs::create_dir(&trip).unwrap();
        std::fs::write(trip.join("a.jpg"), b"x").unwrap();
        std::os::unix::fs::symlink(directory.path(), trip.join("loop")).unwrap();
        assert_eq!(files_in(std::slice::from_ref(&trip)).files, vec![trip.join("a.jpg")], "the link back up is not walked");
    }

    #[test]
    fn what_cannot_be_read_is_counted() {
        let directory = tempfile::tempdir().unwrap();
        let trip = directory.path().join("Trip");
        std::fs::create_dir(&trip).unwrap();
        std::fs::write(trip.join("a.jpg"), b"x").unwrap();
        std::os::unix::fs::symlink("/nowhere/at/all.jpg", trip.join("gone.jpg")).unwrap();
        let found = files_in(&[trip.clone(), directory.path().join("missing.jpg")]);
        assert_eq!(found, Found { files: vec![trip.join("a.jpg")], unreadable: 2 });
    }

    #[test]
    fn the_status_follows_the_import_and_says_what_it_came_to() {
        let mut queue = Queue::default();
        let looking = queue.status(true, None);
        assert_eq!((looking.phase, looking.title.as_str(), looking.progress), (Phase::Working, "Looking for files…", None));
        queue.enqueue(vec!["/a.jpg".into(), "/b.jpg".into(), "/c.jpg".into(), "/d.jpg".into(), "/notes.pdf".into()], None, &[".jpg".to_owned()]);
        let (first, _) = queue.take_next().unwrap();
        queue.finish(first, Ok(Imported::New("1".into())));
        let working = queue.status(false, None);
        assert_eq!((working.title.as_str(), working.progress), ("Importing 1 of 4", Some(0.25)));
        let (second, _) = queue.take_next().unwrap();
        queue.finish(second, Ok(Imported::AlreadyThere("2".into())));
        let (third, _) = queue.take_next().unwrap();
        queue.finish(third, Err("offline".into()));
        queue.cancel_all();
        let ended = queue.status(false, None);
        assert_eq!(ended.phase, Phase::NeedsLook);
        assert_eq!(ended.title, "Imported 1");
        assert_eq!(ended.caption.as_deref(), Some("1 already in the library, 1 not imported, 1 cancelled, 1 not photos or videos"));
        assert!(ended.can_retry);
        let outcome = queue.outcome(None);
        assert_eq!(outcome.files, vec![File { name: "c.jpg".into(), reason: "offline".into() }, File { name: "d.jpg".into(), reason: "Cancelled".into() }]);
    }

    #[test]
    fn an_import_that_brought_nothing_new_says_so() {
        let mut queue = Queue::default();
        queue.enqueue(vec!["/a.jpg".into(), "/b.jpg".into()], None, &[]);
        while let Some((index, _)) = queue.take_next() {
            queue.finish(index, Ok(Imported::AlreadyThere(index.to_string())));
        }
        let status = queue.status(false, None);
        assert_eq!((status.phase, status.title.as_str(), status.caption.as_deref()), (Phase::Done, "Nothing new", Some("2 already in the library")));
        let mut clean = Queue::default();
        clean.enqueue(vec!["/a.jpg".into()], None, &[]);
        let (index, _) = clean.take_next().unwrap();
        clean.finish(index, Ok(Imported::Restored("3".into())));
        let status = clean.status(false, None);
        assert_eq!((status.phase, status.title.as_str(), status.caption), (Phase::Done, "Imported 1", None));
    }

    #[test]
    fn nothing_imported_needs_a_look_and_says_why() {
        let mut queue = Queue::default();
        queue.enqueue(vec!["/notes.pdf".into()], None, &[".jpg".to_owned()]);
        queue.unreadable = 1;
        let status = queue.status(false, None);
        assert_eq!((status.phase, status.title.as_str()), (Phase::NeedsLook, "Nothing imported"));
        assert_eq!(status.caption.as_deref(), Some("1 not photos or videos, 1 could not be read"));
        let refused = Queue::default().outcome(Some("You can view “Trip” but not add to it"));
        assert_eq!((refused.title.as_str(), refused.caption.as_deref(), refused.needs_look), ("Nothing imported", Some("You can view “Trip” but not add to it"), true));
    }

    #[test]
    fn only_what_immich_takes_is_sent() {
        let extensions = vec![".jpg".to_owned(), ".heic".to_owned(), ".mp4".to_owned()];
        assert!(accepted(Path::new("/x/IMG_1.JPG"), &extensions));
        assert!(accepted(Path::new("/x/clip.mp4"), &extensions));
        assert!(!accepted(Path::new("/x/notes.pdf"), &extensions));
        assert!(!accepted(Path::new("/x/README"), &extensions));
        assert!(accepted(Path::new("/x/notes.pdf"), &[]), "without the list, the server decides");
    }

    #[test]
    fn a_summary_counts_each_outcome() {
        let outcomes = vec![Ok(Imported::New("1".into())), Ok(Imported::AlreadyThere("2".into())), Ok(Imported::Refused("unsupported-format".into())), Err("offline".into())];
        assert_eq!(summary(&outcomes), "Imported 1, 1 already in the library, 2 not imported");
    }
}
