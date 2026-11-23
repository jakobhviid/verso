//! What Verso's window does on Linux, without a toolkit (ARCHITECTURE.md, "Verso's window"): signing in and keeping the
//! credential, the service and the drive's switch, the account, the library as sections of tiles, the grid's layout,
//! ThumbHash placeholders, the picture cache, the changes made in Immich, links, imports, notifications, and how dates
//! and sizes read. The GTK app draws it.

pub mod account_preferences; // the account's preferences in Immich
pub mod actions; // what the gallery changes in Immich, with messages for people
pub mod albums; // the albums' view settings remembered, and the sidebar's album sections
pub mod arrangement; // a photo page's view options
pub mod connection; // the signed-in account, shared with the drive
pub mod dates; // when photos were taken: shifted by an amount, or set
pub mod duplicates; // the Duplicates page's order, remembered
pub mod errors; // what a person reads when Immich did not do it
pub mod images; // thumbnails and previews: fetched, cached, decoded
pub mod layout; // justified rows and squares
pub mod library; // sections of tiles: timelines, searches, lists
pub mod links; // Open in Immich and immich-crosslink
pub mod map; // the web map's arithmetic: what a view spans, the place at a point, fitting the photos
pub mod map_style; // the map's look: the Immich server's map style, made drawable by libshumate, and its credits
pub mod notifications; // Verso's own notifications, kept on this computer
pub mod preferences; // the settings windows' layout, from the shared settings table
pub mod presentation; // the slideshow, face boxes, turning the view
pub mod sandbox; // Verso's service in a Flatpak: started and stopped through the portals
pub mod search; // a search's words, filters, order and history
pub mod session; // signing in and out, the credential, the service and the drive's switch
pub mod settings; // remembered choices
pub mod shared_links; // shared links: which show, remembered, their addresses and titles
pub mod sidebar; // the sidebar as Edit Sidebar arranges it: sections, pages, what is hidden
pub mod similar; // Find Similar Photos: which photos group, and the cover
pub mod tags; // the tags as a tree
pub mod text; // dates, lengths, sizes
pub mod thumbhash; // placeholders while thumbnails load
pub mod uploads; // importing files, each checked by its checksum first
