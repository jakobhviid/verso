//! Places: Immich's list of cities, one photo for each, as cities or grouped by country (Immich's web app's places
//! page, PlacesList.svelte), sorted by when each was last visited, most recent or oldest first, or by name (after
//! Immich Gallery's `PlacesArrangement`). Linux's window, the Mac and the iPhone (through `verso-bridge`) all arrange
//! here. The order of names is the platform's (`names`), which knows the person's language, and a city's last visit is
//! the date of its newest photo, which the Mac and the iPhone read.

use std::cmp::Ordering;

use chrono::NaiveDateTime;

/// Cities alone, or a group for each country.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum GroupBy {
    #[default]
    None,
    Country,
}

impl GroupBy {
    pub const ALL: [GroupBy; 2] = [GroupBy::None, GroupBy::Country];

    /// Immich's names, which the choice is kept by on Linux and the Mac.
    pub fn code(self) -> &'static str {
        match self {
            GroupBy::None => "None",
            GroupBy::Country => "Country",
        }
    }

    pub fn from_code(code: &str) -> Option<GroupBy> {
        GroupBy::ALL.into_iter().find(|group_by| group_by.code() == code)
    }
}

/// How places are sorted: by when each was last visited, most recent first unless asked otherwise, or by name.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SortBy {
    #[default]
    RecentVisit,
    OldestVisit,
    Name,
}

impl SortBy {
    pub const ALL: [SortBy; 3] = [SortBy::RecentVisit, SortBy::OldestVisit, SortBy::Name];

    /// The codes the choice is kept by on the Mac and the iPhone.
    pub fn code(self) -> &'static str {
        match self {
            SortBy::RecentVisit => "RecentVisit",
            SortBy::OldestVisit => "OldestVisit",
            SortBy::Name => "Name",
        }
    }

    pub fn from_code(code: &str) -> Option<SortBy> {
        SortBy::ALL.into_iter().find(|sort| sort.code() == code)
    }
}

/// A city of Places, as the arrangement reads it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Place {
    pub city: String,
    /// Its country; none, or blank, where Immich knows none.
    pub country: Option<String>,
    /// When it was last visited, the date of its newest photo on the clock where it was taken; none when not known.
    pub visit: Option<NaiveDateTime>,
}

impl Place {
    fn country(&self) -> Option<&str> {
        self.country.as_deref().filter(|country| !country.trim().is_empty())
    }
}

/// A group's heading: a country, or the places without one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Header {
    Country(String),
    UnknownCountry,
}

/// A group of places, with its places by their index in the list arranged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    /// Stable across reads: `places`, `country-<name>` or `country-unknown`.
    pub id: String,
    /// None for the places ungrouped.
    pub header: Option<Header>,
    pub places: Vec<usize>,
}

/// Places' view options.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Arrangement {
    pub group_by: GroupBy,
    pub sort_by: SortBy,
}

impl Arrangement {
    /// The places (by index) in the chosen order, names ordered by `names`: a place whose visit is not known goes
    /// last, and places alike keep the list's order.
    pub fn sorted(&self, places: &[Place], names: impl Fn(&str, &str) -> Ordering) -> Vec<usize> {
        self.order((0..places.len()).collect(), places, &names)
    }

