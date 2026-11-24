//! The Duplicates page's order and the photos each group keeps at first (after Immich Gallery's
//! `DuplicatesArrangement`). The server sends every group at once, so the app sorts them: Immich's web app keeps the
//! server's order; the others put the groups worth reviewing first. Linux's window, the Mac and the iPhone (through
//! `verso-bridge`) all sort here.

use std::cmp::Reverse;

use immich_api::duplicate::DuplicateGroup;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SortBy {
    /// The server's order.
    #[default]
    Default,
    /// Most photos first.
    ItemCount,
    /// Largest originals first.
    TotalSize,
}

impl SortBy {
    pub const ALL: [SortBy; 3] = [SortBy::Default, SortBy::ItemCount, SortBy::TotalSize];

    /// The codes the choice is kept by, the same on Linux and the Mac.
    pub fn code(self) -> &'static str {
        match self {
            SortBy::Default => "Default",
            SortBy::ItemCount => "ItemCount",
            SortBy::TotalSize => "TotalSize",
        }
    }

    pub fn from_code(code: &str) -> Option<SortBy> {
        SortBy::ALL.into_iter().find(|sort| sort.code() == code)
    }

    /// The places of the groups measured, in this order: most items or largest first; ties keep the server's order.
    pub fn order(self, groups: &[Measure]) -> Vec<usize> {
        let mut places: Vec<usize> = (0..groups.len()).collect();
        match self {
            SortBy::Default => {}
            SortBy::ItemCount => places.sort_by_key(|place| Reverse(groups[*place].items)),
            SortBy::TotalSize => places.sort_by_key(|place| Reverse(groups[*place].bytes)),
        }
        places
    }

    /// The groups in this order.
    pub fn sorted(self, groups: &[DuplicateGroup]) -> Vec<DuplicateGroup> {
        let measured: Vec<Measure> = groups.iter().map(Measure::of).collect();
        self.order(&measured).into_iter().map(|place| groups[place].clone()).collect()
    }
}

/// What the order reads of a group: how many photos it holds, and the bytes of their originals the server told.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Measure {
    pub items: u64,
    pub bytes: u64,
}

impl Measure {
    /// A group measured by its photos' sizes, none where the server told none.
    pub fn of_sizes(sizes: impl IntoIterator<Item = Option<u64>>) -> Measure {
        sizes.into_iter().fold(Measure::default(), |measure, size| Measure { items: measure.items + 1, bytes: measure.bytes + size.unwrap_or(0) })
    }

    pub fn of(group: &DuplicateGroup) -> Measure {
        Measure::of_sizes(group.assets.iter().map(|asset| asset.exif.as_ref().and_then(|exif| exif.file_size)))
    }
}

/// The photos a group keeps at first: those Immich suggests that are in it, or else its first.
pub fn suggested_keep(group: &DuplicateGroup) -> Vec<String> {
    let photos: Vec<&str> = group.assets.iter().map(|asset| asset.id.as_str()).collect();
    kept_at_first(&photos, &group.suggested_keep_asset_ids)
}

/// The photos of a group (by id, in its order) kept at first: those of `suggested` that are in it, or else its first.
pub fn kept_at_first(photos: &[&str], suggested: &[String]) -> Vec<String> {
    let kept: Vec<String> = suggested.iter().filter(|id| photos.contains(&id.as_str())).cloned().collect();
    if kept.is_empty() {
        photos.first().map(|id| vec![(*id).to_owned()]).unwrap_or_default()
    } else {
        kept
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use immich_api::asset_info::{AssetDetails, Exif};

    fn group(id: &str, sizes: &[u64]) -> DuplicateGroup {
        let assets = sizes
            .iter()
            .enumerate()
            .map(|(index, size)| AssetDetails { id: format!("{id}-{index}"), exif: Some(Exif { file_size: Some(*size), ..Exif::default() }), ..AssetDetails::default() })
            .collect();
        DuplicateGroup { duplicate_id: id.to_owned(), assets, ..DuplicateGroup::default() }
    }

    #[test]
    fn groups_sort_by_items_or_size_and_ties_keep_the_servers_order() {
        let groups = [group("a", &[10, 10]), group("b", &[5, 5, 5]), group("c", &[900, 100]), group("d", &[1, 1, 1])];
        let ids = |sort: SortBy| sort.sorted(&groups).into_iter().map(|group| group.duplicate_id).collect::<Vec<_>>();
        assert_eq!(ids(SortBy::Default), ["a", "b", "c", "d"]);
        assert_eq!(ids(SortBy::ItemCount), ["b", "d", "a", "c"]);
        assert_eq!(ids(SortBy::TotalSize), ["c", "a", "b", "d"]);
    }

    #[test]
    fn a_size_the_server_did_not_tell_counts_as_a_photo_of_no_bytes() {
        assert_eq!(Measure::of_sizes([Some(10), None, Some(5)]), Measure { items: 3, bytes: 15 });
        assert_eq!(Measure::of_sizes([]), Measure::default());
        let measured = [Measure::of_sizes([None, None]), Measure::of_sizes([Some(1)])];
        assert_eq!(SortBy::ItemCount.order(&measured), [0, 1]);
        assert_eq!(SortBy::TotalSize.order(&measured), [1, 0]);
        assert!(SortBy::TotalSize.order(&[]).is_empty());
    }

    #[test]
    fn the_choice_is_kept_by_its_code() {
        for sort in SortBy::ALL {
            assert_eq!(SortBy::from_code(sort.code()), Some(sort));
        }
        assert_eq!(SortBy::from_code("TotalSize"), Some(SortBy::TotalSize));
        assert_eq!(SortBy::from_code("Largest"), None);
    }

    #[test]
    fn a_group_keeps_immichs_suggestion_or_its_first() {
        let mut shown = group("a", &[1, 2, 3]);
        assert_eq!(suggested_keep(&shown), ["a-0"]);
        shown.suggested_keep_asset_ids = vec!["a-2".to_owned(), "gone".to_owned()];
        assert_eq!(suggested_keep(&shown), ["a-2"]);
        shown.suggested_keep_asset_ids = vec!["gone".to_owned()];
        assert_eq!(suggested_keep(&shown), ["a-0"], "a suggestion of none of its photos keeps its first");
        assert!(suggested_keep(&DuplicateGroup::default()).is_empty());
    }
}
