//! What the gallery changes in Immich, one call each, with the message a person reads when it fails. Nothing here
//! deletes for good unless asked to by name: deleting moves to Immich's trash.

use chrono::{FixedOffset, NaiveDateTime, TimeZone};
use immich_api::asset_info::AssetDetails;
use immich_api::{AlbumChanges, AssetChanges, AssetEdit, Client, NewAlbum, Visibility};
use verso_linux::i18n::tr;

fn failed(what: &str, error: immich_api::ApiError) -> String {
    tr("{what} failed: {error}").replace("{what}", what).replace("{error}", &crate::errors::said(&error))
}

pub async fn set_favorite(client: &Client, ids: Vec<String>, favorite: bool) -> Result<(), String> {
    let changes = AssetChanges { favorite: Some(favorite), ..AssetChanges::default() };
    client.update_assets(&ids, &changes).await.map_err(|error| failed(tr("Changing favorites"), error))
}

/// Archive (out of the timeline), or back to the timeline.
pub async fn set_archived(client: &Client, ids: Vec<String>, archived: bool) -> Result<(), String> {
    let visibility = if archived { Visibility::Archive } else { Visibility::Timeline };
    let changes = AssetChanges { visibility: Some(visibility), ..AssetChanges::default() };
    client.update_assets(&ids, &changes).await.map_err(|error| failed(tr("Archiving"), error))
}

/// Into the Locked Folder, or out of it to the timeline.
pub async fn set_locked(client: &Client, ids: Vec<String>, locked: bool) -> Result<(), String> {
    let visibility = if locked { Visibility::Locked } else { Visibility::Timeline };
    let changes = AssetChanges { visibility: Some(visibility), ..AssetChanges::default() };
    client.update_assets(&ids, &changes).await.map_err(|error| failed(tr("Moving to the Locked Folder"), error))
}

/// To Immich's trash, from which they can be restored until it is emptied.
pub async fn trash(client: &Client, ids: Vec<String>) -> Result<(), String> {
    client.delete_assets(&ids, false).await.map_err(|error| failed(tr("Deleting"), error))
}

/// For good: only from the trash, after asking.
pub async fn delete_forever(client: &Client, ids: Vec<String>) -> Result<(), String> {
    client.delete_assets(&ids, true).await.map_err(|error| failed(tr("Deleting"), error))
}

pub async fn restore(client: &Client, ids: Vec<String>) -> Result<u64, String> {
    client.restore_assets(&ids).await.map_err(|error| failed(tr("Restoring"), error))
}

pub async fn empty_trash(client: &Client) -> Result<u64, String> {
    client.empty_trash().await.map_err(|error| failed(tr("Emptying the trash"), error))
}

pub async fn add_to_album(client: &Client, album_id: String, ids: Vec<String>) -> Result<usize, String> {
    let results = client.add_assets_to_album(&album_id, &ids).await.map_err(|error| failed(tr("Adding to the album"), error))?;
    Ok(results.iter().filter(|result| result.success).count())
}

pub async fn remove_from_album(client: &Client, album_id: String, ids: Vec<String>) -> Result<(), String> {
    client.remove_assets_from_album(&album_id, &ids).await.map(|_| ()).map_err(|error| failed(tr("Removing from the album"), error))
}

pub async fn create_album(client: &Client, name: String, ids: Vec<String>) -> Result<immich_api::Album, String> {
    let album = NewAlbum { name, asset_ids: ids, ..NewAlbum::default() };
    client.create_album(&album).await.map_err(|error| failed(tr("Creating the album"), error))
}

pub async fn rename_album(client: &Client, album_id: String, name: String) -> Result<(), String> {
    let changes = AlbumChanges { name: Some(name), ..AlbumChanges::default() };
    client.update_album(&album_id, &changes).await.map(|_| ()).map_err(|error| failed(tr("Renaming the album"), error))
}

