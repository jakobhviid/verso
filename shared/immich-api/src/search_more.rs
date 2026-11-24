//! Search beyond metadata: smart search by words or by likeness, random Assets, counts, the largest Assets, the
//! explore page, search suggestions, and place names. Answers are [`AssetDetails`], read whole.
//!
//! Filters are an [`AssetQuery`] sent in the v3.2 dialect (`filter`), as metadata search sends it
//! ([`crate::search`]), so trashed Assets are left out here too. The deprecated flat fields are never mixed in: the
//! server refuses `filter` beside any of them (400 `Deprecated field country cannot be combined with filter`).
//!
//! Quirks, as of v3.3.6:
//! - smart search needs machine learning: without it the server answers 400 `Smart search is not enabled`
//!   ([`ApiError::Protocol`]). In the v3.2 dialect it has no paging (`page` is deprecated and cannot be combined
//!   with `filter`, and there is no cursor), so one call returns the `size` best matches, up to 1000
//! - explore lists groups by field: `exifInfo.city` (one Asset for each city with enough Assets) and `createdAt`
//!   (recent uploads); the groups of things recognised in pictures need machine learning
//! - `POST /search/large-assets` is deprecated (in favour of metadata search) and takes its filters in the query
//!   string, where the server refuses booleans and lists (`expected boolean, received string`), so only the
//!   minimum size and the visibility are offered; the largest come first, and trashed Assets are left out
//! - `GET /search/places` searches GeoNames, the whole world's place names, by fuzzy name, not the user's Assets
//! - `GET /search/cities` answers one Asset per city the user has Assets in

use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::asset::Visibility;
use crate::asset_info::AssetDetails;
use crate::client::Client;
use crate::error::ApiError;
use crate::search::{AssetQuery, MAX_PAGE_SIZE};
use crate::wire::{endpoints, wire_enum, Endpoint};

pub(crate) const ENDPOINTS: &[Endpoint] = endpoints![
    POST "/search/smart" "asset.read",
    POST "/search/random" "asset.read",
    POST "/search/statistics" "asset.statistics",
    POST "/search/large-assets" "asset.read",
    GET "/search/explore" "asset.read",
    GET "/search/places" "asset.read",
    GET "/search/cities" "asset.read",
];

wire_enum! {
    /// Which values [`Client::suggestions`] lists.
    pub enum SuggestionKind {
        Country = "country",
        State = "state",
        City = "city",
        CameraMake = "camera-make",
        CameraModel = "camera-model",
        LensModel = "camera-lens-model",
    }
}

/// What [`Client::suggestions`] lists: one kind of value, narrowed by the values chosen so far.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SuggestionQuery {
    pub kind: SuggestionKind,
    /// For states and cities: only those in this country.
    pub country: Option<String>,
    /// For cities: only those in this state.
    pub state: Option<String>,
    /// For camera and lens models: only those of this make.
    pub camera_make: Option<String>,
    /// For lens models: only those used with this camera model.
    pub camera_model: Option<String>,
}

/// What smart search looks for: words, or Assets that look like one, within a filter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SmartQuery {
    /// What to look for, in words ("dog on a beach").
    pub text: Option<String>,
    /// Or: Assets that look like this Asset.
    pub similar_to: Option<String>,
    /// The language `text` is in (`de`, `ja`), for multilingual models.
    pub language: Option<String>,
    /// Conditions every result meets as well.
    pub filter: AssetQuery,
}

/// One group of the explore page: a field, and one Asset for each of its values.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ExploreGroup {
    /// `exifInfo.city`, `createdAt`, or with machine learning the fields of things recognised.
    pub field_name: String,
    pub items: Vec<ExploreItem>,
}

/// A value of an explore group, with an Asset that stands for it.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(default)]
pub struct ExploreItem {
    pub value: String,
    #[serde(rename = "data")]
    pub asset: AssetDetails,
}