    /// The places grouped: all of them in one group without a header, or a group for each country, ordered by its
    /// visit (its most recent city's, or sorting by the oldest, its least recent city's) or by name, ties by name, and
    /// the places without a country last. Within each group the places are sorted as `sorted` sorts them.
    pub fn groups(&self, places: &[Place], names: impl Fn(&str, &str) -> Ordering) -> Vec<Group> {
        if places.is_empty() {
            return Vec::new();
        }
        if self.group_by == GroupBy::None {
            return vec![Group { id: "places".to_owned(), header: None, places: self.sorted(places, &names) }];
        }
        let mut countries: Vec<(Option<&str>, Vec<usize>)> = Vec::new();
        for (index, place) in places.iter().enumerate() {
            match countries.iter_mut().find(|(country, _)| *country == place.country()) {
                Some((_, members)) => members.push(index),
                None => countries.push((place.country(), vec![index])),
            }
        }
        let visited = |members: &[usize]| {
            let visits = members.iter().filter_map(|member| places[*member].visit);
            if self.sort_by == SortBy::OldestVisit { visits.min() } else { visits.max() }
        };
        let mut countries: Vec<(Option<&str>, Vec<usize>, Option<NaiveDateTime>)> = countries
            .into_iter()
            .map(|(country, members)| {
                let visit = visited(&members);
                (country, members, visit)
            })
            .collect();
        countries.sort_by(|(first, _, first_visit), (second, _, second_visit)| match (first, second) {
            (Some(first), Some(second)) => {
                let by_visit = if self.sort_by == SortBy::Name { Ordering::Equal } else { self.by_visit(*first_visit, *second_visit) };
                by_visit.then_with(|| names(first, second))
            }
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        });
        countries
            .into_iter()
            .map(|(country, members, _)| Group {
                id: country.map_or("country-unknown".to_owned(), |country| format!("country-{country}")),
                header: Some(country.map_or(Header::UnknownCountry, |country| Header::Country(country.to_owned()))),
                places: self.order(members, places, &names),
            })
            .collect()
    }

    /// The members (by index, in the list's order) sorted; a stable sort, so places alike keep the list's order.
    fn order(&self, mut members: Vec<usize>, places: &[Place], names: &impl Fn(&str, &str) -> Ordering) -> Vec<usize> {
        members.sort_by(|first, second| {
            let (first, second) = (&places[*first], &places[*second]);
            match self.sort_by {
                SortBy::Name => names(&first.city, &second.city),
                SortBy::RecentVisit | SortBy::OldestVisit => self.by_visit(first.visit, second.visit),
            }
        });
        members
    }