pub async fn set_album_cover(client: &Client, album_id: String, asset_id: String) -> Result<(), String> {
    let changes = AlbumChanges { thumbnail_asset_id: Some(asset_id), ..AlbumChanges::default() };
    client.update_album(&album_id, &changes).await.map(|_| ()).map_err(|error| failed(tr("Changing the cover"), error))
}

pub async fn delete_album(client: &Client, album_id: String) -> Result<(), String> {
    client.delete_album(&album_id).await.map_err(|error| failed(tr("Deleting the album"), error))
}

pub async fn set_description(client: &Client, id: String, description: String) -> Result<(), String> {
    let changes = AssetChanges { description: Some(description), ..AssetChanges::default() };
    client.update_asset(&id, &changes).await.map(|_| ()).map_err(|error| failed(tr("Saving the description"), error))
}

/// A rating of 1 to 5 stars, or none.
pub async fn set_rating(client: &Client, id: String, rating: Option<i8>) -> Result<(), String> {
    let changes = AssetChanges { rating: Some(rating), ..AssetChanges::default() };
    client.update_asset(&id, &changes).await.map(|_| ()).map_err(|error| failed(tr("Saving the rating"), error))
}

/// The offset of the clock where a photo was taken: its wall-clock time less its UTC time, to the minute.
pub fn offset_of(details: &AssetDetails) -> FixedOffset {
    let local = details.local_date_time.unwrap_or_else(|| details.file_created_at.naive_utc());
    let seconds = (local - details.file_created_at.naive_utc()).num_seconds();
    let minutes = (seconds as f64 / 60.0).round() as i32;
    FixedOffset::east_opt(minutes * 60).unwrap_or_else(|| FixedOffset::east_opt(0).expect("zero is an offset"))
}

/// Read a date and time as people write it: `2024-03-15 14:32`, with or without seconds, or a `T`.
pub fn parse_taken(text: &str) -> Option<NaiveDateTime> {
    let text = text.trim().replace('T', " ");
    ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"].iter().find_map(|format| {
        NaiveDateTime::parse_from_str(&text, format).ok().or_else(|| chrono::NaiveDate::parse_from_str(&text, format).ok().and_then(|date| date.and_hms_opt(12, 0, 0)))
    })
}

/// Set when a photo was taken, on the clock where it was taken (the photo's own offset kept).
pub async fn set_taken(client: &Client, id: String, taken: NaiveDateTime, offset: FixedOffset) -> Result<(), String> {
    let moment = offset.from_local_datetime(&taken).single().ok_or_else(|| tr("That time does not exist on the photo's clock").to_owned())?;
    let changes = AssetChanges { date_time_original: Some(moment), ..AssetChanges::default() };
    client.update_asset(&id, &changes).await.map(|_| ()).map_err(|error| failed(tr("Changing the date"), error))
}

/// Set where photos were taken.
pub async fn set_place(client: &Client, ids: Vec<String>, latitude: f64, longitude: f64) -> Result<(), String> {
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        return Err(tr("That place is not on the map").to_owned());
    }
    let changes = AssetChanges { latitude: Some(latitude), longitude: Some(longitude), ..AssetChanges::default() };
    client.update_assets(&ids, &changes).await.map_err(|error| failed(tr("Changing the place"), error))
}

/// A photo's edits turned by `quarter_turns` clockwise (negative for counter-clockwise), as the photo is seen: the
/// rotation step is changed, added (last) or, once back at zero, taken out; every other step stays as it is.
///
/// The steps apply in their order. A mirror after the rotation step turns its direction around (a clockwise step,
/// flipped, reads counter-clockwise), so with an odd number of them the step turns the other way.
pub fn rotated(mut edits: Vec<AssetEdit>, quarter_turns: i32) -> Vec<AssetEdit> {
    let step = edits.iter().position(|edit| matches!(edit, AssetEdit::Rotate { .. }));
    let current = step.and_then(|position| match edits[position] {
        AssetEdit::Rotate { angle } => Some(angle),
        _ => None,
    });
    let mirrors_after = step.map_or(0, |position| edits[position..].iter().filter(|edit| matches!(edit, AssetEdit::Mirror { .. })).count());
    let quarter_turns = if mirrors_after % 2 == 1 { -quarter_turns } else { quarter_turns };
    let angle = (current.unwrap_or(0) + quarter_turns * 90).rem_euclid(360);
    match (current.is_some(), angle) {
        (true, 0) => edits.retain(|edit| !matches!(edit, AssetEdit::Rotate { .. })),
        (true, angle) => {
            for edit in edits.iter_mut() {
                if let AssetEdit::Rotate { angle: step } = edit {
                    *step = angle;
                }
            }
        }
        (false, 0) => {}
        (false, angle) => edits.push(AssetEdit::Rotate { angle }),
    }
    edits
}

