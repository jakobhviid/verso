//! Links to what the gallery shows: Immich's web app (Open in Immich, Copy Immich Link) and immich-crosslink, the
//! protocol other Immich apps on this computer take part in. The paths are the drive's (`verso_core::links`),
//! so the gallery, the drive and the other apps name one item alike.

use verso_core::links::{encode_component, server_address, ImmichItem, CROSSLINK_SCHEME};

/// A photo, seen on its own (the timeline) or in an album or a person.
pub fn asset(asset_id: &str, within: Option<ImmichItem>) -> ImmichItem {
    ImmichItem::Asset { within: within.map(Box::new), asset_id: asset_id.to_owned() }
}

/// The item's page in Immich's web app.
pub fn web_address(server_url: &str, item: &ImmichItem) -> String {
    format!("{}{}", server_address(server_url), item.immich_path())
}

/// The item's crosslink, as immich-crosslink writes one: the Immich path, the server, and the user when known.
pub fn crosslink(server_url: &str, user_id: Option<&str>, item: &ImmichItem) -> String {
    let path = item.immich_path();
    let joiner = if path.contains('?') { '&' } else { '?' };
    let mut link = format!("{CROSSLINK_SCHEME}://{path}{joiner}server={}", encode_component(&server_address(server_url)));
    if let Some(user_id) = user_id.filter(|user_id| !user_id.is_empty()) {
        link.push_str("&user=");
        link.push_str(&encode_component(user_id));
    }
    link
}

#[cfg(test)]
mod tests {
    use super::*;
    use verso_core::links::{receive, Reading};

    const SERVER: &str = "https://photos.example.org/api";
    const PHOTO: &str = "2d6e3655-50dd-40f5-b8cf-f7d3f56aa95e";
    const ALBUM: &str = "518e39e4-0053-45e3-9bb8-39aae3834243";

    #[test]
    fn a_photo_in_an_album_opens_there_in_immich() {
        let item = asset(PHOTO, Some(ImmichItem::Album(ALBUM.to_owned())));
        assert_eq!(web_address(SERVER, &item), format!("https://photos.example.org/albums/{ALBUM}/photos/{PHOTO}"));
    }

    #[test]
    fn the_gallerys_crosslinks_read_back_as_the_same_item() {
        let item = asset(PHOTO, Some(ImmichItem::Album(ALBUM.to_owned())));
        let link = crosslink(SERVER, Some("201f18cd-48ec-4220-8e10-1466650212ee"), &item);
        assert!(link.starts_with("immich-crosslink:///albums/"), "{link}");
        assert_eq!(receive(&link, SERVER, Some("201f18cd-48ec-4220-8e10-1466650212ee")), Ok(item));
        assert!(matches!(verso_core::links::read_crosslink(&link), Reading::Show(_)));
    }
}
