//! Find Similar Photos, as the Mac gallery's (its `SimilarPhotos`): which photos qualify, how photos taken close
//! together group by how alike they look, and which one is suggested as the stack's cover. The Mac compares Apple
//! Vision's feature prints; here each photo's thumbnail gives a gradient hash (how brightness changes across a 16 by 16
//! picture of it) and a sharpness, compared on this computer. The grouping itself is the Mac's: runs split where the
//! pause between shots is longer than chosen, then complete-link groups within a run, never longer than a minute or
//! more than 20 photos.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use immich_api::asset::{Asset, AssetKind, Visibility};
use immich_api::asset_info::AssetDetails;

pub const MAX_DURATION_SECONDS: i64 = 60;
pub const MAX_MEMBERS: usize = 20;
pub const MIN_MEMBERS: usize = 2;
/// A scan stops, with a message, rather than compare more than this many photos.
pub const CANDIDATE_LIMIT: usize = 2000;
/// The longest pauses between two shots of a group offered, in seconds.
pub const GAPS: [i64; 3] = [5, 10, 30];
pub const DEFAULT_GAP: i64 = 10;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Sensitivity {
    Strict,
    #[default]
    Normal,
    Loose,
}

impl Sensitivity {
    pub const ALL: [Sensitivity; 3] = [Sensitivity::Strict, Sensitivity::Normal, Sensitivity::Loose];

    /// The largest share of differing hash bits between any two photos of a group. Starting points, chosen as a
    /// near-copy, a burst and a loose burst differ in a gradient hash; not a promise of what counts as alike.
    pub fn threshold(self) -> f32 {
        match self {
            Sensitivity::Strict => 0.08,
            Sensitivity::Normal => 0.15,
            Sensitivity::Loose => 0.22,
        }
    }
}

/// Why a photo is not offered for stacking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exclusion {
    NotPhoto,
    NotOwned,
    Trashed,
    HiddenOrLocked,
    Stacked,
}

/// A photo that may join a group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub id: String,
    pub taken: DateTime<Utc>,
    pub is_favorite: bool,
    /// How big the photo is, for the cover's last tie: its pixels, or its file's bytes when those are unknown.
    pub size: u64,
}

fn shown(visibility: &Visibility) -> bool {
    matches!(visibility, Visibility::Timeline | Visibility::Archive)
}

/// Only the user's own still photos on the timeline or in the archive, outside the trash and not in a stack.
pub fn exclusion(asset: &AssetDetails, user_id: &str) -> Option<Exclusion> {
    if asset.kind != AssetKind::Image {
        return Some(Exclusion::NotPhoto);
    }
    if user_id.is_empty() || asset.owner_id != user_id {
        return Some(Exclusion::NotOwned);
    }
    if asset.is_trashed {
        return Some(Exclusion::Trashed);
    }
    if !shown(&asset.visibility) {
        return Some(Exclusion::HiddenOrLocked);
    }
    if asset.stack.is_some() {
        return Some(Exclusion::Stacked);
    }
    None
}

pub fn candidate(asset: &AssetDetails) -> Candidate {
    let pixels = u64::from(asset.width.unwrap_or(0)) * u64::from(asset.height.unwrap_or(0));
    Candidate { id: asset.id.clone(), taken: asset.file_created_at, is_favorite: asset.is_favorite, size: pixels }
}

/// The same for a search's answer, which holds the user's own photos only.
pub fn search_exclusion(asset: &Asset) -> Option<Exclusion> {
    if asset.kind != AssetKind::Image {
        return Some(Exclusion::NotPhoto);
    }
    if asset.is_trashed {
        return Some(Exclusion::Trashed);
    }
    if !shown(&asset.visibility) {
        return Some(Exclusion::HiddenOrLocked);
    }
    if asset.stack_id.is_some() {
        return Some(Exclusion::Stacked);
    }
    None
}

pub fn search_candidate(asset: &Asset) -> Candidate {
    Candidate { id: asset.id.clone(), taken: asset.file_created_at, is_favorite: asset.is_favorite, size: asset.file_size.unwrap_or(0) }
}

fn sorted(candidates: &[Candidate]) -> Vec<Candidate> {
    let mut sorted = candidates.to_vec();
    sorted.sort_by(|a, b| (a.taken, &a.id).cmp(&(b.taken, &b.id)));
    sorted
}

