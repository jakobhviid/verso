//! The map's look on Linux: the style the Immich server's map setting names (`mapLightStyleUrl`, `mapDarkStyleUrl`),
//! as Immich's web app draws it, read with what it points to (its source's TileJSON and its sprites) and made into a
//! style libshumate's vector renderer draws, with the credits its source asks for (ARCHITECTURE.md, "Verso's window",
//! the map). The window builds the renderer from it and shows the credits.
//!
//! What libshumate does not take is changed or left out here, so the rest draws: a TileJSON link is read and its
//! tiles written into the style; one vector source is kept, as libshumate draws one; 3D buildings
//! (`fill-extrusion`) are drawn as their footprints, as they show from straight above, the only way Verso's maps look;
//! layers of another kind it does not draw go (`raster`, `circle`, `heatmap`, `hillshade`); `is-supported-script` is
//! true, as Pango shapes every script; and a `text-font` that is an expression gives way to the list of fonts it
//! falls back on.

use std::time::Duration;

use reqwest::Url;
use serde_json::{Map, Value};
use verso_linux::i18n::tr;

/// The kinds of layer libshumate's vector renderer draws.
const DRAWN: [&str; 4] = ["background", "fill", "line", "symbol"];

/// How long a request for the style or a part of it may take.
const TIMEOUT: Duration = Duration::from_secs(20);

/// The map in the light or in the dark, following the desktop's style.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Look {
    Light,
    Dark,
}

impl Look {
    pub fn of(dark: bool) -> Look {
        if dark { Look::Dark } else { Look::Light }
    }

    /// The style's address in the server's map setting, for this look.
    pub fn address(self, config: &immich_api::ServerConfig) -> &str {
        match self {
            Look::Light => &config.map_light_style_url,
            Look::Dark => &config.map_dark_style_url,
        }
    }
}

/// A style ready for libshumate's renderer.
#[derive(Debug, Clone, PartialEq)]
pub struct MapStyle {
    /// The style as libshumate takes it.
    pub json: String,
    /// The credits the style's source asks for, as Pango markup with their links; empty when it names none.
    pub credits: String,
    /// The host the tiles come from, as a message names it.
    pub tiles_host: String,
    /// The sprite sheet's pages, for the style's icons; none when the style has none or they could not be read.
    pub sprites: Vec<SpritePage>,
}

/// A page of a sprite sheet: its picture (PNG), its index (JSON) and the scale it is drawn for.
#[derive(Debug, Clone, PartialEq)]
pub struct SpritePage {
    pub picture: Vec<u8>,
    pub index: String,
    pub scale: f64,
}

/// Why the map has no style to draw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StyleError {
    /// The server's map setting names no style.
    NotSet,
    /// The server's map setting could not be read: why, as the window says an Immich error.
    Setting(String),
    /// The style, or its tiles' description, could not be fetched from its host: the host and why.
    Unreachable { host: String, reason: String },
    /// What the host sent is not a style that can be read.
    Unreadable { host: String, reason: String },
    /// A style libshumate cannot draw: the host and why.
    Unsupported { host: String, reason: String },
}

impl StyleError {
    /// What the map says in its place, as a sentence.
    pub fn said(&self) -> String {
        match self {
            StyleError::NotSet => tr("The Immich server's map setting names no map style.").to_owned(),
            StyleError::Setting(reason) => tr("The Immich server's map setting could not be read: {reason}.").replace("{reason}", reason),
            StyleError::Unreachable { host, reason } => tr("The map could not be loaded from {host}: {reason}.").replace("{host}", host).replace("{reason}", reason),
            StyleError::Unreadable { host, reason } => tr("The map's style from {host} could not be read: {reason}.").replace("{host}", host).replace("{reason}", reason),
            StyleError::Unsupported { host, reason } => tr("The map's style from {host} cannot be drawn here: {reason}.").replace("{host}", host).replace("{reason}", reason),
        }
    }
}

