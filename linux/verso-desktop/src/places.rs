//! Places as cities, or grouped by country (the Mac gallery's `PlacesArrangement`, after Immich's web app): countries
//! by name, places without one last; within a country, the server's order.

/// A place: its city and country, and the photo that shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    pub city: String,
    pub country: String,
    pub photo_id: String,
}

/// A country and its places; `None` for places without a country.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Country {
    pub name: Option<String>,
    pub places: Vec<Place>,
}

pub fn countries(places: &[Place]) -> Vec<Country> {
    let mut countries: Vec<Country> = Vec::new();
    for place in places {
        let name = Some(place.country.clone()).filter(|country| !country.trim().is_empty());
        match countries.iter_mut().find(|country| country.name == name) {
            Some(country) => country.places.push(place.clone()),
            None => countries.push(Country { name, places: vec![place.clone()] }),
        }
    }
    countries.sort_by(|a, b| match (&a.name, &b.name) {
        (Some(x), Some(y)) => x.to_lowercase().cmp(&y.to_lowercase()),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    countries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(city: &str, country: &str) -> Place {
        Place { city: city.into(), country: country.into(), photo_id: format!("{city}-photo") }
    }

    #[test]
    fn countries_by_name_keep_their_places_order_and_the_unknown_comes_last() {
        let places = [place("Reykjavík", "Iceland"), place("Aarhus", "Denmark"), place("Somewhere", ""), place("Odense", "Denmark")];
        let countries = countries(&places);
        let names: Vec<_> = countries.iter().map(|country| country.name.clone()).collect();
        assert_eq!(names, [Some("Denmark".into()), Some("Iceland".into()), None]);
        let cities: Vec<_> = countries[0].places.iter().map(|place| place.city.as_str()).collect();
        assert_eq!(cities, ["Aarhus", "Odense"]);
    }
}
