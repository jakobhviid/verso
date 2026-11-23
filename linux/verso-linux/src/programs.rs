//! Finding Verso's own programs wherever its channel put them: in the install's folder (the packages put them all in
//! `/usr/bin`; the tarball keeps the window in `libexec/`, behind its launcher), on PATH, or in the Homebrew prefix,
//! which a desktop session's PATH may not include.

use std::path::{Path, PathBuf};

/// Homebrew's prefix on Linux when nothing says otherwise.
const HOMEBREW_DEFAULT: &str = "/home/linuxbrew/.linuxbrew";

/// The first `name` that exists: in the `bin` of the Homebrew prefix the running program came from, in the install's
/// folder, on PATH, then in another Homebrew prefix (`$HOMEBREW_PREFIX`, or Homebrew's default). A prefix's `bin`
/// holds stable links, so a path found there outlives the next `brew upgrade`, where the folder beside a program
/// from Homebrew is one version's.
pub fn find(name: &str) -> Option<PathBuf> {
    let running = std::env::current_exe().ok();
    let own_prefix = running.as_deref().and_then(homebrew_prefix_of);
    let beside = running.as_deref().and_then(install_folder_of).map(|folder| folder.join(name));
    let on_path: Vec<PathBuf> =
        std::env::var_os("PATH").map(|path| std::env::split_paths(&path).map(|directory| directory.join(name)).collect()).unwrap_or_default();
    let other_prefixes = [std::env::var_os("HOMEBREW_PREFIX").map(PathBuf::from), Some(PathBuf::from(HOMEBREW_DEFAULT))];
    let in_prefix = |prefix: PathBuf| prefix.join("bin").join(name);
    own_prefix
        .map(in_prefix)
        .into_iter()
        .chain(beside)
        .chain(on_path)
        .chain(other_prefixes.into_iter().flatten().map(in_prefix))
        .find(|path| path.is_file())
}

/// The install's folder: the running program's, or, for a program in a `libexec` folder (the tarball's window, behind
/// the launcher that checks the system's libraries first), the folder above it, where the launcher, the service, the
/// app's own icons and the catalogs are.
pub fn install_folder() -> Option<PathBuf> {
    install_folder_of(&std::env::current_exe().ok()?)
}

/// The launcher in front of the running program, when it runs from a `libexec` folder: the program of its own name, as
/// `find` finds it (a Homebrew prefix's link first, then the install's folder). It is what the desktop started and
/// what an upgrade replaces; the program behind it is in one version's folder under Homebrew.
pub fn launcher() -> Option<PathBuf> {
    let running = std::env::current_exe().ok()?;
    if !in_libexec(&running) {
        return None;
    }
    find(running.file_name()?.to_str()?)
}

fn install_folder_of(program: &Path) -> Option<PathBuf> {
    let folder = program.parent()?;
    if in_libexec(program) { folder.parent().map(Path::to_path_buf) } else { Some(folder.to_path_buf()) }
}

fn in_libexec(program: &Path) -> bool {
    program.parent().and_then(Path::file_name).is_some_and(|folder| folder == "libexec")
}

/// The Homebrew prefix of a program that runs from its Cellar or Caskroom.
fn homebrew_prefix_of(program: &Path) -> Option<PathBuf> {
    let text = program.to_str()?;
    let at = text.find("/Cellar/").or_else(|| text.find("/Caskroom/"))?;
    Some(PathBuf::from(&text[..at]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kegs_prefix_is_read_from_its_path() {
        let formula = Path::new("/home/linuxbrew/.linuxbrew/Cellar/verso/1.2.0/bin/verso-service");
        assert_eq!(homebrew_prefix_of(formula), Some(PathBuf::from("/home/linuxbrew/.linuxbrew")));
        let cask = Path::new("/opt/brew/Caskroom/verso/1.2.0/verso/verso");
        assert_eq!(homebrew_prefix_of(cask), Some(PathBuf::from("/opt/brew")));
        let window = Path::new("/opt/brew/Caskroom/verso/1.2.0/verso/libexec/verso");
        assert_eq!(homebrew_prefix_of(window), Some(PathBuf::from("/opt/brew")));
        assert_eq!(homebrew_prefix_of(Path::new("/usr/bin/verso-service")), None);
    }

    #[test]
    fn the_window_behind_the_launcher_shares_the_install_folder() {
        assert_eq!(install_folder_of(Path::new("/opt/verso/libexec/verso")), Some(PathBuf::from("/opt/verso")));
        assert_eq!(install_folder_of(Path::new("/opt/verso/verso-service")), Some(PathBuf::from("/opt/verso")));
        assert_eq!(install_folder_of(Path::new("/usr/bin/verso")), Some(PathBuf::from("/usr/bin")));
        assert!(in_libexec(Path::new("/opt/verso/libexec/verso")));
        assert!(!in_libexec(Path::new("/opt/verso/verso")));
    }
}