/// What the map says along its top when some of its tiles could not be loaded from `host`, for `reason` as libshumate
/// gives it (the network's words name the host already: "Could not connect to tiles.immich.cloud: ...").
pub fn tiles_failed(host: &str, reason: &str) -> String {
    let reason = without_error_number(reason.trim().trim_end_matches('.'));
    if host.is_empty() || reason.contains(host) {
        tr("Some of the map could not be loaded: {reason}.").replace("{reason}", &reason)
    } else {
        tr("Some of the map could not be loaded from {host}: {reason}.").replace("{host}", host).replace("{reason}", &reason)
    }
}

/// Read the style at `address` (the server's map setting, for one look) and what it points to, and make it drawable.
pub async fn load(address: &str) -> Result<MapStyle, StyleError> {
    let address = address.trim();
    if address.is_empty() {
        return Err(StyleError::NotSet);
    }
    let style_url = Url::parse(address).map_err(|error| StyleError::Unreadable { host: address.to_owned(), reason: error.to_string() })?;
    let host = host_of(&style_url);
    let client = reqwest::Client::builder()
        .user_agent(verso_core::product::user_agent())
        .timeout(TIMEOUT)
        .build()
        .map_err(|error| StyleError::Unreachable { host: host.clone(), reason: error.to_string() })?;
    let style: Value = serde_json::from_slice(&fetch(&client, &style_url).await?).map_err(|error| StyleError::Unreadable { host: host.clone(), reason: error.to_string() })?;
    let source = chosen_source(&style).map_err(|reason| StyleError::Unsupported { host: host.clone(), reason })?;
    let tile_json = match tile_json_address(&style, &source, &style_url).map_err(|reason| StyleError::Unsupported { host: host.clone(), reason })? {
        Some(url) => {
            let host = host_of(&url);
            let body = fetch(&client, &url).await?;
            Some(serde_json::from_slice::<Value>(&body).map_err(|error| StyleError::Unreadable { host, reason: error.to_string() })?)
        }
        None => None,
    };
    let sprite = sprite_address(&style, &style_url);
    let (style, attribution) = prepare(style, &source, tile_json.as_ref()).map_err(|reason| StyleError::Unsupported { host: host.clone(), reason })?;
    let tiles_host = style["sources"][source.as_str()]["tiles"][0].as_str().and_then(|template| Url::parse(template).ok()).map(|url| host_of(&url)).unwrap_or_default();
    let sprites = match sprite {
        Some(sprite) => sprite_pages(&client, &sprite).await,
        None => Vec::new(),
    };
    Ok(MapStyle { json: style.to_string(), credits: credits_markup(&attribution), tiles_host, sprites })
}

/// A URL's host, as a message names where something came from.
fn host_of(url: &Url) -> String {
    url.host_str().unwrap_or(url.as_str()).to_owned()
}

/// The body at `url`, or why it could not be had.
async fn fetch(client: &reqwest::Client, url: &Url) -> Result<Vec<u8>, StyleError> {
    let unreachable = |reason: String| StyleError::Unreachable { host: host_of(url), reason };
    let response = client.get(url.clone()).send().await.map_err(|error| unreachable(transport_reason(&error)))?;
    let status = response.status();
    if !status.is_success() {
        return Err(unreachable(format!("HTTP {}", status.as_u16())));
    }
    let body = response.bytes().await.map_err(|error| unreachable(transport_reason(&error)))?;
    Ok(body.to_vec())
}

/// The innermost cause of a failed request, which names what went wrong ("Connection refused", a name not found),
/// without the address or the system's error number.
fn transport_reason(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        return tr("it took too long").to_owned();
    }
    let mut reason = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(inner) = source {
        reason = inner.to_string();
        source = inner.source();
    }
    without_error_number(&reason)
}