/// A place in GeoNames that matches a name.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PlaceMatch {
    pub name: String,
    pub latitude: f64,
    pub longitude: f64,
    /// The region it is in (a state, a province).
    #[serde(rename = "admin1name")]
    pub region: Option<String>,
    /// The smaller area it is in (a county, a municipality).
    #[serde(rename = "admin2name")]
    pub district: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SearchAnswerWire {
    assets: SearchAssetsWire,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct SearchAssetsWire {
    items: Vec<AssetDetails>,
    next_cursor: Option<String>,
    next_page: Option<String>,
}

/// A gallery's search in the flat fields Immich's web app sends (`POST /search/metadata`, or `/search/smart` with
/// words), with every filter of its search panel and page or cursor paging ([`Client::flat_search`]). Immich 3.3
/// deprecates the flat fields in favour of `filter` ([`AssetQuery`]) but its own web client still sends them, and
/// only they page smart search. A field left `None` is left out.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlatSearch {
    /// The words of a smart search.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ocr: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub person_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub city: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub make: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lens_model: Option<String>,
    /// As ISO 8601 text, the instants the search panel chose.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taken_after: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub taken_before: Option<String>,
    /// `IMAGE` or `VIDEO`.
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visibility: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_favorite: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_not_in_album: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    pub size: u32,
    /// `asc` or `desc`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub with_exif: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub with_stacked: Option<bool>,
}

/// One page of a [`FlatSearch`]: its Assets, read whole, and the way to the next page, by number or by cursor.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FlatSearchPage {
    pub assets: Vec<AssetDetails>,
    pub next_page: Option<String>,
    pub next_cursor: Option<String>,
}

/// What a text search looks in ([`Client::search_text`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextField {
    /// The file's name when it was uploaded.
    FileName,
    /// The description.
    Description,
    /// Text recognised in the picture (OCR), with machine learning on the server.
    Ocr,
}

impl TextField {
    fn key(self) -> &'static str {
        match self {
            TextField::FileName => "originalFileName",
            TextField::Description => "description",
            TextField::Ocr => "ocr",
        }
    }
}

/// One page of a metadata search with every Asset read whole ([`Client::search_details`]).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DetailsPage {
    pub assets: Vec<AssetDetails>,
    /// Pass this to get the next page; `None` on the last page.
    pub next_cursor: Option<String>,
}

impl SmartQuery {
    fn to_body(&self, size: u32) -> Value {
        let mut body = json!({
            "filter": self.filter.to_filter(),
            "size": size.clamp(1, MAX_PAGE_SIZE),
            "withExif": true,
        });
        if let Some(text) = &self.text {
            body["query"] = Value::String(text.clone());
        }
        if let Some(asset_id) = &self.similar_to {
            body["queryAssetId"] = Value::String(asset_id.clone());
        }
        if let Some(language) = &self.language {
            body["language"] = Value::String(language.clone());
        }
        body
    }
}

impl Client {
    /// One page of Assets matching `query`, each read whole, with its size, ThumbHash and EXIF (`POST
    /// /search/metadata`), for a grid that lays them out as they are shaped. `page_size` is clamped to 1..=1000.
    /// Needs `asset.read`.
    pub async fn search_details(&self, query: &AssetQuery, page_size: u32, cursor: Option<&str>) -> Result<DetailsPage, ApiError> {
        let answer: SearchAnswerWire = self.post_json(&["search", "metadata"], &query.to_body(page_size, cursor)).await?;
        Ok(DetailsPage { assets: answer.assets.items, next_cursor: answer.assets.next_cursor.filter(|cursor| !cursor.is_empty()) })
    }

    /// One page of a gallery's search (`POST /search/smart` when `smart`, else `/search/metadata`), as the search
    /// panel asks it. Needs `asset.read`, and machine learning on the server for smart search.
    pub async fn flat_search(&self, search: &FlatSearch, smart: bool) -> Result<FlatSearchPage, ApiError> {
        let endpoint = if smart { "smart" } else { "metadata" };
        let answer: SearchAnswerWire = self.post_json(&["search", endpoint], search).await?;
        Ok(FlatSearchPage {
            assets: answer.assets.items,
            next_page: answer.assets.next_page.filter(|page| !page.is_empty()),
            next_cursor: answer.assets.next_cursor.filter(|cursor| !cursor.is_empty()),
        })
    }

    /// Up to `size` (at most 1000) Assets, newest first, whose file name, description or recognised text contains
    /// `text` (`POST /search/metadata` with the flat fields Immich's web app sends, which the `filter` dialect does
    /// not have; trashed Assets stay out). Needs `asset.read`.
    pub async fn search_text(&self, field: TextField, text: &str, size: u32) -> Result<Vec<AssetDetails>, ApiError> {
        let mut body = serde_json::Map::new();
        body.insert(field.key().to_owned(), Value::String(text.to_owned()));
        body.insert("size".to_owned(), json!(size.clamp(1, MAX_PAGE_SIZE)));
        body.insert("withExif".to_owned(), json!(true));
        body.insert("order".to_owned(), json!("desc"));
        let answer: SearchAnswerWire = self.post_json(&["search", "metadata"], &Value::Object(body)).await?;
        Ok(answer.assets.items)
    }

