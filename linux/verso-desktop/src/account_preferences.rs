//! The account's preferences in Immich, as the Mac gallery's Preferences pane lists them: each feature on or off and
//! in the web app's sidebar, the memory duration, the albums' default order, downloads, email notifications and the
//! rest. Read from the server's whole answer, so a row shows only where the server has its value; a change is sent as a
//! patch of that value alone, which the server merges into the rest.

use serde_json::{Map, Value};

/// How a preference is changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    Switch,
    /// A whole number in a range, with its unit.
    Number { min: u32, max: u32 },
    /// One of the values, each with its label.
    Choice(&'static [(&'static str, &'static str)]),
    /// Bytes, shown and chosen in gibibytes.
    GibiBytes,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row {
    pub title: &'static str,
    pub path: &'static [&'static str],
    pub control: Control,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Group {
    pub title: &'static str,
    pub rows: &'static [Row],
}

const fn switch(title: &'static str, path: &'static [&'static str]) -> Row {
    Row { title, path, control: Control::Switch }
}

/// The groups, in the Mac gallery's order.
pub const GROUPS: &[Group] = &[
    Group { title: "Memories", rows: &[switch("Enabled", &["memories", "enabled"]), switch("Show in Web Sidebar", &["memories", "sidebarWeb"]), Row { title: "Seconds per Photo", path: &["memories", "duration"], control: Control::Number { min: 1, max: 60 } }] },
    Group { title: "Ratings", rows: &[switch("Enabled", &["ratings", "enabled"])] },
    Group { title: "Folders", rows: &[switch("Enabled", &["folders", "enabled"]), switch("Show in Web Sidebar", &["folders", "sidebarWeb"])] },
    Group { title: "Tags", rows: &[switch("Enabled", &["tags", "enabled"]), switch("Show in Web Sidebar", &["tags", "sidebarWeb"])] },
    Group {
        title: "People",
        rows: &[
            switch("Enabled", &["people", "enabled"]),
            switch("Show in Web Sidebar", &["people", "sidebarWeb"]),
            Row { title: "Minimum Faces", path: &["people", "minimumFaces"], control: Control::Number { min: 1, max: 1000 } },
            Row { title: "People Update Strategy", path: &["people", "updateStrategy"], control: Control::Choice(&[("self", "Only This Person"), ("everyone", "Everyone")]) },
        ],
    },
    Group { title: "Shared Links", rows: &[switch("Enabled", &["sharedLinks", "enabled"]), switch("Show in Web Sidebar", &["sharedLinks", "sidebarWeb"])] },
    Group { title: "Albums", rows: &[Row { title: "Default Album Order", path: &["albums", "defaultAssetOrder"], control: Control::Choice(&[("desc", "Newest First"), ("asc", "Oldest First")]) }] },
    Group { title: "Downloads", rows: &[Row { title: "Archive Size (GiB)", path: &["download", "archiveSize"], control: Control::GibiBytes }, switch("Include Embedded Videos", &["download", "includeEmbeddedVideos"])] },
    Group {
        title: "Email Notifications",
        rows: &[switch("Enable Email Notifications", &["emailNotifications", "enabled"]), switch("Album Invitations", &["emailNotifications", "albumInvite"]), switch("Album Updates", &["emailNotifications", "albumUpdate"])],
    },
    Group {
        title: "Other",
        rows: &[switch("Google Cast", &["cast", "gCastEnabled"]), switch("Recently Added in Web Sidebar", &["recentlyAdded", "sidebarWeb"]), switch("Show Support Badge", &["purchase", "showSupportBadge"])],
    },
];

pub const GIBIBYTE: u64 = 1 << 30;

/// The value at `path` in the server's answer, if it has one.
pub fn value<'a>(raw: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(raw, |value, key| value.get(key)).filter(|value| !value.is_null())
}

/// A patch that changes the value at `path` alone.
pub fn patch(path: &[&str], value: Value) -> Value {
    path.iter().rev().fold(value, |inner, key| {
        let mut object = Map::new();
        object.insert((*key).to_owned(), inner);
        Value::Object(object)
    })
}

/// The groups and rows the server has values for.
pub fn shown(raw: &Value) -> Vec<(&'static Group, Vec<&'static Row>)> {
    GROUPS
        .iter()
        .filter_map(|group| {
            let rows: Vec<&Row> = group.rows.iter().filter(|row| value(raw, row.path).is_some()).collect();
            (!rows.is_empty()).then_some((group, rows))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_what_the_server_has_shows_and_a_change_is_sent_alone() {
        let raw = json!({ "memories": { "enabled": true, "duration": 5 }, "people": { "enabled": false, "sidebarWeb": null }, "download": { "archiveSize": 4294967296u64 } });
        assert_eq!(value(&raw, &["memories", "duration"]), Some(&json!(5)));
        assert_eq!(value(&raw, &["people", "sidebarWeb"]), None, "a null is no value");
        let groups: Vec<(&str, Vec<&str>)> = shown(&raw).into_iter().map(|(group, rows)| (group.title, rows.iter().map(|row| row.title).collect())).collect();
        assert_eq!(groups, [("Memories", vec!["Enabled", "Seconds per Photo"]), ("People", vec!["Enabled"]), ("Downloads", vec!["Archive Size (GiB)"])]);
        assert_eq!(patch(&["memories", "duration"], json!(8)), json!({ "memories": { "duration": 8 } }));
    }
}
