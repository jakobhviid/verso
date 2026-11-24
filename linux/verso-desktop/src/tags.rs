//! The tags as a tree, as the Mac gallery's Tags page shows them: each after its parent, children by name.

use immich_api::Tag;

/// The tags in tree order, each with its depth. A tag whose parent is not among them shows at the top level.
pub fn tree(tags: &[Tag]) -> Vec<(&Tag, usize)> {
    fn add<'a>(tags: &'a [Tag], parent: Option<&str>, depth: usize, ordered: &mut Vec<(&'a Tag, usize)>) {
        let mut children: Vec<&Tag> = tags.iter().filter(|tag| tag.parent_id.as_deref() == parent).collect();
        children.sort_by_key(|tag| tag.name.to_lowercase());
        for tag in children {
            ordered.push((tag, depth));
            add(tags, Some(&tag.id), depth + 1, ordered);
        }
    }
    let mut ordered = Vec::new();
    let mut roots: Vec<&Tag> = tags.iter().filter(|tag| tag.parent_id.as_deref().is_none_or(|parent| !tags.iter().any(|known| known.id == parent))).collect();
    roots.sort_by_key(|tag| tag.name.to_lowercase());
    for root in roots {
        ordered.push((root, 0));
        add(tags, Some(&root.id), 1, &mut ordered);
    }
    ordered
}

/// A tag's colour as red, green and blue from 0 to 1, when it is `#RRGGBB`.
pub fn color(text: &str) -> Option<(f32, f32, f32)> {
    let hex = text.strip_prefix('#').filter(|hex| hex.len() == 6)?;
    let value = u32::from_str_radix(hex, 16).ok()?;
    let part = |shift: u32| ((value >> shift) & 0xff) as f32 / 255.0;
    Some((part(16), part(8), part(0)))
}

/// A tag's new name is valid when it has text and no `/` (a slash would move it in the tree).
pub fn valid_name(name: &str) -> bool {
    !name.trim().is_empty() && !name.contains('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(id: &str, name: &str, parent: Option<&str>) -> Tag {
        Tag { id: id.to_owned(), name: name.to_owned(), parent_id: parent.map(str::to_owned), ..Tag::default() }
    }

    #[test]
    fn tags_follow_their_parents_by_name() {
        let tags = [tag("b", "beach", Some("t")), tag("t", "Travel", None), tag("a", "alps", Some("t")), tag("f", "family", None), tag("o", "orphan", Some("gone")), tag("s", "ski", Some("a"))];
        let shown: Vec<(&str, usize)> = tree(&tags).into_iter().map(|(tag, depth)| (tag.name.as_str(), depth)).collect();
        assert_eq!(shown, [("family", 0), ("orphan", 0), ("Travel", 0), ("alps", 1), ("ski", 2), ("beach", 1)]);
    }

    #[test]
    fn colours_and_names() {
        assert_eq!(color("#ff8000"), Some((1.0, 128.0 / 255.0, 0.0)));
        assert_eq!(color("red"), None);
        assert_eq!(color("#fff"), None);
        assert!(valid_name(" Beach "));
        assert!(!valid_name("a/b") && !valid_name("  "));
    }
}