/// Photos, oldest first, split wherever the pause between two shots is longer than `max_gap` seconds (a pause of
/// exactly that keeps them together). Only runs of two or more can hold a group.
pub fn time_runs(candidates: &[Candidate], max_gap: i64) -> Vec<Vec<Candidate>> {
    let mut runs = Vec::new();
    let mut current: Vec<Candidate> = Vec::new();
    for candidate in sorted(candidates) {
        if current.last().is_some_and(|last| candidate.taken - last.taken > Duration::seconds(max_gap)) {
            if current.len() >= MIN_MEMBERS {
                runs.push(std::mem::take(&mut current));
            }
            current.clear();
        }
        current.push(candidate);
    }
    if current.len() >= MIN_MEMBERS {
        runs.push(current);
    }
    runs
}

/// Complete-link grouping of one run (oldest first), as the Mac's: every two photos of a group are within
/// `threshold`, so A like B and B like C do not pull in a different C. The closest pairs merge first, ties going to
/// the earlier photos. `distance` gives `None` for a photo that could not be compared, which keeps it out. Gives run
/// indices.
pub fn groups(run: &[Candidate], threshold: f32, distance: impl Fn(usize, usize) -> Option<f32>) -> Vec<Vec<usize>> {
    let mut members: HashMap<usize, Vec<usize>> = (0..run.len()).map(|index| (index, vec![index])).collect();
    let mut links: HashMap<(usize, usize), f32> = HashMap::new();
    for first in 0..run.len() {
        for second in first + 1..run.len() {
            if run[second].taken - run[first].taken > Duration::seconds(MAX_DURATION_SECONDS) {
                break;
            }
            if let Some(apart) = distance(first, second).filter(|apart| apart.is_finite() && *apart <= threshold) {
                links.insert((first, second), apart);
            }
        }
    }
    let fits = |a: &[usize], b: &[usize]| {
        let count = a.len() + b.len();
        let first = a.iter().chain(b).min().copied().unwrap_or(0);
        let last = a.iter().chain(b).max().copied().unwrap_or(0);
        count <= MAX_MEMBERS && run[last].taken - run[first].taken <= Duration::seconds(MAX_DURATION_SECONDS)
    };
    loop {
        let mut best: Option<((usize, usize), f32)> = None;
        let mut gone = Vec::new();
        for (&pair, &apart) in &links {
            // Groups only grow: a pair that no longer fits never will.
            if !fits(&members[&pair.0], &members[&pair.1]) {
                gone.push(pair);
                continue;
            }
            let better = match best {
                None => true,
                Some((known, known_apart)) => (apart, pair.0, pair.1) < (known_apart, known.0, known.1),
            };
            if better {
                best = Some((pair, apart));
            }
        }
        for pair in gone {
            links.remove(&pair);
        }
        let Some(((keep, merged), _)) = best else { break };
        let mut joined = members.remove(&merged).unwrap_or_default();
        let kept = members.entry(keep).or_default();
        kept.append(&mut joined);
        kept.sort_unstable();
        links.remove(&(keep, merged));
        let others: Vec<usize> = members.keys().copied().filter(|other| *other != keep).collect();
        for other in others {
            let to_keep = (keep.min(other), keep.max(other));
            let to_merged = (merged.min(other), merged.max(other));
            // Complete link: the merged group is as far from another as its farthest part.
            match (links.get(&to_keep).copied(), links.get(&to_merged).copied()) {
                (Some(near), Some(far)) => {
                    links.insert(to_keep, near.max(far));
                }
                _ => {
                    links.remove(&to_keep);
                }
            }
            links.remove(&to_merged);
        }
    }
    let mut found: Vec<Vec<usize>> = members.into_values().filter(|group| group.len() >= MIN_MEMBERS).collect();
    found.sort_by_key(|group| group[0]);
    found
}

/// What a photo's thumbnail gives for comparing it: a 256-bit gradient hash and a sharpness.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Features {
    hash: [u64; 4],
    /// The variance of the Laplacian of a small grey copy: higher is sharper.
    pub sharpness: f64,
}