/// "Connection refused (os error 111)" as "Connection refused".
fn without_error_number(reason: &str) -> String {
    match reason.rfind(" (os error ") {
        Some(start) if reason.ends_with(')') => reason[..start].to_owned(),
        _ => reason.to_owned(),
    }
}

/// The sprite sheet's pages at `base` (`base.json` with `base.png`, and `@2x` for screens that scale by two); a page
/// that cannot be read is left out, and the icons on it are not drawn.
async fn sprite_pages(client: &reqwest::Client, base: &Url) -> Vec<SpritePage> {
    let mut pages = Vec::new();
    for (suffix, scale) in [("", 1.0), ("@2x", 2.0)] {
        let (Ok(index_url), Ok(picture_url)) = (Url::parse(&format!("{base}{suffix}.json")), Url::parse(&format!("{base}{suffix}.png"))) else { continue };
        let (Ok(index), Ok(picture)) = (fetch(client, &index_url).await, fetch(client, &picture_url).await) else { continue };
        if let Ok(index) = String::from_utf8(index) {
            pages.push(SpritePage { picture, index, scale });
        }
    }
    pages
}

/// The source the style is drawn from: libshumate draws one, so the vector source most of the layers use.
pub fn chosen_source(style: &Value) -> Result<String, String> {
    let sources = style.get("sources").and_then(Value::as_object).filter(|sources| !sources.is_empty()).ok_or_else(|| tr("it names no tiles").to_owned())?;
    let vector: Vec<&String> = sources.iter().filter(|(_, source)| source.get("type").and_then(Value::as_str) == Some("vector")).map(|(name, _)| name).collect();
    let uses = |name: &str| style.get("layers").and_then(Value::as_array).map_or(0, |layers| layers.iter().filter(|layer| layer.get("source").and_then(Value::as_str) == Some(name)).count());
    vector
        .iter()
        .max_by_key(|name| uses(name))
        .map(|name| (*name).clone())
        .ok_or_else(|| tr("it has no vector tiles, and libshumate draws only those").to_owned())
}

/// Where the source's TileJSON is, when the style links to it rather than naming its tiles itself.
pub fn tile_json_address(style: &Value, source: &str, style_url: &Url) -> Result<Option<Url>, String> {
    let definition = &style["sources"][source];
    if definition.get("tiles").and_then(Value::as_array).is_some_and(|tiles| !tiles.is_empty()) {
        return Ok(None);
    }
    let Some(link) = definition.get("url").and_then(Value::as_str) else {
        return Err(tr("its tiles have no address").to_owned());
    };
    let url = style_url.join(link).map_err(|error| error.to_string())?;
    if !matches!(url.scheme(), "https" | "http") {
        return Err(tr("its tiles are at a {scheme} address, which libshumate cannot read").replace("{scheme}", url.scheme()));
    }
    Ok(Some(url))
}

/// Where the style's sprite sheet is, without `.json` or `.png`: a style's `sprite`, or the default of a list of them.
pub fn sprite_address(style: &Value, style_url: &Url) -> Option<Url> {
    let address = match style.get("sprite")? {
        Value::String(address) => address.as_str(),
        Value::Array(sprites) => sprites.iter().find(|sprite| sprite.get("id").and_then(Value::as_str) == Some("default"))?.get("url")?.as_str()?,
        _ => return None,
    };
    style_url.join(address).ok().filter(|url| matches!(url.scheme(), "https" | "http"))
}