    /// The `size` (up to 1000) Assets that best match words or look most like an Asset, best first
    /// (`POST /search/smart`). Needs machine learning on the server, and `asset.read`.
    pub async fn smart_search(&self, query: &SmartQuery, size: u32) -> Result<Vec<AssetDetails>, ApiError> {
        let answer: SearchAnswerWire = self
            .call_with(Method::POST, &["search", "smart"], &[], &query.to_body(size))
            .await?;
        Ok(answer.assets.items)
    }

    /// Up to `size` (at most 1000) Assets that match, picked at random (`POST /search/random`). Needs `asset.read`.
    pub async fn random_assets(&self, filter: &AssetQuery, size: u32) -> Result<Vec<AssetDetails>, ApiError> {
        let body = json!({
            "filter": filter.to_filter(),
            "size": size.clamp(1, MAX_PAGE_SIZE),
            "withExif": true,
        });
        self.call_with(Method::POST, &["search", "random"], &[], &body).await
    }

    /// How many Assets match (`POST /search/statistics`). Needs `asset.statistics`.
    pub async fn count_assets(&self, filter: &AssetQuery) -> Result<u64, ApiError> {
        #[derive(Deserialize, Default)]
        #[serde(default)]
        struct Statistics {
            total: u64,
        }
        let body = json!({ "filter": filter.to_filter() });
        let answer: Statistics = self.call_with(Method::POST, &["search", "statistics"], &[], &body).await?;
        Ok(answer.total)
    }

    /// The largest Assets of at least `min_file_size` bytes, largest first, up to `size` (at most 1000)
    /// (`POST /search/large-assets`, deprecated). Needs `asset.read`.
    pub async fn large_assets(
        &self,
        min_file_size: u64,
        visibility: Option<&Visibility>,
        size: u32,
    ) -> Result<Vec<AssetDetails>, ApiError> {
        let min_file_size = min_file_size.to_string();
        let size = size.clamp(1, MAX_PAGE_SIZE).to_string();
        let mut query = vec![("minFileSize", min_file_size.as_str()), ("size", size.as_str())];
        if let Some(visibility) = visibility {
            query.push(("visibility", visibility.as_str()));
        }
        self.call(Method::POST, &["search", "large-assets"], &query).await
    }

    /// The groups of the explore page (`GET /search/explore`). Needs `asset.read`.
    pub async fn explore(&self) -> Result<Vec<ExploreGroup>, ApiError> {
        self.call(Method::GET, &["search", "explore"], &[]).await
    }

    /// One Asset for each city the user has Assets in (`GET /search/cities`). Needs `asset.read`.
    pub async fn city_assets(&self) -> Result<Vec<AssetDetails>, ApiError> {
        self.call(Method::GET, &["search", "cities"], &[]).await
    }

    /// Places anywhere in the world whose name is like `name` (`GET /search/places`). Needs `asset.read`.
    pub async fn search_places(&self, name: &str) -> Result<Vec<PlaceMatch>, ApiError> {
        self.call(Method::GET, &["search", "places"], &[("name", name)]).await
    }