/// Grey values of an RGBA picture shrunk to `width` by `height` by averaging the pixels each covers.
fn shrunk_grey(rgba: &[u8], from_width: usize, from_height: usize, width: usize, height: usize) -> Vec<f64> {
    let mut grey = vec![0.0; width * height];
    for y in 0..height {
        let (top, bottom) = (y * from_height / height, ((y + 1) * from_height / height).max(y * from_height / height + 1));
        for x in 0..width {
            let (left, right) = (x * from_width / width, ((x + 1) * from_width / width).max(x * from_width / width + 1));
            let (mut sum, mut count) = (0.0, 0.0);
            for row in top..bottom.min(from_height) {
                for column in left..right.min(from_width) {
                    let pixel = (row * from_width + column) * 4;
                    sum += 0.299 * f64::from(rgba[pixel]) + 0.587 * f64::from(rgba[pixel + 1]) + 0.114 * f64::from(rgba[pixel + 2]);
                    count += 1.0;
                }
            }
            grey[y * width + x] = if count > 0.0 { sum / count } else { 0.0 };
        }
    }
    grey
}

/// The features of a picture given as tightly packed RGBA.
pub fn features(rgba: &[u8], width: usize, height: usize) -> Option<Features> {
    if width < 2 || height < 2 || rgba.len() < width * height * 4 {
        return None;
    }
    // The hash: whether each of 16 by 16 cells is brighter than the one to its right.
    let grey = shrunk_grey(rgba, width, height, 17, 16);
    let mut hash = [0u64; 4];
    for y in 0..16 {
        for x in 0..16 {
            if grey[y * 17 + x] > grey[y * 17 + x + 1] {
                let bit = y * 16 + x;
                hash[bit / 64] |= 1 << (bit % 64);
            }
        }
    }
    let side = 64.min(width).min(height);
    let small = shrunk_grey(rgba, width, height, side, side);
    let mut laplacians = Vec::with_capacity(side * side);
    for y in 1..side - 1 {
        for x in 1..side - 1 {
            let at = |dx: isize, dy: isize| small[((y as isize + dy) as usize) * side + (x as isize + dx) as usize];
            laplacians.push(at(-1, 0) + at(1, 0) + at(0, -1) + at(0, 1) - 4.0 * at(0, 0));
        }
    }
    let mean = laplacians.iter().sum::<f64>() / laplacians.len().max(1) as f64;
    let sharpness = laplacians.iter().map(|value| (value - mean).powi(2)).sum::<f64>() / laplacians.len().max(1) as f64;
    Some(Features { hash, sharpness })
}

/// The share of differing hash bits, from 0 (alike) to 1.
pub fn distance(a: &Features, b: &Features) -> f32 {
    let differing: u32 = a.hash.iter().zip(&b.hash).map(|(a, b)| (a ^ b).count_ones()).sum();
    differing as f32 / 256.0
}

/// The suggested cover: a favorite first, then the sharpest, then the biggest, then the earlier shot and its id, so
/// the same photos always give the same suggestion.
pub fn top_pick(members: &[Candidate], features: &HashMap<String, Features>) -> Option<String> {
    let key = |candidate: &Candidate| (candidate.is_favorite, features.get(&candidate.id).map_or(f64::NEG_INFINITY, |features| features.sharpness), candidate.size);
    members
        .iter()
        .min_by(|a, b| {
            let (key_a, key_b) = (key(a), key(b));
            key_b.partial_cmp(&key_a).unwrap_or(std::cmp::Ordering::Equal).then_with(|| (a.taken, &a.id).cmp(&(b.taken, &b.id)))
        })
        .map(|candidate| candidate.id.clone())
}

/// The last `days` days, today included.
pub fn last_days(days: i64, today: NaiveDate) -> (NaiveDate, NaiveDate) {
    (today - Duration::days(days - 1), today)
}

