//! Dragging photos out to Files, an email or an editor: the drop gets the originals as files. The paths are found
//! only when the drop asks for them: in the drive, where it is mounted, so the program reads the original as it
//! reads any file and nothing is downloaded first; else the originals are downloaded to the cache.

use std::cell::RefCell;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;

use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, gio, glib};
use immich_api::Client;
use verso_desktop::links;
use verso_core::links::ImmichItem;

/// What finding the files needs: the account, and where the photos were seen.
#[derive(Clone)]
pub struct Resolver {
    pub client: Client,
    pub server: String,
    pub user_id: Option<String>,
    /// The account's cache, where originals are downloaded when the drive cannot give them.
    pub cache: PathBuf,
    pub within: Option<ImmichItem>,
}

impl Resolver {
    /// The original of one photo as a local file: the drive's path, else a download into the cache.
    pub async fn file(&self, id: &str) -> Result<PathBuf, String> {
        let link = links::crosslink(&self.server, self.user_id.as_deref(), &links::asset(id, self.within.clone()));
        if let Some((result, path)) = verso_linux::dbus::show_link(&link, false, false).await {
            if result == "show" && std::path::Path::new(&path).is_file() {
                return Ok(PathBuf::from(path));
            }
        }
        let details = self.client.asset_details(id).await.map_err(|error| verso_desktop::errors::said(&error))?;
        let name = std::path::Path::new(&details.original_file_name).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| id.to_owned());
        let folder = self.cache.join(verso_desktop::images::ORIGINALS).join(id);
        let target = folder.join(name);
        if !target.exists() {
            tokio::fs::create_dir_all(&folder).await.map_err(|error| error.to_string())?;
            let partial = verso_desktop::images::partial_path(&target);
            if let Err(error) = self.client.download_original(id, &partial).await {
                let _ = tokio::fs::remove_file(&partial).await;
                return Err(error.to_string());
            }
            verso_desktop::images::settle(&partial, &target).map_err(|error| error.to_string())?;
        }
        Ok(target)
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct PhotoFiles {
        pub ids: RefCell<Vec<String>>,
        pub resolver: RefCell<Option<Resolver>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for PhotoFiles {
        const NAME: &'static str = "ImmichGalleryPhotoFiles";
        type Type = super::PhotoFiles;
        type ParentType = gdk::ContentProvider;
    }

    impl ObjectImpl for PhotoFiles {}

    impl ContentProviderImpl for PhotoFiles {
        fn formats(&self) -> gdk::ContentFormats {
            gdk::ContentFormats::new(&["text/uri-list"])
        }

        fn write_mime_type_future(
            &self,
            mime_type: &str,
            stream: &gio::OutputStream,
            io_priority: glib::Priority,
        ) -> Pin<Box<dyn Future<Output = Result<(), glib::Error>> + 'static>> {
            let wanted = mime_type == "text/uri-list";
            let (ids, resolver, stream) = (self.ids.borrow().clone(), self.resolver.borrow().clone(), stream.clone());
            Box::pin(async move {
                let (true, Some(resolver)) = (wanted, resolver) else {
                    return Err(glib::Error::new(gio::IOErrorEnum::NotSupported, "only file addresses can be given"));
                };
                let found = crate::tasks::runtime().spawn(async move {
                    let mut files = Vec::new();
                    for id in ids {
                        if let Ok(path) = resolver.file(&id).await {
                            files.push(path);
                        }
                    }
                    files
                });
                let files = found.await.unwrap_or_default();
                if files.is_empty() {
                    return Err(glib::Error::new(gio::IOErrorEnum::NotFound, "the photos could not be had as files"));
                }
                let list: String = files.iter().map(|path| format!("{}\r\n", gio::File::for_path(path).uri())).collect();
                stream.write_all_future(list.into_bytes(), io_priority).await.map_err(|(_, error)| error)?;
                Ok(())
            })
        }
    }
}

glib::wrapper! {
    /// The photos being dragged, as the files a drop asks for.
    pub struct PhotoFiles(ObjectSubclass<imp::PhotoFiles>) @extends gdk::ContentProvider;
}

impl PhotoFiles {
    pub fn new(ids: Vec<String>, resolver: Resolver) -> PhotoFiles {
        let provider: PhotoFiles = glib::Object::new();
        provider.imp().ids.replace(ids);
        provider.imp().resolver.replace(Some(resolver));
        provider
    }
}