/// The style as libshumate draws it, and its source's attribution (HTML, as MapLibre takes it): `source` alone, its
/// tiles written in from `tile_json` when the style links to them; the layers libshumate draws, of that source; and
/// their expressions as it reads them (the module's header).
pub fn prepare(mut style: Value, source: &str, tile_json: Option<&Value>) -> Result<(Value, String), String> {
    let definition = style["sources"][source].as_object().cloned().unwrap_or_default();
    let described = tile_json.and_then(Value::as_object).cloned().unwrap_or_default();
    let field = |name: &str| definition.get(name).or_else(|| described.get(name)).cloned();
    let tiles: Vec<Value> = field("tiles").and_then(|tiles| tiles.as_array().cloned()).unwrap_or_default();
    let Some(template) = tiles.first().and_then(Value::as_str) else {
        return Err(tr("its tiles have no address").to_owned());
    };
    if !(template.starts_with("https://") || template.starts_with("http://")) {
        return Err(tr("its tiles are not at a web address").to_owned());
    }
    if field("scheme").and_then(|scheme| scheme.as_str().map(str::to_owned)).as_deref() == Some("tms") {
        return Err(tr("its tiles are numbered from the south (TMS), which libshumate does not read").to_owned());
    }
    let mut drawn = Map::new();
    drawn.insert("type".to_owned(), Value::from("vector"));
    drawn.insert("tiles".to_owned(), Value::from(vec![Value::from(template)]));
    drawn.insert("minzoom".to_owned(), field("minzoom").filter(Value::is_number).unwrap_or(Value::from(0)));
    drawn.insert("maxzoom".to_owned(), field("maxzoom").filter(Value::is_number).unwrap_or(Value::from(14)));
    let attribution = field("attribution").and_then(|attribution| attribution.as_str().map(str::to_owned)).unwrap_or_default();
    let mut sources = Map::new();
    sources.insert(source.to_owned(), Value::Object(drawn));
    style["sources"] = Value::Object(sources);
    let layers: Vec<Value> = style
        .get("layers")
        .and_then(Value::as_array)
        .map(|layers| {
            layers
                .iter()
                .map(|layer| footprints(layer.clone()))
                .filter(|layer| DRAWN.contains(&layer.get("type").and_then(Value::as_str).unwrap_or("")))
                .filter(|layer| match layer.get("source").and_then(Value::as_str) {
                    Some(name) => name == source,
                    None => layer.get("type").and_then(Value::as_str) == Some("background"),
                })
                .map(readable)
                .collect()
        })
        .unwrap_or_default();
    style["layers"] = Value::from(layers);
    Ok((style, attribution))
}

/// A `fill-extrusion` layer as a `fill` of the same colour and opacity: buildings as they show from straight above.
/// Any other layer as it is.
fn footprints(mut layer: Value) -> Value {
    if layer.get("type").and_then(Value::as_str) != Some("fill-extrusion") {
        return layer;
    }
    layer["type"] = Value::from("fill");
    let mut paint = Map::new();
    if let Some(extruded) = layer.get("paint").and_then(Value::as_object) {
        for (from, to) in [("fill-extrusion-color", "fill-color"), ("fill-extrusion-opacity", "fill-opacity")] {
            if let Some(value) = extruded.get(from) {
                paint.insert(to.to_owned(), value.clone());
            }
        }
    }
    layer["paint"] = Value::Object(paint);
    layer
}

/// A layer as libshumate reads it: `is-supported-script` is true, and a `text-font` expression its fallback list.
fn readable(mut layer: Value) -> Value {
    supported_scripts(&mut layer);
    if let Some(fonts) = layer.get_mut("layout").and_then(|layout| layout.get_mut("text-font")) {
        let names = |value: &Value| value.as_array().is_some_and(|names| names.iter().all(Value::is_string));
        if !names(fonts) {
            let mut lists = Vec::new();
            font_lists(fonts, &mut lists);
            match lists.pop() {
                Some(list) => *fonts = list,
                None => {
                    if let Some(layout) = layer.get_mut("layout").and_then(Value::as_object_mut) {
                        layout.remove("text-font");
                    }
                }
            }
        }
    }
    layer
}

/// Every `["is-supported-script", ...]` made `true`: MapLibre asks it to choose a name its renderer can shape, and
/// Pango shapes every script the computer has fonts for.
fn supported_scripts(value: &mut Value) {
    match value {
        Value::Array(items) => {
            if items.first().and_then(Value::as_str) == Some("is-supported-script") {
                *value = Value::Bool(true);
            } else {
                items.iter_mut().for_each(supported_scripts);
            }
        }
        Value::Object(fields) => fields.values_mut().for_each(supported_scripts),
        _ => {}
    }
}