/// Turn a photo by quarter turns, without touching the original: Immich keeps it as an edit and makes the
/// thumbnails again.
pub async fn rotate(client: &Client, id: String, quarter_turns: i32) -> Result<(), String> {
    let edits = client.asset_edits(&id).await.map_err(|error| failed(tr("Rotating"), error))?;
    let turned = rotated(edits, quarter_turns);
    let outcome = if turned.is_empty() { client.delete_asset_edits(&id).await } else { client.set_asset_edits(&id, &turned).await.map(|_| ()) };
    outcome.map_err(|error| failed(tr("Rotating"), error))
}

/// A crop, in pixels of the original as it stands up (its EXIF orientation applied).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Crop {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// The original's size as it stands up: EXIF orientations 5 to 8 turn it a quarter, so width and height swap.
pub fn upright_size(details: &AssetDetails) -> Option<(u32, u32)> {
    let exif = details.exif.as_ref()?;
    let (width, height) = (exif.image_width.filter(|width| *width > 0)?, exif.image_height.filter(|height| *height > 0)?);
    Some(if matches!(exif.orientation.as_deref(), Some("5" | "6" | "7" | "8")) { (height, width) } else { (width, height) })
}

/// Whether a photo's picture can be edited here (turned, cropped), as the Mac gallery decides: one's own still photo
/// of known size, and not a Live Photo, a 360° sphere, a GIF, an SVG or an Insta360 file.
pub fn can_edit_picture(details: &AssetDetails, user_id: Option<&str>) -> bool {
    let name = details.original_file_name.to_lowercase();
    let mime = details.original_mime_type.as_deref().unwrap_or_default().to_lowercase();
    user_id == Some(details.owner_id.as_str())
        && details.kind == immich_api::AssetKind::Image
        && details.live_photo_video_id.is_none()
        && details.exif.as_ref().and_then(|exif| exif.projection_type.as_deref()) != Some("EQUIRECTANGULAR")
        && upright_size(details).is_some()
        && ![".gif", ".svg", ".insp"].iter().any(|extension| name.ends_with(extension))
        && !["image/gif", "image/svg+xml"].contains(&mime.as_str())
}

/// The crop among a photo's edits, if there is one.
pub fn crop_of(edits: &[AssetEdit]) -> Option<Crop> {
    edits.iter().find_map(|edit| match edit {
        AssetEdit::Crop { x, y, width, height } => Some(Crop { x: *x, y: *y, width: *width, height: *height }),
        _ => None,
    })
}

/// A rectangle chosen on the picture, as fractions of it (left, top, width, height, each 0 to 1), in pixels of a
/// picture of `width` by `height`; `None` for the whole picture.
pub fn crop_in_pixels(fraction: (f64, f64, f64, f64), width: u32, height: u32) -> Option<Crop> {
    let (left, top, wide, high) = fraction;
    if left <= 0.0 && top <= 0.0 && left + wide >= 1.0 && top + high >= 1.0 {
        return None;
    }
    let x = ((left * f64::from(width)) as u32).min(width.saturating_sub(1));
    let y = ((top * f64::from(height)) as u32).min(height.saturating_sub(1));
    let crop_width = ((wide * f64::from(width)) as u32).max(1).min(width - x);
    let crop_height = ((high * f64::from(height)) as u32).max(1).min(height - y);
    Some(Crop { x, y, width: crop_width, height: crop_height })
}

