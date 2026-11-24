//! The viewer's extras, as the Mac gallery's: the slideshow's settings and order, where a face's box falls on the
//! photo shown, and turning a picture for the view alone (Rotate View Temporarily).

use immich_api::face::Face;

use crate::settings::Settings;

/// The slideshow's settings, remembered under the Mac gallery's keys.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Slideshow {
    /// Seconds a photo shows.
    pub interval: f64,
    pub shuffle: bool,
    pub fade: bool,
    /// A video moves on after the interval too, instead of playing to its end.
    pub limit_videos: bool,
}

impl Default for Slideshow {
    fn default() -> Slideshow {
        Slideshow { interval: 5.0, shuffle: false, fade: true, limit_videos: false }
    }
}

/// The intervals offered, in seconds.
pub const INTERVALS: [u32; 6] = [2, 3, 5, 10, 15, 30];

/// How long a video may sit without ending before the slideshow moves on anyway.
pub const VIDEO_PATIENCE: f64 = 30.0;

impl Slideshow {
    pub fn load(settings: &Settings) -> Slideshow {
        let flag = |key: &str, default: bool| settings.get(key).map_or(default, |value| value == "true");
        let defaults = Slideshow::default();
        Slideshow {
            interval: settings.get("viewer.interval").and_then(|value| value.parse().ok()).filter(|seconds: &f64| *seconds > 0.0).unwrap_or(defaults.interval),
            shuffle: flag("viewer.shuffle", defaults.shuffle),
            fade: flag("viewer.fade", defaults.fade),
            limit_videos: flag("viewer.limitVideos", defaults.limit_videos),
        }
    }

    pub fn save(&self, settings: &Settings) {
        let flag = |on: bool| Some(if on { "true" } else { "false" });
        settings.set("viewer.interval", Some(&self.interval.to_string()));
        settings.set("viewer.shuffle", flag(self.shuffle));
        settings.set("viewer.fade", flag(self.fade));
        settings.set("viewer.limitVideos", flag(self.limit_videos));
    }
}

/// The order a slideshow shows `count` photos in, starting from `current`: the grid's order from there on, or, shuffled,
/// every photo once with `current` first. `seed` makes the shuffle (any number; the same one gives the same order).
pub fn order(count: usize, current: usize, shuffle: bool, seed: u64) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    let current = current.min(count - 1);
    if !shuffle {
        return (current..count).collect();
    }
    let mut rest: Vec<usize> = (0..count).filter(|index| *index != current).collect();
    // Fisher and Yates, with xorshift: no dependency for a slideshow's dice.
    let mut state = seed | 1;
    for end in (1..rest.len()).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        rest.swap(end, (state % (end as u64 + 1)) as usize);
    }
    std::iter::once(current).chain(rest).collect()
}

/// A rectangle: left, top, width, height.
pub type Rect = (f64, f64, f64, f64);

/// Where a picture of `width` by `height` shows when fitted, whole, into `frame`, centred.
pub fn fitted(width: f64, height: f64, frame: Rect) -> Rect {
    let (left, top, frame_width, frame_height) = frame;
    if width <= 0.0 || height <= 0.0 {
        return frame;
    }
    let scale = (frame_width / width).min(frame_height / height);
    let (shown_width, shown_height) = (width * scale, height * scale);
    (left + (frame_width - shown_width) / 2.0, top + (frame_height - shown_height) / 2.0, shown_width, shown_height)
}

/// Where a face's box falls on the photo as it shows: Immich measures it on a picture of its own size.
pub fn face_box(face: &Face, shown: Rect) -> Option<Rect> {
    if face.image_width == 0 || face.image_height == 0 {
        return None;
    }
    let (left, top, width, height) = shown;
    let x = |value: i32| left + f64::from(value) / f64::from(face.image_width) * width;
    let y = |value: i32| top + f64::from(value) / f64::from(face.image_height) * height;
    Some((x(face.left), y(face.top), x(face.right) - x(face.left), y(face.bottom) - y(face.top)))
}

/// A face's name as the viewer shows it.
pub fn face_name(face: &Face) -> Option<&str> {
    face.person.as_ref().map(|person| person.name.as_str()).filter(|name| !name.trim().is_empty())
}