/// The literal lists of font names in an expression, in order: in `case` and `match`, the last is the fallback.
fn font_lists(value: &Value, lists: &mut Vec<Value>) {
    if let Value::Array(items) = value {
        if items.first().and_then(Value::as_str) == Some("literal") {
            if let Some(list) = items.get(1).filter(|list| list.as_array().is_some_and(|names| !names.is_empty() && names.iter().all(Value::is_string))) {
                lists.push(list.clone());
                return;
            }
        }
        items.iter().for_each(|item| font_lists(item, lists));
    }
}

/// The layer libshumate refused, named in its error ("layer 'roads': Unrecognized operator ..."), so the window can
/// leave that layer out and draw the rest.
pub fn refused_layer(message: &str) -> Option<&str> {
    let rest = message.strip_prefix("layer '")?;
    let end = rest.find("': ")?;
    Some(&rest[..end])
}

/// The style without the layer `id`; `None` when it has no such layer.
pub fn without_layer(json: &str, id: &str) -> Option<String> {
    let mut style: Value = serde_json::from_str(json).ok()?;
    let layers = style.get_mut("layers")?.as_array_mut()?;
    let before = layers.len();
    layers.retain(|layer| layer.get("id").and_then(Value::as_str) != Some(id));
    (layers.len() < before).then(|| style.to_string())
}

/// A source's attribution, HTML as MapLibre shows it (`<a href="...">&copy; OpenStreetMap</a>`), as Pango markup: its
/// links kept where they go to the web, every other tag left out, and its entities read.
pub fn credits_markup(attribution: &str) -> String {
    let mut markup = String::new();
    let mut rest = attribution;
    let mut in_link = false;
    while !rest.is_empty() {
        match rest.find('<') {
            Some(start) => {
                markup.push_str(&escape(&entities(&rest[..start])));
                let Some(length) = rest[start..].find('>') else {
                    markup.push_str(&escape(&entities(&rest[start..])));
                    break;
                };
                let tag = rest[start + 1..start + length].trim();
                rest = &rest[start + length + 1..];
                let lower = tag.to_ascii_lowercase();
                if lower == "/a" {
                    if in_link {
                        markup.push_str("</a>");
                        in_link = false;
                    }
                } else if lower.starts_with("a ") || lower == "a" {
                    if in_link {
                        markup.push_str("</a>");
                        in_link = false;
                    }
                    if let Some(href) = attribute(tag, "href").map(|href| entities(&href)).filter(|href| href.starts_with("https://") || href.starts_with("http://")) {
                        markup.push_str(&format!("<a href=\"{}\">", escape(&href)));
                        in_link = true;
                    }
                } else if lower.starts_with("br") {
                    markup.push(' ');
                }
            }
            None => {
                markup.push_str(&escape(&entities(rest)));
                break;
            }
        }
    }
    if in_link {
        markup.push_str("</a>");
    }
    markup.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// An attribute's value in a tag's text (`a href="..." target="_blank"`), quoted with either quote or not at all.
fn attribute(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = lower[from..].find(name) {
        let at = from + found;
        from = at + name.len();
        let before = lower[..at].chars().last();
        if !before.is_some_and(char::is_whitespace) {
            continue;
        }
        let after = tag[from..].trim_start();
        let Some(value) = after.strip_prefix('=') else { continue };
        let value = value.trim_start();
        return Some(match value.chars().next() {
            Some(quote @ ('"' | '\'')) => value[1..].split(quote).next().unwrap_or("").to_owned(),
            _ => value.split_whitespace().next().unwrap_or("").to_owned(),
        });
    }
    None
}

/// HTML's entities read: the named ones attributions use, and numbers.
fn entities(text: &str) -> String {
    let mut read = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        read.push_str(&rest[..start]);
        rest = &rest[start..];
        let Some(end) = rest.find(';').filter(|end| *end <= 10) else {
            read.push('&');
            rest = &rest[1..];
            continue;
        };
        let name = &rest[1..end];
        let character = match name {
            "copy" => Some('\u{a9}'),
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            "mdash" => Some('-'),
            "ndash" => Some('-'),
            _ => name
                .strip_prefix("#x")
                .or_else(|| name.strip_prefix("#X"))
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .or_else(|| name.strip_prefix('#').and_then(|decimal| decimal.parse().ok()))
                .and_then(char::from_u32),
        };
        match character {
            Some(character) => {
                read.push(character);
                rest = &rest[end + 1..];
            }
            None => {
                read.push('&');
                rest = &rest[1..];
            }
        }
    }
    read.push_str(rest);
    read
}