/// From the start of the first day to the start of the day after the last, in this computer's time; a reversed
/// range is turned round.
pub fn bounds(start: NaiveDate, end: NaiveDate) -> std::ops::Range<DateTime<Utc>> {
    let (first, last) = (start.min(end), start.max(end));
    let midnight = |day: NaiveDate| Local.from_local_datetime(&day.and_hms_opt(0, 0, 0).unwrap_or_default()).earliest().map_or_else(|| Utc.from_utc_datetime(&day.and_hms_opt(0, 0, 0).unwrap_or_default()), |local| local.with_timezone(&Utc));
    midnight(first)..midnight(last + Duration::days(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shot(id: &str, seconds: i64) -> Candidate {
        Candidate { id: id.to_owned(), taken: DateTime::from_timestamp(1_700_000_000 + seconds, 0).unwrap(), is_favorite: false, size: 0 }
    }

    #[test]
    fn runs_split_at_long_pauses_and_keep_two_or_more() {
        let photos = [shot("a", 0), shot("b", 10), shot("c", 31), shot("d", 100), shot("e", 104)];
        let runs: Vec<Vec<String>> = time_runs(&photos, 10).into_iter().map(|run| run.into_iter().map(|shot| shot.id).collect()).collect();
        assert_eq!(runs, [vec!["a", "b"], vec!["d", "e"]], "a pause of exactly the gap keeps shots together; c is alone");
    }

    #[test]
    fn groups_are_complete_link_so_a_chain_does_not_pull_in_a_stranger() {
        let run = [shot("a", 0), shot("b", 1), shot("c", 2), shot("d", 3)];
        // a and b alike; b and c alike; a and c not; d like nothing.
        let distance = |i: usize, j: usize| match (i, j) {
            (0, 1) => Some(0.05),
            (1, 2) => Some(0.06),
            (0, 2) => Some(0.4),
            _ => Some(0.9),
        };
        assert_eq!(groups(&run, 0.15, distance), [vec![0, 1]]);
        // A photo that could not be compared stays out.
        assert!(groups(&run[..2], 0.15, |_, _| None).is_empty());
    }

    #[test]
    fn groups_never_span_more_than_a_minute() {
        let run = [shot("a", 0), shot("b", 40), shot("c", 80)];
        let found = groups(&run, 0.15, |_, _| Some(0.01));
        assert_eq!(found, [vec![0, 1]]);
    }

    fn picture(width: usize, height: usize, shade: impl Fn(usize, usize) -> u8) -> Vec<u8> {
        let mut rgba = Vec::with_capacity(width * height * 4);
        for y in 0..height {
            for x in 0..width {
                let value = shade(x, y);
                rgba.extend_from_slice(&[value, value, value, 255]);
            }
        }
        rgba
    }

    #[test]
    fn like_pictures_hash_alike_and_different_ones_do_not() {
        let gradient = picture(160, 120, |x, y| ((x * 255 / 160 + y) % 256) as u8);
        let brighter = picture(160, 120, |x, y| ((x * 255 / 160 + y) % 256).saturating_add(10).min(255) as u8);
        let checks = picture(160, 120, |x, y| if (x / 10 + y / 10) % 2 == 0 { 230 } else { 20 });
        let (a, b, c) = (features(&gradient, 160, 120).unwrap(), features(&brighter, 160, 120).unwrap(), features(&checks, 160, 120).unwrap());
        assert_eq!(distance(&a, &a), 0.0);
        assert!(distance(&a, &b) < Sensitivity::Strict.threshold(), "{}", distance(&a, &b));
        assert!(distance(&a, &c) > Sensitivity::Loose.threshold(), "{}", distance(&a, &c));
        assert!(c.sharpness > a.sharpness, "edges are sharper than a gradient");
        assert!(features(&[0; 4], 1, 1).is_none());
    }

    #[test]
    fn the_cover_is_a_favorite_then_the_sharpest_then_the_biggest_then_the_first() {
        let mut members = vec![shot("a", 0), shot("b", 1), shot("c", 2)];
        let sharp = |value: f64| Features { hash: [0; 4], sharpness: value };
        let mut features: HashMap<String, Features> = [("a".to_owned(), sharp(1.0)), ("b".to_owned(), sharp(5.0)), ("c".to_owned(), sharp(5.0))].into();
        members[2].size = 10;
        assert_eq!(top_pick(&members, &features).as_deref(), Some("c"), "as sharp as b, and bigger");
        members[0].is_favorite = true;
        assert_eq!(top_pick(&members, &features).as_deref(), Some("a"));
        features.clear();
        members[0].is_favorite = false;
        members[2].size = 0;
        assert_eq!(top_pick(&members, &features).as_deref(), Some("a"), "all alike: the first");
    }

    #[test]
    fn a_period_covers_whole_days() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 14).unwrap();
        assert_eq!(last_days(30, today).0, NaiveDate::from_ymd_opt(2026, 10, 16).unwrap());
        let range = bounds(today, today - Duration::days(1));
        assert_eq!(range.end - range.start, Duration::days(2));
    }
}