/// A photo's edits with its crop replaced: the old one goes, and a new one comes first, before any turn or mirror (as
/// the Mac gallery puts it), so it is in the picture's own pixels.
pub fn cropped(mut edits: Vec<AssetEdit>, crop: Option<Crop>) -> Vec<AssetEdit> {
    edits.retain(|edit| !matches!(edit, AssetEdit::Crop { .. }));
    if let Some(crop) = crop {
        edits.insert(0, AssetEdit::Crop { x: crop.x, y: crop.y, width: crop.width, height: crop.height });
    }
    edits
}

/// Crop a photo, or with `None` show the whole of it again, without touching the original.
pub async fn set_crop(client: &Client, id: String, crop: Option<Crop>) -> Result<(), String> {
    let edits = client.asset_edits(&id).await.map_err(|error| failed(tr("Cropping"), error))?;
    let changed = cropped(edits, crop);
    let outcome = if changed.is_empty() { client.delete_asset_edits(&id).await } else { client.set_asset_edits(&id, &changed).await.map(|_| ()) };
    outcome.map_err(|error| failed(tr("Cropping"), error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};

    fn photo(width: u32, height: u32, orientation: Option<&str>) -> AssetDetails {
        let exif = immich_api::asset_info::Exif { image_width: Some(width), image_height: Some(height), orientation: orientation.map(str::to_owned), ..Default::default() };
        AssetDetails { owner_id: "me".into(), kind: immich_api::AssetKind::Image, original_file_name: "IMG_1.JPG".into(), exif: Some(exif), ..AssetDetails::default() }
    }

    #[test]
    fn a_turned_original_stands_up_with_width_and_height_swapped() {
        assert_eq!(upright_size(&photo(4000, 3000, Some("1"))), Some((4000, 3000)));
        assert_eq!(upright_size(&photo(4000, 3000, Some("6"))), Some((3000, 4000)));
        assert_eq!(upright_size(&AssetDetails::default()), None);
    }

    #[test]
    fn only_ones_own_still_photos_of_known_size_are_edited_here() {
        assert!(can_edit_picture(&photo(10, 10, None), Some("me")));
        assert!(!can_edit_picture(&photo(10, 10, None), Some("someone else")));
        let live = AssetDetails { live_photo_video_id: Some("v".into()), ..photo(10, 10, None) };
        assert!(!can_edit_picture(&live, Some("me")));
        let gif = AssetDetails { original_file_name: "dance.GIF".into(), ..photo(10, 10, None) };
        assert!(!can_edit_picture(&gif, Some("me")));
        let mut sphere = photo(10, 10, None);
        sphere.exif.as_mut().unwrap().projection_type = Some("EQUIRECTANGULAR".into());
        assert!(!can_edit_picture(&sphere, Some("me")));
        let video = AssetDetails { kind: immich_api::AssetKind::Video, ..photo(10, 10, None) };
        assert!(!can_edit_picture(&video, Some("me")));
    }

    #[test]
    fn a_crop_is_in_pixels_inside_the_picture_and_the_whole_picture_is_none() {
        assert_eq!(crop_in_pixels((0.0, 0.0, 1.0, 1.0), 4000, 3000), None);
        assert_eq!(crop_in_pixels((0.25, 0.5, 0.5, 0.25), 4000, 3000), Some(Crop { x: 1000, y: 1500, width: 2000, height: 750 }));
        assert_eq!(crop_in_pixels((0.9, 0.9, 0.5, 0.5), 100, 100), Some(Crop { x: 90, y: 90, width: 10, height: 10 }), "kept inside");
        assert_eq!(crop_in_pixels((0.5, 0.5, 0.0, 0.0), 100, 100), Some(Crop { x: 50, y: 50, width: 1, height: 1 }), "a pixel at least");
    }

    #[test]
    fn a_new_crop_replaces_the_old_and_comes_first() {
        let turn = AssetEdit::Rotate { angle: 90 };
        let old = AssetEdit::Crop { x: 1, y: 1, width: 5, height: 5 };
        let crop = Crop { x: 10, y: 20, width: 30, height: 40 };
        assert_eq!(cropped(vec![turn.clone(), old.clone()], Some(crop)), vec![AssetEdit::Crop { x: 10, y: 20, width: 30, height: 40 }, turn.clone()]);
        assert_eq!(cropped(vec![old.clone(), turn.clone()], None), vec![turn.clone()]);
        assert_eq!(crop_of(&[turn, old]), Some(Crop { x: 1, y: 1, width: 5, height: 5 }));
    }
    use immich_api::MirrorAxis;

    #[test]
    fn turning_changes_only_the_rotation() {
        let crop = AssetEdit::Crop { x: 0, y: 0, width: 10, height: 10 };
        assert_eq!(rotated(vec![crop.clone()], 1), vec![crop.clone(), AssetEdit::Rotate { angle: 90 }]);
        assert_eq!(rotated(vec![AssetEdit::Rotate { angle: 90 }, crop.clone()], -1), vec![crop.clone()], "back at zero, the step goes");
        assert_eq!(rotated(vec![AssetEdit::Rotate { angle: 270 }], 1), Vec::<AssetEdit>::new());
        assert_eq!(rotated(vec![AssetEdit::Rotate { angle: 90 }], 1), vec![AssetEdit::Rotate { angle: 180 }]);
        assert_eq!(rotated(Vec::new(), -1), vec![AssetEdit::Rotate { angle: 270 }]);
        // Flipped after the turn, the step turns the other way, so the photo still turns as asked.
        let flip = AssetEdit::Mirror { axis: MirrorAxis::Horizontal };
        assert_eq!(rotated(vec![AssetEdit::Rotate { angle: 90 }, flip.clone()], 1), vec![flip.clone()]);
        assert_eq!(rotated(vec![AssetEdit::Rotate { angle: 90 }, flip.clone(), flip.clone()], 1), vec![AssetEdit::Rotate { angle: 180 }, flip.clone(), flip.clone()], "flipped twice, it turns as it is");
        assert_eq!(rotated(vec![flip.clone(), AssetEdit::Rotate { angle: 90 }], 1), vec![flip.clone(), AssetEdit::Rotate { angle: 180 }], "flipped before the turn, it turns as it is");
        assert_eq!(rotated(vec![flip.clone()], 1), vec![flip.clone(), AssetEdit::Rotate { angle: 90 }], "a new step goes last, after the flip");
    }

    #[test]
    fn a_photo_keeps_the_offset_of_its_clock() {
        let details = AssetDetails {
            file_created_at: DateTime::parse_from_rfc3339("2018-11-17T12:04:36Z").unwrap().with_timezone(&Utc),
            local_date_time: NaiveDateTime::parse_from_str("2018-11-17 13:04:36", "%Y-%m-%d %H:%M:%S").ok(),
            ..AssetDetails::default()
        };
        assert_eq!(offset_of(&details), FixedOffset::east_opt(3600).unwrap());
        let india = AssetDetails { local_date_time: NaiveDateTime::parse_from_str("2018-11-17 17:34:36", "%Y-%m-%d %H:%M:%S").ok(), ..details.clone() };
        assert_eq!(offset_of(&india), FixedOffset::east_opt(5 * 3600 + 1800).unwrap());
    }

    #[test]
    fn dates_read_as_people_write_them() {
        let expected = NaiveDateTime::parse_from_str("2024-03-15 14:32:00", "%Y-%m-%d %H:%M:%S").unwrap();
        assert_eq!(parse_taken("2024-03-15 14:32"), Some(expected));
        assert_eq!(parse_taken(" 2024-03-15T14:32:00 "), Some(expected));
        assert_eq!(parse_taken("2024-03-15").map(|moment| moment.time().to_string()), Some("12:00:00".to_owned()));
        assert_eq!(parse_taken("15/03/2024"), None);
    }
}