/// Text made safe for Pango markup.
fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A style shaped as Immich's own (`tiles.immich.cloud`, Protomaps' basemap), cut down.
    fn immich_style() -> Value {
        json!({
            "version": 8,
            "name": "Immich Map",
            "sources": {"vector": {"type": "vector", "url": "https://tiles.immich.cloud/v1.json"}},
            "sprite": "https://static.immich.cloud/tiles/sprites/v4/light",
            "glyphs": "https://static.immich.cloud/tiles/fonts/v2/{fontstack}/{range}.pbf",
            "layers": [
                {"id": "background", "type": "background", "paint": {"background-color": "#cccccc"}},
                {"id": "earth", "type": "fill", "source": "vector", "source-layer": "earth"},
                {"id": "buildings_3d", "type": "fill-extrusion", "source": "vector", "source-layer": "buildings", "minzoom": 14,
                    "paint": {"fill-extrusion-color": "#d0cecc", "fill-extrusion-opacity": ["step", ["zoom"], 0, 15, 1], "fill-extrusion-height": 10}},
                {"id": "hills", "type": "hillshade", "source": "vector"},
                {"id": "places_locality", "type": "symbol", "source": "vector", "source-layer": "places", "layout": {
                    "text-font": ["case", ["<=", ["get", "min_zoom"], 5], ["literal", ["Noto Sans Medium"]], ["literal", ["Noto Sans Regular"]]],
                    "text-field": ["case", ["any", ["is-supported-script", ["get", "name"]], ["has", "pgf:name"]], ["get", "name"], ["get", "name:en"]]
                }}
            ]
        })
    }

    fn immich_tile_json() -> Value {
        json!({
            "tilejson": "3.0.0",
            "scheme": "xyz",
            "tiles": ["https://tiles.immich.cloud/v1/{z}/{x}/{y}.mvt?v=20261121"],
            "attribution": "<a href=\"https://www.openstreetmap.org/copyright\" target=\"_blank\">&copy; OpenStreetMap</a>",
            "minzoom": 0,
            "maxzoom": 15
        })
    }

    #[test]
    fn the_style_takes_its_tiles_from_the_tile_json() {
        let style = immich_style();
        let base = Url::parse("https://tiles.immich.cloud/v1/style/light.json").unwrap();
        assert_eq!(chosen_source(&style).unwrap(), "vector");
        assert_eq!(tile_json_address(&style, "vector", &base).unwrap().unwrap().as_str(), "https://tiles.immich.cloud/v1.json");
        let (prepared, attribution) = prepare(style, "vector", Some(&immich_tile_json())).unwrap();
        assert_eq!(
            prepared["sources"],
            json!({"vector": {"type": "vector", "tiles": ["https://tiles.immich.cloud/v1/{z}/{x}/{y}.mvt?v=20261121"], "minzoom": 0, "maxzoom": 15}})
        );
        assert!(attribution.contains("OpenStreetMap"));
    }

    #[test]
    fn what_libshumate_cannot_draw_is_left_out_or_read_its_way() {
        let (prepared, _) = prepare(immich_style(), "vector", Some(&immich_tile_json())).unwrap();
        let ids: Vec<&str> = prepared["layers"].as_array().unwrap().iter().map(|layer| layer["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["background", "earth", "buildings_3d", "places_locality"], "no hillshade");
        assert_eq!(
            prepared["layers"][2],
            json!({"id": "buildings_3d", "type": "fill", "source": "vector", "source-layer": "buildings", "minzoom": 14,
                "paint": {"fill-color": "#d0cecc", "fill-opacity": ["step", ["zoom"], 0, 15, 1]}}),
            "3D buildings as their footprints"
        );
        let places = &prepared["layers"][3]["layout"];
        assert_eq!(places["text-font"], json!(["Noto Sans Regular"]), "the case's fallback");
        assert_eq!(places["text-field"], json!(["case", ["any", true, ["has", "pgf:name"]], ["get", "name"], ["get", "name:en"]]));
    }

    #[test]
    fn one_vector_source_is_kept_with_its_layers() {
        let style = json!({
            "sources": {
                "openmaptiles": {"type": "vector", "tiles": ["https://tiles.example.org/{z}/{x}/{y}.pbf"], "maxzoom": 14, "attribution": "&copy; OpenMapTiles"},
                "hills": {"type": "raster-dem", "url": "https://tiles.example.org/dem.json"},
                "labels": {"type": "vector", "tiles": ["https://labels.example.org/{z}/{x}/{y}.pbf"]}
            },
            "layers": [
                {"id": "water", "type": "fill", "source": "openmaptiles"},
                {"id": "roads", "type": "line", "source": "openmaptiles"},
                {"id": "shade", "type": "hillshade", "source": "hills"},
                {"id": "names", "type": "symbol", "source": "labels"}
            ]
        });
        assert_eq!(chosen_source(&style).unwrap(), "openmaptiles");
        assert!(tile_json_address(&style, "openmaptiles", &Url::parse("https://example.org/style.json").unwrap()).unwrap().is_none(), "its tiles are in the style");
        let (prepared, attribution) = prepare(style, "openmaptiles", None).unwrap();
        assert_eq!(prepared["sources"].as_object().unwrap().len(), 1);
        assert_eq!(prepared["sources"]["openmaptiles"]["maxzoom"], json!(14));
        assert_eq!(prepared["layers"].as_array().unwrap().len(), 2);
        assert_eq!(attribution, "&copy; OpenMapTiles");
    }

    #[test]
    fn a_style_libshumate_cannot_draw_says_why() {
        let raster = json!({"sources": {"osm": {"type": "raster", "tiles": ["https://tile.example.org/{z}/{x}/{y}.png"]}}, "layers": [{"id": "osm", "type": "raster", "source": "osm"}]});
        assert!(chosen_source(&raster).is_err());
        assert!(chosen_source(&json!({"layers": []})).is_err());
        let pmtiles = json!({"sources": {"protomaps": {"type": "vector", "url": "pmtiles://https://example.org/planet.pmtiles"}}});
        assert!(tile_json_address(&pmtiles, "protomaps", &Url::parse("https://example.org/style.json").unwrap()).is_err());
        let tms = json!({"tiles": ["https://example.org/{z}/{x}/{y}.pbf"], "scheme": "tms"});
        assert!(prepare(immich_style(), "vector", Some(&tms)).is_err());
    }

    #[test]
    fn addresses_are_read_against_the_styles_own() {
        let base = Url::parse("https://maps.example.org/styles/light.json").unwrap();
        let style = json!({"sources": {"v": {"type": "vector", "url": "../tiles.json"}}, "sprite": "sprites/light"});
        assert_eq!(tile_json_address(&style, "v", &base).unwrap().unwrap().as_str(), "https://maps.example.org/tiles.json");
        assert_eq!(sprite_address(&style, &base).unwrap().as_str(), "https://maps.example.org/styles/sprites/light");
        let several = json!({"sprite": [{"id": "roads", "url": "https://a.example.org/roads"}, {"id": "default", "url": "https://a.example.org/default"}]});
        assert_eq!(sprite_address(&several, &base).unwrap().as_str(), "https://a.example.org/default");
        assert!(sprite_address(&json!({}), &base).is_none());
    }

    #[test]
    fn a_layer_libshumate_refuses_is_named_and_left_out() {
        assert_eq!(refused_layer("layer 'pois': Unrecognized operator is-supported-script"), Some("pois"));
        assert_eq!(refused_layer("ShumateVectorRenderer does not currently support multiple data sources"), None);
        let json = json!({"layers": [{"id": "a"}, {"id": "pois"}]}).to_string();
        let without: Value = serde_json::from_str(&without_layer(&json, "pois").unwrap()).unwrap();
        assert_eq!(without["layers"], json!([{"id": "a"}]));
        assert!(without_layer(&json, "missing").is_none(), "nothing to leave out ends the retries");
    }

    #[test]
    fn credits_keep_their_links_as_markup() {
        assert_eq!(
            credits_markup("<a href=\"https://www.openstreetmap.org/copyright\" target=\"_blank\">&copy; OpenStreetMap</a>"),
            "<a href=\"https://www.openstreetmap.org/copyright\">\u{a9} OpenStreetMap</a>"
        );
        assert_eq!(
            credits_markup("<a href='https://openmaptiles.org/'>&copy; OpenMapTiles</a> <a href=\"https://www.openstreetmap.org/copyright\">&copy; OpenStreetMap contributors</a>"),
            "<a href=\"https://openmaptiles.org/\">\u{a9} OpenMapTiles</a> <a href=\"https://www.openstreetmap.org/copyright\">\u{a9} OpenStreetMap contributors</a>"
        );
        assert_eq!(credits_markup("<b>Tiles</b> &amp; data &#169; Example <script>"), "Tiles &amp; data \u{a9} Example");
        assert_eq!(credits_markup("<a href=\"javascript:alert(1)\">Click</a>"), "Click", "only links to the web");
        assert_eq!(credits_markup(""), "");
    }

    #[test]
    fn the_setting_names_a_style_for_each_look() {
        let config = immich_api::ServerConfig {
            map_light_style_url: "https://tiles.immich.cloud/v1/style/light.json".to_owned(),
            map_dark_style_url: "https://tiles.immich.cloud/v1/style/dark.json".to_owned(),
            ..immich_api::ServerConfig::default()
        };
        assert!(Look::of(false).address(&config).ends_with("light.json"));
        assert!(Look::of(true).address(&config).ends_with("dark.json"));
    }

    #[test]
    fn failed_tiles_name_their_host_once() {
        assert_eq!(
            tiles_failed("tiles.immich.cloud", "Could not connect to tiles.immich.cloud: Connection refused"),
            "Some of the map could not be loaded: Could not connect to tiles.immich.cloud: Connection refused."
        );
        assert_eq!(
            tiles_failed("tiles.immich.cloud", "Unable to download tile: HTTP Not Found"),
            "Some of the map could not be loaded from tiles.immich.cloud: Unable to download tile: HTTP Not Found."
        );
    }

    #[test]
    fn a_reason_leaves_out_the_systems_error_number() {
        assert_eq!(without_error_number("Connection refused (os error 111)"), "Connection refused");
        assert_eq!(without_error_number("dns error: failed to lookup address information"), "dns error: failed to lookup address information");
    }

    #[tokio::test]
    async fn no_address_is_said_without_a_request() {
        assert_eq!(load("  ").await, Err(StyleError::NotSet));
        assert!(matches!(load("not an address").await, Err(StyleError::Unreadable { .. })));
    }
}