    /// The values of one kind the user's Assets have, for a search form: countries, states, cities, camera makes,
    /// models and lenses (`GET /search/suggestions`). Assets without a value are not counted. Needs `asset.read`.
    pub async fn suggestions(&self, query: &SuggestionQuery) -> Result<Vec<String>, ApiError> {
        let mut parameters = vec![("type", query.kind.as_str())];
        let narrowing = [
            ("country", &query.country),
            ("state", &query.state),
            ("make", &query.camera_make),
            ("model", &query.camera_model),
        ];
        for (name, value) in narrowing {
            if let Some(value) = value {
                parameters.push((name, value.as_str()));
            }
        }
        let suggestions: Vec<Option<String>> = self.call(Method::GET, &["search", "suggestions"], &parameters).await?;
        Ok(crate::place::names(suggestions))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::SEARCH_ITEM;
    use crate::test_server::{CannedResponse, FakeServer};

    #[test]
    fn smart_search_speaks_only_the_new_dialect() {
        let query = SmartQuery {
            text: Some("dog".to_owned()),
            filter: AssetQuery { city: Some("Lyon".to_owned()), ..AssetQuery::default() },
            ..SmartQuery::default()
        };
        assert_eq!(
            query.to_body(5000),
            json!({
                "query": "dog",
                "filter": { "trashedAt": { "eq": null }, "city": { "eq": "Lyon" } },
                "size": 1000,
                "withExif": true,
            })
        );
    }

    #[tokio::test]
    async fn smart_search_reads_its_assets_whole() {
        let answer = format!(
            r#"{{"albums":{{"total":0,"count":0,"items":[],"facets":[]}},
                "assets":{{"total":1,"count":1,"items":[{SEARCH_ITEM}],"facets":[],"nextPage":null}}}}"#
        );
        let server = FakeServer::start(vec![CannedResponse::json(200, &answer)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let query = SmartQuery { similar_to: Some("a1".to_owned()), ..SmartQuery::default() };
        let assets = client.smart_search(&query, 10).await.unwrap();
        assert_eq!(assets[0].exif.as_ref().and_then(|exif| exif.city.as_deref()), Some("Reykjavík"));
        assert!(server.requests()[0].body_text().contains(r#""queryAssetId":"a1""#));
    }

    #[tokio::test]
    async fn a_flat_search_sends_only_what_is_set_and_reads_both_pagings() {
        let answer = r#"{"assets":{"items":[],"nextPage":"2","nextCursor":""}}"#;
        let server = FakeServer::start(vec![CannedResponse::json(200, answer), CannedResponse::json(200, answer)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let search = FlatSearch {
            query: Some("beach".to_owned()),
            kind: Some("IMAGE".to_owned()),
            person_ids: Some(vec!["p".to_owned()]),
            is_favorite: Some(true),
            page: Some(1),
            size: 100,
            ..FlatSearch::default()
        };
        let page = client.flat_search(&search, true).await.unwrap();
        assert_eq!((page.next_page.as_deref(), page.next_cursor), (Some("2"), None), "an empty cursor is none");
        let sent = &server.requests()[0];
        assert_eq!(sent.target, "/api/search/smart");
        let body: Value = serde_json::from_str(&sent.body_text()).unwrap();
        assert_eq!(body, json!({"query": "beach", "type": "IMAGE", "personIds": ["p"], "isFavorite": true, "page": 1, "size": 100}));
        client.flat_search(&FlatSearch { size: 10, ..FlatSearch::default() }, false).await.unwrap();
        assert_eq!(server.requests()[1].target, "/api/search/metadata");
    }

    #[tokio::test]
    async fn large_assets_send_their_filters_in_the_query() {
        let server = FakeServer::start(vec![CannedResponse::json(200, "[]")]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        client.large_assets(1_000_000, Some(&Visibility::Timeline), 20).await.unwrap();
        let request = &server.requests()[0];
        assert_eq!(request.method, "POST");
        assert_eq!(request.target, "/api/search/large-assets?minFileSize=1000000&size=20&visibility=timeline");
    }

    #[tokio::test]
    async fn suggestions_send_only_the_narrowing_that_is_set() {
        let server = FakeServer::start(vec![CannedResponse::json(200, r#"["EF 50mm",null]"#)]).await;
        let client = Client::new(&server.url, None, "test").unwrap();
        let query = SuggestionQuery {
            kind: SuggestionKind::LensModel,
            camera_make: Some("Canon".to_owned()),
            ..SuggestionQuery::default()
        };
        assert_eq!(client.suggestions(&query).await.unwrap(), ["EF 50mm"]);
        assert_eq!(server.requests()[0].target, "/api/search/suggestions?type=camera-lens-model&make=Canon");
    }

    #[test]
    fn explore_groups_and_places_decode() {
        let explore = format!(r#"[{{"fieldName":"exifInfo.city","items":[{{"value":"Reykjavík","data":{SEARCH_ITEM}}}]}}]"#);
        let groups: Vec<ExploreGroup> = crate::client::decode_json(explore.as_bytes(), "explore").unwrap();
        assert_eq!(groups[0].items[0].value, "Reykjavík");
        assert_eq!(groups[0].items[0].asset.id, "12ecb329-c96f-41b1-8406-e5b8fe134454");
        let places = r#"[{"name":"Odense","latitude":55.4,"longitude":10.38,"admin1name":"South Denmark","admin2name":null}]"#;
        let places: Vec<PlaceMatch> = crate::client::decode_json(places.as_bytes(), "places").unwrap();
        assert_eq!(places[0].region.as_deref(), Some("South Denmark"));
        assert_eq!(places[0].district, None);
    }
}