    /// Two visits in the chosen order, an unknown one last.
    fn by_visit(&self, first: Option<NaiveDateTime>, second: Option<NaiveDateTime>) -> Ordering {
        match (first, second) {
            (Some(first), Some(second)) if self.sort_by == SortBy::OldestVisit => first.cmp(&second),
            (Some(first), Some(second)) => second.cmp(&first),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::names::caseless;
    use chrono::{Duration, NaiveDate};

    fn place(city: &str, country: Option<&str>) -> Place {
        Place { city: city.to_owned(), country: country.map(str::to_owned), visit: None }
    }

    /// The places as the server sends them, by city name.
    fn server() -> Vec<Place> {
        vec![
            place("Aarhus", Some("Denmark")),
            place("Atlantis", None),
            place("Bologna", Some("Italy")),
            place("Copenhagen", Some("Denmark")),
            place("Ys", Some("")),
            place("Århus", Some("australia")),
        ]
    }

    /// When each city was last visited, by days after a first; Atlantis is not known.
    fn visited(mut places: Vec<Place>) -> Vec<Place> {
        let first = NaiveDate::from_ymd_opt(2023, 11, 14).unwrap().and_hms_opt(22, 13, 20).unwrap();
        for place in &mut places {
            let days = match place.city.as_str() {
                "Aarhus" => 1,
                "Bologna" => 9,
                "Copenhagen" => 5,
                "Ys" => 3,
                "Århus" => 7,
                _ => continue,
            };
            place.visit = Some(first + Duration::days(days));
        }
        places
    }

    /// Names as English orders them: Å beside A.
    fn english(first: &str, second: &str) -> Ordering {
        let folded = |name: &str| name.to_lowercase().replace('å', "a");
        folded(first).cmp(&folded(second)).then_with(|| caseless(first, second))
    }

    fn arrangement(group_by: GroupBy, sort_by: SortBy) -> Arrangement {
        Arrangement { group_by, sort_by }
    }

    fn headers(groups: &[Group]) -> Vec<Option<Header>> {
        groups.iter().map(|group| group.header.clone()).collect()
    }

    fn country(name: &str) -> Option<Header> {
        Some(Header::Country(name.to_owned()))
    }

    #[test]
    fn ungrouped_places_are_one_group_without_a_header_in_the_servers_order_until_visits_are_known() {
        let groups = Arrangement::default().groups(&server(), caseless);
        assert_eq!(groups, [Group { id: "places".to_owned(), header: None, places: vec![0, 1, 2, 3, 4, 5] }]);
        assert!(arrangement(GroupBy::Country, SortBy::RecentVisit).groups(&[], caseless).is_empty());
        assert!(Arrangement::default().groups(&[], caseless).is_empty());
    }

    #[test]
    fn countries_go_by_name_case_aside_and_the_places_without_one_last() {
        let groups = arrangement(GroupBy::Country, SortBy::RecentVisit).groups(&server(), caseless);
        assert_eq!(headers(&groups), [country("australia"), country("Denmark"), country("Italy"), Some(Header::UnknownCountry)]);
        assert_eq!(groups.iter().map(|group| group.id.as_str()).collect::<Vec<_>>(), ["country-australia", "country-Denmark", "country-Italy", "country-unknown"]);
        assert_eq!(groups[1].places, [0, 3]);
        assert_eq!(groups[3].places, [1, 4], "an empty country is none");
    }

    #[test]
    fn places_sort_by_their_last_visit_and_one_not_known_goes_last() {
        let places = visited(server());
        assert_eq!(Arrangement::default().groups(&places, caseless)[0].places, [2, 5, 3, 4, 0, 1]);
        assert_eq!(arrangement(GroupBy::None, SortBy::OldestVisit).sorted(&places, caseless), [0, 4, 3, 5, 2, 1]);
    }

    #[test]
    fn places_sort_by_name_in_the_order_the_platform_gives_names() {
        let mut places = visited(server());
        places.reverse();
        let cities = |names: fn(&str, &str) -> Ordering| {
            arrangement(GroupBy::None, SortBy::Name).sorted(&places, names).into_iter().map(|index| places[index].city.as_str()).collect::<Vec<_>>()
        };
        assert_eq!(cities(caseless), ["Aarhus", "Atlantis", "Bologna", "Copenhagen", "Ys", "Århus"], "Å after Z, as Danish has it");
        assert_eq!(cities(english), ["Aarhus", "Århus", "Atlantis", "Bologna", "Copenhagen", "Ys"], "Å beside A, as English has it");
    }

    #[test]
    fn countries_follow_their_most_recent_city_or_sorting_by_the_oldest_their_least_recent() {
        let places = visited(server());
        let recent = arrangement(GroupBy::Country, SortBy::RecentVisit).groups(&places, caseless);
        assert_eq!(headers(&recent), [country("Italy"), country("australia"), country("Denmark"), Some(Header::UnknownCountry)]);
        assert_eq!(recent[2].places, [3, 0]);
        let oldest = arrangement(GroupBy::Country, SortBy::OldestVisit).groups(&places, caseless);
        assert_eq!(headers(&oldest), [country("Denmark"), country("australia"), country("Italy"), Some(Header::UnknownCountry)]);
        assert_eq!(oldest[0].places, [0, 3]);
        assert_eq!(oldest[3].places, [4, 1], "the unknown visit last within a group too");
    }

    #[test]
    fn countries_by_name_keep_alike_places_in_the_lists_order() {
        let places = [place("Reykjavík", Some("Iceland")), place("Aarhus", Some("Denmark")), place("Somewhere", Some(" ")), place("Odense", Some("Denmark"))];
        let groups = arrangement(GroupBy::Country, SortBy::Name).groups(&places, caseless);
        assert_eq!(headers(&groups), [country("Denmark"), country("Iceland"), Some(Header::UnknownCountry)]);
        assert_eq!(groups[0].places, [1, 3]);
        let twins = [place("Paris", Some("France")), place("paris", Some("France"))];
        assert_eq!(arrangement(GroupBy::None, SortBy::Name).sorted(&twins, caseless), [0, 1]);
    }

    #[test]
    fn the_choices_are_kept_by_their_codes() {
        for group_by in GroupBy::ALL {
            assert_eq!(GroupBy::from_code(group_by.code()), Some(group_by));
        }
        for sort_by in SortBy::ALL {
            assert_eq!(SortBy::from_code(sort_by.code()), Some(sort_by));
        }
        assert_eq!(GroupBy::from_code("Country"), Some(GroupBy::Country));
        assert_eq!(GroupBy::from_code("None"), Some(GroupBy::None));
        assert_eq!(SortBy::from_code("RecentVisit"), Some(SortBy::RecentVisit));
        assert_eq!(SortBy::from_code("Visit"), None);
    }
}
