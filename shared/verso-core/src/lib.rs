//! The portable core of Verso.
//!
//! Holds every piece of logic that a platform adapter needs: the identifier-based library model, naming and
//! clashes, membership from Immich, the metadata store and change journal, the content cache, upload logic, the
//! settings table, and how the gallery arranges what it shows (`overview`, `map`, `duplicates`, `shared_links`,
//! `people`, and the date scroller's `rail`) (ARCHITECTURE.md, "Crates"). No FUSE, D-Bus, GTK or OS-specific code
//! lives here; platform services come in through traits.

pub mod content;
pub mod duplicates;
pub mod folder_uploads;
pub mod immich;
pub mod layout;
pub mod links;
pub mod map;
pub mod model;
pub mod naming;
pub mod overview;
pub mod people;
pub mod product;
pub mod rail;
pub mod settings;
pub mod shared_links;
pub mod sign_in;
pub mod source;
pub mod store;
pub mod tree;
pub mod uploads;