/// RGBA pixels turned by quarter turns clockwise (negative: anticlockwise), for the view alone. Gives the pixels,
/// tightly packed, and the new width and height.
pub fn rotate_rgba(pixels: &[u8], width: usize, height: usize, stride: usize, quarter_turns: i32) -> (Vec<u8>, usize, usize) {
    let turns = quarter_turns.rem_euclid(4);
    let (new_width, new_height) = if turns % 2 == 1 { (height, width) } else { (width, height) };
    let mut turned = vec![0; new_width * new_height * 4];
    for y in 0..height {
        for x in 0..width {
            let (to_x, to_y) = match turns {
                1 => (height - 1 - y, x),
                2 => (width - 1 - x, height - 1 - y),
                3 => (y, width - 1 - x),
                _ => (x, y),
            };
            let from = y * stride + x * 4;
            let to = (to_y * new_width + to_x) * 4;
            turned[to..to + 4].copy_from_slice(&pixels[from..from + 4]);
        }
    }
    (turned, new_width, new_height)
}

#[cfg(test)]
mod tests {
    use super::*;
    use immich_api::Person;

    #[test]
    fn the_slideshow_remembers_its_settings() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(Slideshow::load(&settings), Slideshow::default());
        let chosen = Slideshow { interval: 10.0, shuffle: true, fade: false, limit_videos: true };
        chosen.save(&settings);
        assert_eq!(Slideshow::load(&settings), chosen);
    }

    #[test]
    fn a_slideshow_goes_on_from_the_photo_shown_or_shuffles_every_photo_once() {
        assert_eq!(order(5, 2, false, 7), [2, 3, 4]);
        let shuffled = order(50, 10, true, 7);
        assert_eq!(shuffled[0], 10, "the photo shown first");
        let mut sorted = shuffled.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..50).collect::<Vec<_>>(), "each once");
        assert_ne!(shuffled[1..], order(50, 10, false, 7)[..], "shuffled");
        assert_eq!(order(50, 10, true, 7), shuffled, "the same seed, the same order");
        assert!(order(0, 0, true, 1).is_empty());
        assert_eq!(order(3, 9, false, 1), [2]);
    }

    #[test]
    fn a_face_falls_where_it_is_on_the_fitted_photo() {
        // A 4000 by 3000 photo fitted into 1000 by 1000 shows 1000 by 750, 125 down.
        let shown = fitted(4000.0, 3000.0, (0.0, 0.0, 1000.0, 1000.0));
        assert_eq!(shown, (0.0, 125.0, 1000.0, 750.0));
        let face = Face { left: 400, top: 300, right: 800, bottom: 600, image_width: 4000, image_height: 3000, ..Face::default() };
        assert_eq!(face_box(&face, shown), Some((100.0, 200.0, 100.0, 75.0)));
        assert_eq!(face_box(&Face::default(), shown), None);
        assert_eq!(face_name(&face), None);
        let ada = Person { id: "p".to_owned(), name: "Ada".to_owned(), is_hidden: false, is_favorite: false, birth_date: None, thumbnail_path: String::new(), color: None, created_at: None, updated_at: None };
        let named = Face { person: Some(ada), ..face };
        assert_eq!(face_name(&named), Some("Ada"));
    }

    #[test]
    fn pictures_turn_for_the_view() {
        // 2 by 1: red, green.
        let pixels = [255, 0, 0, 255, 0, 255, 0, 255];
        let (right, width, height) = rotate_rgba(&pixels, 2, 1, 8, 1);
        assert_eq!((width, height), (1, 2));
        assert_eq!(right, [255, 0, 0, 255, 0, 255, 0, 255], "clockwise: red on top");
        let (left, _, _) = rotate_rgba(&pixels, 2, 1, 8, -1);
        assert_eq!(left, [0, 255, 0, 255, 255, 0, 0, 255], "anticlockwise: green on top");
        let (half, width, height) = rotate_rgba(&pixels, 2, 1, 8, 2);
        assert_eq!((width, height, half), (2, 1, vec![0, 255, 0, 255, 255, 0, 0, 255]));
    }
}
