//! Verso's Mac gallery talks to Immich through the core's client (ARCHITECTURE.md, "Verso on the Mac"). Its endpoint
//! calls are written in Swift against Immich's JSON (the app's `ImmichClient`, from Immich Gallery); each is composed
//! there and sent here, so the core's client adds the credential, the user agent, retries as the method allows and the
//! reachability gate, and the answer goes back as it came. Pictures, originals, videos and uploads still go through
//! the app's own URLSession.

use std::sync::Arc;

use immich_api::timeline::{BucketAsset, TimelineOptions, TimelineScope, YearMonth};
use immich_api::{
    Album, AlbumChanges, AlbumMember, AlbumRole, ApiError, AssetChanges, AssetDetails, AssetOrder, Client, ComposedRequest, Exif,
    FlatSearch, NewAlbum, NewMember, NewPerson, NewSharedLink, Partner, PartnerDirection, PeopleQuery, Person, PersonChanges, Secret,
    SharedLink, SharedLinkChanges, SharedLinkKind, User, Visibility,
};
use immich_api::account::{AccountChanges, AuthStatus, Proof};
use immich_api::admin::{Library, LibrarySettings, NewUser, Queue, QueueCommand, QueueName, UserChanges};
use immich_api::map::{MapMarker, MapQuery};
use immich_api::memory::{Memory, MemoryFilter};
use immich_api::tag::Tag;
use immich_api::{
    Activity, ActivityFilter, ActivityStatistics, AssetEdit, BulkIdResult, DuplicateGroup, DuplicateResolution, ExploreGroup, Face,
    ApiKey, MemoryChanges, MirrorAxis, Notification, NotificationFilter, ServerFeatures, Session, Stack, SuggestionKind, SuggestionQuery,
    TagChanges, UserDetails,
};

use crate::{failed, on_runtime, BridgeError, Credential};

/// A query item or a header: a name and its value.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApiField {
    pub name: String,
    pub value: String,
}

/// The server's answer, as it came, whatever its status.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ApiAnswer {
    pub status: u16,
    /// Names in lower case.
    pub headers: Vec<ApiField>,
    pub body: Vec<u8>,
}

/// One account's way to the API: the server and the credential, or none before signing in.
#[derive(uniffi::Object)]
pub struct ApiConnection {
    client: Client,
}

#[uniffi::export]
impl ApiConnection {
    /// `api` is the API's address (`/api` is added when it is missing, so the server's address does too).
    #[uniffi::constructor]
    pub fn new(api: String, credential: Option<Credential>) -> Result<Arc<ApiConnection>, BridgeError> {
        let credential = credential.map(|credential| credential.for_client());
        let client = crate::new_client(&api, credential).map_err(failed)?;
        Ok(Arc::new(ApiConnection { client }))
    }

    /// Send one request: `path` is the endpoint below the API's address, as `assets/{id}`, not percent-encoded. An
    /// error means no answer came: the server cannot be reached, or the request cannot be made.
    pub async fn send(
        &self,
        method: String,
        path: String,
        query: Vec<ApiField>,
        headers: Vec<ApiField>,
        body: Option<Vec<u8>>,
    ) -> Result<ApiAnswer, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let shown = format!("{method} {path}");
            let request = ComposedRequest { method, path, query: pairs(query), headers: pairs(headers), body };
            let answer = client.send_composed(request).await.map_err(|error| {
                log::info!("{shown}: no answer: {error}");
                unanswered(error)
            })?;
            // The endpoint and its status, never the query or the body: `log show --info` reads them.
            log::info!("{shown}: {}", answer.status);
            let headers = answer.headers.into_iter().map(|(name, value)| ApiField { name, value }).collect();
            Ok(ApiAnswer { status: answer.status, headers, body: answer.body.to_vec() })
        })
        .await
    }
}

// The typed calls (ARCHITECTURE.md, "Verso on the Mac"): immich-api's own requests and decoding, the Linux gallery's,
// in place of a Swift endpoint call, an area at a time. The timeline first.

/// Which timeline: immich-api's scopes, as the Mac app names its sources.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TimelineSource {
    /// The library, timeline visibility only.
    Library,
    /// The library as a gallery shows it: stacks as their primary Asset, with the partners' photos.
    LibraryStacked,
    Album { id: String },
    Person { id: String },
    Archive,
    Favorites,
    Trash,
    Locked,
    Tag { id: String },
    Partner { user_id: String },
}

/// How a timeline is narrowed and ordered.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct TimelineSettings {
    pub favorites_only: bool,
    pub oldest_first: bool,
    pub by_date_added: bool,
    /// Each stack as its primary Asset (`withStacked`).
    pub stacked: bool,
    /// Each Asset's coordinates, for the map.
    pub coordinates: bool,
}

/// One month of a timeline: its bucket key (`2025-03-01`, as Immich names it) and how many Assets it holds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TimelineMonth {
    pub bucket: String,
    pub count: u32,
}

/// One Asset of a month, as a grid lays it out.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TimelineAsset {
    pub id: String,
    /// When it was taken, in UTC, as Immich writes it (`2025-03-04T10:00:00.000Z`).
    pub file_created_at: String,
    pub local_offset_hours: f64,
    pub is_trashed: bool,
    /// `timeline`, `archive`, `hidden` or `locked`.
    pub visibility: String,
    pub is_image: bool,
    pub ratio: Option<f64>,
    pub thumbhash: Option<String>,
    pub is_favorite: bool,
    pub duration_ms: Option<u64>,
    pub live_photo_video_id: Option<String>,
    pub owner_id: Option<String>,
    /// The stack it heads, and how many Assets the stack holds.
    pub stack_id: Option<String>,
    pub stack_count: Option<u32>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub city: Option<String>,
    pub country: Option<String>,
}

impl From<TimelineSource> for TimelineScope {
    fn from(source: TimelineSource) -> TimelineScope {
        match source {
            TimelineSource::Library => TimelineScope::Library,
            TimelineSource::LibraryStacked => TimelineScope::LibraryStacked,
            TimelineSource::Album { id } => TimelineScope::Album(id),
            TimelineSource::Person { id } => TimelineScope::Person(id),
            TimelineSource::Archive => TimelineScope::Archive,
            TimelineSource::Favorites => TimelineScope::Favorites,
            TimelineSource::Trash => TimelineScope::Trash,
            TimelineSource::Locked => TimelineScope::Locked,
            TimelineSource::Tag { id } => TimelineScope::Tag(id),
            TimelineSource::Partner { user_id } => TimelineScope::Partner(user_id),
        }
    }
}

impl From<TimelineSettings> for TimelineOptions {
    fn from(settings: TimelineSettings) -> TimelineOptions {
        TimelineOptions {
            favorites_only: settings.favorites_only,
            oldest_first: settings.oldest_first,
            by_date_added: settings.by_date_added,
            stacked: settings.stacked,
        }
    }
}

impl From<BucketAsset> for TimelineAsset {
    fn from(asset: BucketAsset) -> TimelineAsset {
        let (stack_id, stack_count) = asset.stack.map_or((None, None), |(id, count)| (Some(id), Some(count)));
        let (latitude, longitude) = asset.coordinates.map_or((None, None), |(latitude, longitude)| (Some(latitude), Some(longitude)));
        TimelineAsset {
            id: asset.id,
            file_created_at: asset.file_created_at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            local_offset_hours: asset.local_offset_hours,
            is_trashed: asset.is_trashed,
            visibility: asset.visibility.as_str().to_owned(),
            is_image: asset.is_image,
            ratio: asset.ratio,
            thumbhash: asset.thumbhash,
            is_favorite: asset.is_favorite,
            duration_ms: asset.duration_ms,
            live_photo_video_id: asset.live_photo_video_id,
            owner_id: asset.owner_id,
            stack_id,
            stack_count,
            latitude,
            longitude,
            city: asset.city,
            country: asset.country,
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// A timeline's months, newest first unless `settings` say otherwise.
    pub async fn timeline_months(&self, source: TimelineSource, settings: TimelineSettings) -> Result<Vec<TimelineMonth>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let scope = TimelineScope::from(source);
            let months = client.time_buckets_with(&scope, &settings.into()).await.map_err(refused)?;
            log::info!("typed: the months of {scope:?}: {}", months.len());
            Ok(months.into_iter().map(|month| TimelineMonth { bucket: month.month.bucket_key(), count: month.count }).collect())
        })
        .await
    }

    /// One month of a timeline, by its bucket key.
    pub async fn timeline_month(&self, source: TimelineSource, settings: TimelineSettings, bucket: String) -> Result<Vec<TimelineAsset>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let month = YearMonth::parse(&bucket).ok_or_else(|| failed(format!("`{bucket}` is not a timeline month")))?;
            let scope = TimelineScope::from(source);
            let assets = if settings.coordinates {
                client.time_bucket_with_coordinates_and_options(&scope, month, &settings.into()).await
            } else {
                client.time_bucket_with(&scope, month, &settings.into()).await
            }
            .map_err(refused)?;
            log::info!("typed: {bucket} of {scope:?}: {} Assets", assets.len());
            Ok(assets.into_iter().map(TimelineAsset::from).collect())
        })
        .await
    }
}

// Albums.

/// Another account, as an album shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryUser {
    pub id: String,
    pub name: String,
    pub email: String,
    /// Immich's colour for the initials avatar, as `primary` or `red`.
    pub avatar_color: String,
    /// None when the account has no profile picture.
    pub profile_image_path: Option<String>,
}

/// One of an album's members: the owner, an editor or a viewer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAlbumMember {
    /// `owner`, `editor` or `viewer`.
    pub role: String,
    pub user: GalleryUser,
}

/// An album, its dates as Immich writes them (`2025-03-04T10:00:00.000Z`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAlbum {
    pub id: String,
    pub name: String,
    /// Empty when the album has none.
    pub description: String,
    pub start_date: Option<String>,
    pub end_date: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub last_modified_asset_timestamp: Option<String>,
    pub asset_count: u64,
    pub shared: bool,
    pub thumbnail_asset_id: Option<String>,
    /// The owner and everyone it is shared with.
    pub members: Vec<GalleryAlbumMember>,
    pub activity_enabled: bool,
    pub has_shared_link: bool,
    /// `asc` or `desc`, when the album has an order of its own.
    pub order: Option<String>,
}

fn written(time: chrono::DateTime<chrono::Utc>) -> String {
    time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

impl From<User> for GalleryUser {
    fn from(user: User) -> GalleryUser {
        GalleryUser {
            id: user.id,
            name: user.name,
            email: user.email,
            avatar_color: user.avatar_color.as_str().to_owned(),
            profile_image_path: Some(user.profile_image_path).filter(|path| !path.is_empty()),
        }
    }
}

impl From<AlbumMember> for GalleryAlbumMember {
    fn from(member: AlbumMember) -> GalleryAlbumMember {
        GalleryAlbumMember { role: member.role.as_str().to_owned(), user: member.user.into() }
    }
}

impl From<Album> for GalleryAlbum {
    fn from(album: Album) -> GalleryAlbum {
        GalleryAlbum {
            id: album.id,
            name: album.name,
            description: album.description,
            start_date: album.start_date.map(written),
            end_date: album.end_date.map(written),
            created_at: written(album.created_at),
            updated_at: written(album.updated_at),
            last_modified_asset_timestamp: album.last_modified_asset_timestamp.map(written),
            asset_count: album.asset_count,
            shared: album.shared,
            thumbnail_asset_id: album.thumbnail_asset_id,
            members: album.members.into_iter().map(GalleryAlbumMember::from).collect(),
            activity_enabled: album.activity_enabled,
            has_shared_link: album.has_shared_link,
            order: album.order.map(|order| order.as_str().to_owned()),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// The account's albums: its own and those shared with it.
    pub async fn albums(&self) -> Result<Vec<GalleryAlbum>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let albums = client.albums().await.map_err(refused)?;
            log::info!("typed: the albums: {}", albums.len());
            Ok(albums.into_iter().map(GalleryAlbum::from).collect())
        })
        .await
    }

    /// One album, without its Assets: the timeline has them.
    pub async fn album(&self, id: String) -> Result<GalleryAlbum, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let album = client.album(&id).await.map_err(refused)?;
            log::info!("typed: one album");
            Ok(album.into())
        })
        .await
    }
}

// People.

/// A person, as recognised by face detection or created by hand.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryPerson {
    pub id: String,
    /// Empty for a person nobody has named.
    pub name: String,
    pub is_hidden: bool,
    pub is_favorite: bool,
    /// As `1990-04-23`.
    pub birth_date: Option<String>,
}

/// One page of people.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryPeoplePage {
    pub people: Vec<GalleryPerson>,
    pub total: u64,
    pub has_next_page: bool,
}

/// Which page of people: from 1, how many, and how narrowed (favorites or hidden only on Immich v3.3).
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GalleryPeopleQuery {
    pub page: u32,
    pub size: u32,
    pub with_hidden: bool,
    pub name: Option<String>,
    pub favorites_only: bool,
    pub hidden_only: bool,
}

impl From<Person> for GalleryPerson {
    fn from(person: Person) -> GalleryPerson {
        GalleryPerson {
            id: person.id,
            name: person.name,
            is_hidden: person.is_hidden,
            is_favorite: person.is_favorite,
            birth_date: person.birth_date.map(|date| date.format("%Y-%m-%d").to_string()),
        }
    }
}

impl From<GalleryPeopleQuery> for PeopleQuery {
    fn from(query: GalleryPeopleQuery) -> PeopleQuery {
        PeopleQuery {
            page: query.page,
            size: query.size,
            with_hidden: query.with_hidden,
            name: query.name,
            favorites_only: query.favorites_only,
            hidden_only: query.hidden_only,
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    pub async fn people_page(&self, query: GalleryPeopleQuery) -> Result<GalleryPeoplePage, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let page = client.people_page(&query.into()).await.map_err(refused)?;
            log::info!("typed: a page of people: {}", page.people.len());
            Ok(GalleryPeoplePage {
                people: page.people.into_iter().map(GalleryPerson::from).collect(),
                total: page.total,
                has_next_page: page.has_next_page,
            })
        })
        .await
    }

    pub async fn person(&self, id: String) -> Result<GalleryPerson, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.person(&id).await.map_err(refused)?.into()) }).await
    }

    /// How many Assets show the person.
    pub async fn person_statistics(&self, id: String) -> Result<u64, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.person_statistics(&id).await.map_err(refused) }).await
    }
}

// A photo's details.

/// What the camera wrote, and where the photo was taken.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryExif {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens_model: Option<String>,
    pub f_number: Option<f64>,
    pub focal_length: Option<f64>,
    pub iso: Option<u32>,
    /// As the camera wrote it, as `1/250`.
    pub exposure_time: Option<String>,
    pub image_width: Option<u32>,
    pub image_height: Option<u32>,
    pub orientation: Option<String>,
    pub file_size: Option<u64>,
    pub date_time_original: Option<String>,
    pub time_zone: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub city: Option<String>,
    pub state: Option<String>,
    pub country: Option<String>,
    pub description: Option<String>,
    pub rating: Option<i32>,
    pub projection_type: Option<String>,
}

/// A person on a photo.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAssetPerson {
    pub id: String,
    pub name: String,
}

/// The stack a photo heads.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryStack {
    pub id: String,
    pub primary_asset_id: String,
    pub asset_count: u64,
}

/// One photo or video, read whole, its times as Immich writes them.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryAsset {
    pub id: String,
    pub owner_id: String,
    /// `IMAGE`, `VIDEO`, or what else the server sent.
    pub kind: String,
    pub original_file_name: String,
    pub original_mime_type: Option<String>,
    pub file_created_at: String,
    /// The wall clock where it was taken, written as Immich writes it, with a `Z` it does not mean.
    pub local_date_time: String,
    /// When it was added to Immich.
    pub created_at: String,
    pub is_favorite: bool,
    pub is_trashed: bool,
    pub visibility: String,
    pub duration_ms: Option<u64>,
    pub thumbhash: Option<String>,
    pub live_photo_video_id: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub exif: Option<GalleryExif>,
    pub people: Vec<GalleryAssetPerson>,
    pub is_edited: bool,
    pub stack: Option<GalleryStack>,
}

impl From<Exif> for GalleryExif {
    fn from(exif: Exif) -> GalleryExif {
        GalleryExif {
            make: exif.make,
            model: exif.model,
            lens_model: exif.lens_model,
            f_number: exif.f_number,
            focal_length: exif.focal_length,
            iso: exif.iso,
            exposure_time: exif.exposure_time,
            image_width: exif.image_width,
            image_height: exif.image_height,
            orientation: exif.orientation,
            file_size: exif.file_size,
            date_time_original: exif.date_time_original.map(written),
            time_zone: exif.time_zone,
            latitude: exif.latitude,
            longitude: exif.longitude,
            city: exif.city,
            state: exif.state,
            country: exif.country,
            description: exif.description,
            rating: exif.rating.map(i32::from),
            projection_type: exif.projection_type,
        }
    }
}

impl From<AssetDetails> for GalleryAsset {
    fn from(asset: AssetDetails) -> GalleryAsset {
        let file_created_at = written(asset.file_created_at);
        GalleryAsset {
            id: asset.id,
            owner_id: asset.owner_id,
            kind: asset.kind.as_str().to_owned(),
            original_file_name: asset.original_file_name,
            original_mime_type: asset.original_mime_type,
            local_date_time: asset
                .local_date_time
                .map_or_else(|| file_created_at.clone(), |local| local.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()),
            file_created_at,
            created_at: written(asset.created_at),
            is_favorite: asset.is_favorite,
            is_trashed: asset.is_trashed,
            visibility: asset.visibility.as_str().to_owned(),
            duration_ms: asset.duration_ms,
            thumbhash: asset.thumbhash,
            live_photo_video_id: asset.live_photo_video_id,
            width: asset.width,
            height: asset.height,
            exif: asset.exif.map(GalleryExif::from),
            people: asset.people.into_iter().map(|person| GalleryAssetPerson { id: person.id, name: person.name }).collect(),
            is_edited: asset.is_edited,
            stack: asset.stack.map(|stack| GalleryStack {
                id: stack.id,
                primary_asset_id: stack.primary_asset_id,
                asset_count: stack.asset_count,
            }),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// One photo or video, read whole.
    pub async fn asset(&self, id: String) -> Result<GalleryAsset, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.asset_details(&id).await.map_err(refused)?.into()) }).await
    }
}

// Sharing.

/// A shared link: what it points at, how it is protected, and what it allows.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GallerySharedLink {
    pub id: String,
    pub key: String,
    /// `ALBUM` or `INDIVIDUAL`.
    pub kind: String,
    pub slug: Option<String>,
    pub description: Option<String>,
    pub expires_at: Option<String>,
    pub password: Option<String>,
    pub allow_download: bool,
    pub allow_upload: bool,
    pub show_metadata: bool,
    pub album: Option<GalleryAlbum>,
    pub assets: Vec<GalleryAsset>,
}

/// A partner: the other account, and whether their library shows on this one's timeline.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryPartner {
    pub id: String,
    pub name: String,
    pub email: String,
    pub in_timeline: Option<bool>,
}

impl From<SharedLink> for GallerySharedLink {
    fn from(link: SharedLink) -> GallerySharedLink {
        GallerySharedLink {
            id: link.id,
            key: link.key.expose().to_owned(),
            kind: link.kind.as_str().to_owned(),
            slug: link.slug,
            description: link.description,
            expires_at: link.expires_at.map(written),
            password: link.password.map(|password| password.expose().to_owned()),
            allow_download: link.allow_download,
            allow_upload: link.allow_upload,
            show_metadata: link.show_metadata,
            album: link.album.map(GalleryAlbum::from),
            assets: link.assets.into_iter().map(GalleryAsset::from).collect(),
        }
    }
}

impl From<Partner> for GalleryPartner {
    fn from(partner: Partner) -> GalleryPartner {
        GalleryPartner { id: partner.id, name: partner.name, email: partner.email, in_timeline: partner.in_timeline }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Every shared link of the account.
    pub async fn shared_links(&self) -> Result<Vec<GallerySharedLink>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let links = client.shared_links(None).await.map_err(refused)?;
            log::info!("typed: the shared links: {}", links.len());
            Ok(links.into_iter().map(GallerySharedLink::from).collect())
        })
        .await
    }

    pub async fn shared_link(&self, id: String) -> Result<GallerySharedLink, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.shared_link(&id).await.map_err(refused)?.into()) }).await
    }

    /// The partners the account shares with (`shared-by`), or who share with it (`shared-with`).
    pub async fn partners(&self, direction: String) -> Result<Vec<GalleryPartner>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let direction = match direction.as_str() {
                "shared-by" => PartnerDirection::SharedBy,
                "shared-with" => PartnerDirection::SharedWith,
                _ => return Err(failed(format!("`{direction}` is not a direction of partners"))),
            };
            let partners = client.partners(&direction).await.map_err(refused)?;
            Ok(partners.into_iter().map(GalleryPartner::from).collect())
        })
        .await
    }

    /// The server's other accounts, to share with.
    pub async fn users(&self) -> Result<Vec<GalleryUser>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.users().await.map_err(refused)?.into_iter().map(GalleryUser::from).collect()) }).await
    }
}

// Search.

/// A search as the app's search panel asks it (immich-api's [`FlatSearch`]): every filter left `None` is left out.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GallerySearch {
    pub query: Option<String>,
    pub original_file_name: Option<String>,
    pub description: Option<String>,
    pub ocr: Option<String>,
    pub person_ids: Option<Vec<String>>,
    pub tag_ids: Option<Vec<String>>,
    pub country: Option<String>,
    pub state: Option<String>,
    pub city: Option<String>,
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens_model: Option<String>,
    pub taken_after: Option<String>,
    pub taken_before: Option<String>,
    /// `IMAGE` or `VIDEO`.
    pub kind: Option<String>,
    pub visibility: Option<String>,
    pub is_favorite: Option<bool>,
    pub is_not_in_album: Option<bool>,
    pub rating: Option<i32>,
    pub page: Option<u32>,
    pub cursor: Option<String>,
    pub size: u32,
    pub order: Option<String>,
    pub with_exif: Option<bool>,
    pub with_stacked: Option<bool>,
}

/// One page of a search: the photos, and the way to the next page, by number or by cursor.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GallerySearchPage {
    pub assets: Vec<GalleryAsset>,
    pub next_page: Option<String>,
    pub next_cursor: Option<String>,
}

impl From<GallerySearch> for FlatSearch {
    fn from(search: GallerySearch) -> FlatSearch {
        FlatSearch {
            query: search.query,
            original_file_name: search.original_file_name,
            description: search.description,
            ocr: search.ocr,
            person_ids: search.person_ids,
            tag_ids: search.tag_ids,
            country: search.country,
            state: search.state,
            city: search.city,
            make: search.make,
            model: search.model,
            lens_model: search.lens_model,
            taken_after: search.taken_after,
            taken_before: search.taken_before,
            kind: search.kind,
            visibility: search.visibility,
            is_favorite: search.is_favorite,
            is_not_in_album: search.is_not_in_album,
            rating: search.rating,
            page: search.page,
            cursor: search.cursor,
            size: search.size,
            order: search.order,
            with_exif: search.with_exif,
            with_stacked: search.with_stacked,
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// One page of a search: smart, by words, or by its filters alone.
    pub async fn search(&self, search: GallerySearch, smart: bool) -> Result<GallerySearchPage, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let page = client.flat_search(&search.into(), smart).await.map_err(refused)?;
            log::info!("typed: a page of a {} search: {}", if smart { "smart" } else { "metadata" }, page.assets.len());
            Ok(GallerySearchPage {
                assets: page.assets.into_iter().map(GalleryAsset::from).collect(),
                next_page: page.next_page,
                next_cursor: page.next_cursor,
            })
        })
        .await
    }
}

// Administration.

/// An account, as an administrator sees it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAdminUser {
    pub id: String,
    pub name: String,
    pub email: String,
    pub is_admin: bool,
    pub deleted_at: Option<String>,
    /// `active`, `removing` or `deleted`.
    pub status: String,
    pub quota_size_in_bytes: Option<u64>,
    pub quota_usage_in_bytes: Option<u64>,
    pub should_change_password: bool,
}

/// An external library.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryLibrary {
    pub id: String,
    pub name: String,
    pub owner_id: String,
    pub asset_count: u64,
    pub import_paths: Vec<String>,
    pub exclusion_patterns: Vec<String>,
}

/// A queue of the server's background jobs, with its counts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryQueue {
    pub name: String,
    pub is_paused: bool,
    pub active: u64,
    pub completed: u64,
    pub delayed: u64,
    pub failed: u64,
    pub paused: u64,
    pub waiting: u64,
}

impl From<UserDetails> for GalleryAdminUser {
    fn from(user: UserDetails) -> GalleryAdminUser {
        GalleryAdminUser {
            id: user.id,
            name: user.name,
            email: user.email,
            is_admin: user.is_admin,
            deleted_at: user.deleted_at.map(written),
            status: user.status.as_str().to_owned(),
            quota_size_in_bytes: user.quota_size_in_bytes,
            quota_usage_in_bytes: user.quota_usage_in_bytes,
            should_change_password: user.should_change_password,
        }
    }
}

impl From<Library> for GalleryLibrary {
    fn from(library: Library) -> GalleryLibrary {
        GalleryLibrary {
            id: library.id,
            name: library.name,
            owner_id: library.owner_id,
            asset_count: library.asset_count,
            import_paths: library.import_paths,
            exclusion_patterns: library.exclusion_patterns,
        }
    }
}

impl From<Queue> for GalleryQueue {
    fn from(queue: Queue) -> GalleryQueue {
        let counts = queue.statistics;
        GalleryQueue {
            name: queue.name.as_str().to_owned(),
            is_paused: queue.is_paused,
            active: counts.active,
            completed: counts.completed,
            delayed: counts.delayed,
            failed: counts.failed,
            paused: counts.paused,
            waiting: counts.waiting,
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// The server's accounts, deleted ones too when asked. Needs an administrator.
    pub async fn admin_users(&self, with_deleted: bool) -> Result<Vec<GalleryAdminUser>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            Ok(client.admin_users(with_deleted).await.map_err(refused)?.into_iter().map(GalleryAdminUser::from).collect())
        })
        .await
    }

    pub async fn libraries(&self) -> Result<Vec<GalleryLibrary>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.libraries().await.map_err(refused)?.into_iter().map(GalleryLibrary::from).collect()) }).await
    }

    pub async fn queues(&self) -> Result<Vec<GalleryQueue>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.queues().await.map_err(refused)?.into_iter().map(GalleryQueue::from).collect()) }).await
    }
}

// Changes to photos.

/// What to change on photos; a field left `None` stays as it is.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct GalleryAssetChanges {
    pub favorite: Option<bool>,
    /// `timeline`, `archive`, `hidden` or `locked`.
    pub visibility: Option<String>,
    /// When it was taken, with its offset, as `2025-03-04T10:00:00+01:00`.
    pub date_time_original: Option<String>,
    /// Shift the capture date by this many minutes.
    pub date_time_relative: Option<i64>,
    /// An IANA zone such as `Europe/Copenhagen`.
    pub time_zone: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// An empty description removes it.
    pub description: Option<String>,
    /// 1 to 5 stars, or -1 for rejected.
    pub rating: Option<i32>,
    /// Remove the rating.
    pub clear_rating: bool,
}

impl GalleryAssetChanges {
    fn into_changes(self) -> Result<AssetChanges, BridgeError> {
        let date_time_original = self
            .date_time_original
            .map(|text| chrono::DateTime::parse_from_rfc3339(&text).map_err(|_| failed(format!("`{text}` is not a date with its offset"))))
            .transpose()?;
        let rating = if self.clear_rating {
            Some(None)
        } else {
            self.rating.map(|stars| i8::try_from(stars).map(Some).map_err(|_| failed(format!("{stars} is not a rating")))).transpose()?
        };
        Ok(AssetChanges {
            favorite: self.favorite,
            visibility: self.visibility.map(Visibility::from),
            date_time_original,
            date_time_relative: self.date_time_relative,
            time_zone: self.time_zone,
            latitude: self.latitude,
            longitude: self.longitude,
            description: self.description,
            rating,
            ..AssetChanges::default()
        })
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Change the same things on every photo in `ids`.
    pub async fn update_assets(&self, ids: Vec<String>, changes: GalleryAssetChanges) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = changes.into_changes()?;
            client.update_assets(&ids, &changes).await.map_err(refused)?;
            log::info!("typed: changed {} photos", ids.len());
            Ok(())
        })
        .await
    }

    /// Move photos to the trash, or delete them for good when `force`.
    pub async fn delete_assets(&self, ids: Vec<String>, force: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_assets(&ids, force).await.map_err(refused) }).await
    }

    /// Take photos out of the trash; how many came back.
    pub async fn restore_assets(&self, ids: Vec<String>) -> Result<u64, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.restore_assets(&ids).await.map_err(refused) }).await
    }
}

// Changes to albums, people, shared links and partners.

/// What to change on an album; a field left `None` stays as it is.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAlbumChanges {
    pub name: Option<String>,
    /// An empty description removes it.
    pub description: Option<String>,
    pub thumbnail_asset_id: Option<String>,
    /// `asc` or `desc`.
    pub order: Option<String>,
    pub activity_enabled: Option<bool>,
}

/// One id's outcome in a change to many: whether it took, and why not.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryIdResult {
    pub id: String,
    pub success: bool,
    /// `duplicate`, `no_permission`, `not_found`, `unknown` or `validation`.
    pub error: Option<String>,
}

impl From<BulkIdResult> for GalleryIdResult {
    fn from(result: BulkIdResult) -> GalleryIdResult {
        GalleryIdResult { id: result.id, success: result.success, error: result.error.map(|error| error.as_str().to_owned()) }
    }
}

/// What to change on a person; a field left `None` stays as it is.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GalleryPersonChanges {
    /// An empty name makes the person unnamed.
    pub name: Option<String>,
    /// As `1990-04-23`.
    pub birth_date: Option<String>,
    pub clear_birth_date: bool,
    pub is_hidden: Option<bool>,
    pub is_favorite: Option<bool>,
    /// The photo whose face of this person becomes their thumbnail.
    pub feature_face_asset_id: Option<String>,
}

/// A shared link's settings, as the link editor has them: an empty slug or password, or no expiry, is none.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct GallerySharingOptions {
    pub description: String,
    pub slug: String,
    pub password: String,
    /// Leave the password as it is, when changing a link.
    pub keep_password: bool,
    /// ISO 8601, or none for a link that lasts for ever.
    pub expires_at: Option<String>,
    pub allow_download: bool,
    pub allow_upload: bool,
    pub show_metadata: bool,
}

fn utc(text: &str) -> Result<chrono::DateTime<chrono::Utc>, BridgeError> {
    chrono::DateTime::parse_from_rfc3339(text)
        .map(|time| time.with_timezone(&chrono::Utc))
        .map_err(|_| failed(format!("`{text}` is not a date and time")))
}

fn day(text: &str) -> Result<chrono::NaiveDate, BridgeError> {
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|_| failed(format!("`{text}` is not a day")))
}

impl GalleryAlbumChanges {
    fn into_changes(self) -> AlbumChanges {
        AlbumChanges {
            name: self.name,
            description: self.description,
            thumbnail_asset_id: self.thumbnail_asset_id,
            activity_enabled: self.activity_enabled,
            order: self.order.map(AssetOrder::from),
        }
    }
}

impl GalleryPersonChanges {
    fn into_changes(self) -> Result<PersonChanges, BridgeError> {
        let birth_date = if self.clear_birth_date { Some(None) } else { self.birth_date.as_deref().map(day).transpose()?.map(Some) };
        Ok(PersonChanges {
            name: self.name,
            birth_date,
            is_hidden: self.is_hidden,
            is_favorite: self.is_favorite,
            feature_face_asset_id: self.feature_face_asset_id,
            ..PersonChanges::default()
        })
    }
}

impl GallerySharingOptions {
    fn expiry(&self) -> Result<Option<chrono::DateTime<chrono::Utc>>, BridgeError> {
        self.expires_at.as_deref().map(utc).transpose()
    }

    fn into_new_link(self, album_id: Option<String>, asset_ids: Vec<String>) -> Result<NewSharedLink, BridgeError> {
        let expires_at = self.expiry()?;
        Ok(NewSharedLink {
            kind: if album_id.is_some() { SharedLinkKind::Album } else { SharedLinkKind::Individual },
            asset_ids: if album_id.is_some() { Vec::new() } else { asset_ids },
            album_id,
            description: Some(self.description),
            password: Some(self.password).filter(|password| !password.is_empty()).map(Secret::from),
            slug: Some(self.slug).filter(|slug| !slug.is_empty()),
            expires_at,
            allow_download: self.allow_download,
            allow_upload: self.allow_upload,
            show_metadata: self.show_metadata,
        })
    }

    /// As the link editor sends it: every setting, the slug, password and expiry removed when empty.
    fn into_changes(self) -> Result<SharedLinkChanges, BridgeError> {
        let expires_at = self.expiry()?;
        Ok(SharedLinkChanges {
            description: Some(Some(self.description)),
            password: if self.keep_password { None } else { Some(Some(self.password).filter(|password| !password.is_empty()).map(Secret::from)) },
            slug: Some(Some(self.slug).filter(|slug| !slug.is_empty())),
            expires_at: Some(expires_at),
            allow_download: Some(self.allow_download),
            allow_upload: Some(self.allow_upload),
            show_metadata: Some(self.show_metadata),
        })
    }
}

#[uniffi::export]
impl ApiConnection {
    pub async fn create_album(&self, name: String, description: Option<String>, asset_ids: Vec<String>) -> Result<GalleryAlbum, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let album = NewAlbum { name, description: description.filter(|text| !text.is_empty()), asset_ids, ..NewAlbum::default() };
            Ok(client.create_album(&album).await.map_err(refused)?.into())
        })
        .await
    }

    pub async fn update_album(&self, id: String, changes: GalleryAlbumChanges) -> Result<GalleryAlbum, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.update_album(&id, &changes.into_changes()).await.map_err(refused)?.into()) }).await
    }

    pub async fn delete_album(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_album(&id).await.map_err(refused) }).await
    }

    /// Add photos to an album, or take them out when `removing`: each photo's outcome.
    pub async fn change_album_assets(&self, id: String, asset_ids: Vec<String>, removing: bool) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let results = if removing {
                client.remove_assets_from_album(&id, &asset_ids).await
            } else {
                client.add_assets_to_album(&id, &asset_ids).await
            }
            .map_err(refused)?;
            Ok(results
                .into_iter()
                .map(GalleryIdResult::from)
                .collect())
        })
        .await
    }

    /// Share an album with an account, as `editor` or `viewer`.
    pub async fn add_album_member(&self, id: String, user_id: String, role: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.add_album_members(&id, &[NewMember { user_id, role: AlbumRole::from(role) }]).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn update_album_member(&self, id: String, user_id: String, role: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.update_album_member(&id, &user_id, &AlbumRole::from(role)).await.map_err(refused) }).await
    }

    pub async fn remove_album_member(&self, id: String, user_id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.remove_album_member(&id, &user_id).await.map_err(refused) }).await
    }

    pub async fn create_person(&self, name: String) -> Result<GalleryPerson, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let person = NewPerson { name: Some(name), ..NewPerson::default() };
            Ok(client.create_person(&person).await.map_err(refused)?.into())
        })
        .await
    }

    pub async fn update_person(&self, id: String, changes: GalleryPersonChanges) -> Result<GalleryPerson, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.update_person(&id, &changes.into_changes()?).await.map_err(refused)?.into()) }).await
    }

    /// Merge people into the person `id`: each merged person's outcome.
    pub async fn merge_people(&self, id: String, merged_ids: Vec<String>) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let results = client.merge_people(&id, &merged_ids).await.map_err(refused)?;
            Ok(results
                .into_iter()
                .map(GalleryIdResult::from)
                .collect())
        })
        .await
    }

    /// Give a face to another person; the person it now shows.
    pub async fn reassign_face(&self, face_id: String, person_id: String) -> Result<GalleryPerson, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.reassign_face(&face_id, &person_id).await.map_err(refused)?.into()) }).await
    }

    pub async fn delete_face(&self, face_id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_face(&face_id, false).await.map_err(refused) }).await
    }

    /// A link to an album, or to chosen photos when `album_id` is none.
    pub async fn create_shared_link(
        &self,
        album_id: Option<String>,
        asset_ids: Vec<String>,
        options: GallerySharingOptions,
    ) -> Result<GallerySharedLink, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let link = options.into_new_link(album_id, asset_ids)?;
            Ok(client.create_shared_link(&link).await.map_err(refused)?.into())
        })
        .await
    }

    pub async fn update_shared_link(&self, id: String, options: GallerySharingOptions) -> Result<GallerySharedLink, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.update_shared_link(&id, &options.into_changes()?).await.map_err(refused)?.into()) }).await
    }

    pub async fn delete_shared_link(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_shared_link(&id).await.map_err(refused) }).await
    }

    /// Add photos to a link to chosen photos, or take them out when `removing`: each photo's outcome.
    pub async fn change_shared_link_assets(&self, id: String, asset_ids: Vec<String>, removing: bool) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let results = if removing {
                client.remove_assets_from_shared_link(&id, &asset_ids).await
            } else {
                client.add_assets_to_shared_link(&id, &asset_ids).await
            }
            .map_err(refused)?;
            Ok(results
                .into_iter()
                .map(|result| GalleryIdResult { id: result.asset_id, success: result.success, error: result.error.map(|error| error.as_str().to_owned()) })
                .collect())
        })
        .await
    }

    /// Share the library with an account.
    pub async fn add_partner(&self, user_id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.add_partner(&user_id).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn remove_partner(&self, user_id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.remove_partner(&user_id).await.map_err(refused) }).await
    }

    /// Whether a partner's photos show on this account's timeline.
    pub async fn set_partner_in_timeline(&self, user_id: String, in_timeline: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.set_partner_in_timeline(&user_id, in_timeline).await.map_err(refused)?;
            Ok(())
        })
        .await
    }
}

// The server, the account, and Explore's reads.

/// The server's version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct GalleryVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

/// The server's switches that the app reads: how to sign in, and what it offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct GalleryFeatures {
    pub oauth: bool,
    pub password_login: bool,
    pub trash: bool,
    pub smart_search: bool,
    pub facial_recognition: bool,
    pub duplicate_detection: bool,
    pub ocr: bool,
    pub map: bool,
}

impl From<ServerFeatures> for GalleryFeatures {
    fn from(features: ServerFeatures) -> GalleryFeatures {
        GalleryFeatures {
            oauth: features.oauth,
            password_login: features.password_login,
            trash: features.trash,
            smart_search: features.smart_search,
            facial_recognition: features.facial_recognition,
            duplicate_detection: features.duplicate_detection,
            ocr: features.ocr,
            map: features.map,
        }
    }
}

/// The signed-in account.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAccount {
    pub id: String,
    pub name: String,
    pub email: String,
    pub is_admin: bool,
    pub should_change_password: bool,
    pub avatar_color: String,
    /// As Immich writes it: empty for no profile picture.
    pub profile_image_path: String,
    pub quota_size_in_bytes: Option<u64>,
    pub quota_usage_in_bytes: Option<u64>,
}

impl From<UserDetails> for GalleryAccount {
    fn from(user: UserDetails) -> GalleryAccount {
        GalleryAccount {
            id: user.id,
            name: user.name,
            email: user.email,
            is_admin: user.is_admin,
            should_change_password: user.should_change_password,
            avatar_color: user.avatar_color.as_str().to_owned(),
            profile_image_path: user.profile_image_path,
            quota_size_in_bytes: user.quota_size_in_bytes,
            quota_usage_in_bytes: user.quota_usage_in_bytes,
        }
    }
}

/// Whether the account has a password and a PIN code, and whether this session may see the Locked Folder.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAuthStatus {
    pub password: bool,
    pub pin_code: bool,
    pub is_elevated: bool,
    pub pin_expires_at: Option<String>,
}

impl From<AuthStatus> for GalleryAuthStatus {
    fn from(status: AuthStatus) -> GalleryAuthStatus {
        GalleryAuthStatus {
            password: status.password,
            pin_code: status.pin_code,
            is_elevated: status.is_elevated,
            pin_expires_at: status.pin_expires_at.map(written),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryTag {
    pub id: String,
    /// The last part of its path.
    pub name: String,
    /// Its whole path, `Parent/Child`.
    pub value: String,
    pub color: Option<String>,
    pub parent_id: Option<String>,
}

impl From<Tag> for GalleryTag {
    fn from(tag: Tag) -> GalleryTag {
        GalleryTag { id: tag.id, name: tag.name, value: tag.value, color: tag.color, parent_id: tag.parent_id }
    }
}

/// Which photos the map shows: favorites only, archived ones too, partners' too, taken between two times (ISO
/// 8601).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryMapQuery {
    pub favorites_only: bool,
    pub archived: bool,
    pub with_partners: bool,
    pub after: Option<String>,
    pub before: Option<String>,
}

/// One photo on the map.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryMarker {
    pub id: String,
    pub latitude: f64,
    pub longitude: f64,
    pub city: Option<String>,
}

impl From<MapMarker> for GalleryMarker {
    fn from(marker: MapMarker) -> GalleryMarker {
        GalleryMarker { id: marker.id, latitude: marker.lat, longitude: marker.lon, city: marker.city }
    }
}

/// A memory, with its photos.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryMemory {
    pub id: String,
    /// `on_this_day` or `birthday`.
    pub kind: String,
    /// The year it recalls.
    pub year: i32,
    /// Whose birthday, for one.
    pub person_name: Option<String>,
    /// The day it recalls.
    pub memory_at: String,
    pub seen_at: Option<String>,
    /// Kept by the user, so Immich's cleanup leaves it.
    pub is_saved: bool,
    pub assets: Vec<GalleryAsset>,
}

impl From<Memory> for GalleryMemory {
    fn from(memory: Memory) -> GalleryMemory {
        GalleryMemory {
            id: memory.id,
            kind: memory.kind.as_str().to_owned(),
            year: memory.data.year,
            person_name: memory.data.person_name,
            memory_at: written(memory.memory_at),
            seen_at: memory.seen_at.map(written),
            is_saved: memory.is_saved,
            assets: memory.assets.into_iter().map(GalleryAsset::from).collect(),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Tell the connection whether the server can be reached, as Linux's window does (ARCHITECTURE.md, "Verso on the
    /// Mac"): while it cannot, every request fails at once rather than wait out its timeout, and `ping` still asks.
    pub fn set_reachable(&self, reachable: bool) {
        self.client.set_reachable(reachable);
    }

    /// Whether the server answers, within a few seconds, even while it is taken as unreachable.
    pub async fn ping(&self) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.ping().await.map_err(refused) }).await
    }

    /// The server's version; needs no credential.
    pub async fn server_version(&self) -> Result<GalleryVersion, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let version = client.server_version().await.map_err(refused)?;
            Ok(GalleryVersion { major: version.major, minor: version.minor, patch: version.patch })
        })
        .await
    }

    /// The server's switches; needs no credential.
    pub async fn server_features(&self) -> Result<GalleryFeatures, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.server_features().await.map_err(refused)?.into()) }).await
    }

    pub async fn me(&self) -> Result<GalleryAccount, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.me().await.map_err(refused)?.into()) }).await
    }

    pub async fn auth_status(&self) -> Result<GalleryAuthStatus, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.auth_status().await.map_err(refused)?.into()) }).await
    }

    pub async fn tags(&self) -> Result<Vec<GalleryTag>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.tags().await.map_err(refused)?.into_iter().map(GalleryTag::from).collect()) }).await
    }

    pub async fn map_markers(&self, query: GalleryMapQuery) -> Result<Vec<GalleryMarker>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let query = MapQuery {
                archived: query.archived.then_some(true),
                favorite: query.favorites_only.then_some(true),
                created_after: query.after.as_deref().map(utc).transpose()?,
                created_before: query.before.as_deref().map(utc).transpose()?,
                with_partners: query.with_partners,
                with_shared_albums: false,
            };
            Ok(client.map_markers(&query).await.map_err(refused)?.into_iter().map(GalleryMarker::from).collect())
        })
        .await
    }

    /// Every server folder that holds the account's photos.
    pub async fn folder_paths(&self) -> Result<Vec<String>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.folder_paths().await.map_err(refused) }).await
    }

    /// The photos directly in one server folder.
    pub async fn folder_assets(&self, path: String) -> Result<Vec<GalleryAsset>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.folder_assets(&path).await.map_err(refused)?.into_iter().map(GalleryAsset::from).collect()) })
            .await
    }

    /// One photo for each city the account has photos in.
    pub async fn city_assets(&self) -> Result<Vec<GalleryAsset>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.city_assets().await.map_err(refused)?.into_iter().map(GalleryAsset::from).collect()) }).await
    }

    /// One page of the memories shown on `day` (`2026-11-15`), neither trashed nor upcoming.
    pub async fn memories(&self, day: String, page: u32, size: u32) -> Result<Vec<GalleryMemory>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let filter = MemoryFilter {
                shown_on: Some(self::day(&day)?),
                trashed: Some(false),
                upcoming: Some(false),
                size: Some(size),
                page: Some(page),
                ..MemoryFilter::default()
            };
            Ok(client.memories(&filter).await.map_err(refused)?.into_iter().map(GalleryMemory::from).collect())
        })
        .await
    }
}

// What surrounds a photo: its stack, duplicates, faces, edits and comments; search's suggestions and Explore.

/// A stack: the photo shown for it, and every photo in it, the primary first.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryStackDetails {
    pub id: String,
    pub primary_asset_id: String,
    pub assets: Vec<GalleryAsset>,
}

impl From<Stack> for GalleryStackDetails {
    fn from(stack: Stack) -> GalleryStackDetails {
        GalleryStackDetails {
            id: stack.id,
            primary_asset_id: stack.primary_asset_id,
            assets: stack.assets.into_iter().map(GalleryAsset::from).collect(),
        }
    }
}

/// A group of look-alike photos, with those the server suggests keeping.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryDuplicateGroup {
    pub id: String,
    pub assets: Vec<GalleryAsset>,
    pub suggested_keep_asset_ids: Vec<String>,
}

impl From<DuplicateGroup> for GalleryDuplicateGroup {
    fn from(group: DuplicateGroup) -> GalleryDuplicateGroup {
        GalleryDuplicateGroup {
            id: group.duplicate_id,
            assets: group.assets.into_iter().map(GalleryAsset::from).collect(),
            suggested_keep_asset_ids: group.suggested_keep_asset_ids,
        }
    }
}

/// A face on a photo: its box, in the pixels of the picture it was measured on, and whose it is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryFace {
    pub id: String,
    pub person: Option<GalleryPerson>,
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub image_width: u32,
    pub image_height: u32,
}

impl From<Face> for GalleryFace {
    fn from(face: Face) -> GalleryFace {
        GalleryFace {
            id: face.id,
            person: face.person.map(GalleryPerson::from),
            left: face.left,
            top: face.top,
            right: face.right,
            bottom: face.bottom,
            image_width: face.image_width,
            image_height: face.image_height,
        }
    }
}

/// One step of a photo's edit: `crop` (x, y, width, height), `rotate` (angle) or `mirror` (axis); another kind's
/// action alone.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct GalleryEdit {
    pub action: String,
    pub angle: Option<i32>,
    pub axis: Option<String>,
    pub x: Option<u32>,
    pub y: Option<u32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

impl From<AssetEdit> for GalleryEdit {
    fn from(edit: AssetEdit) -> GalleryEdit {
        match edit {
            AssetEdit::Crop { x, y, width, height } => GalleryEdit {
                action: "crop".to_owned(),
                x: Some(x),
                y: Some(y),
                width: Some(width),
                height: Some(height),
                ..GalleryEdit::default()
            },
            AssetEdit::Rotate { angle } => GalleryEdit { action: "rotate".to_owned(), angle: Some(angle), ..GalleryEdit::default() },
            AssetEdit::Mirror { axis } => GalleryEdit { action: "mirror".to_owned(), axis: Some(axis.as_str().to_owned()), ..GalleryEdit::default() },
            AssetEdit::Other { action, .. } => GalleryEdit { action, ..GalleryEdit::default() },
        }
    }
}

/// A comment or a like in a shared album.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryActivity {
    pub id: String,
    /// `comment` or `like`.
    pub kind: String,
    /// The photo it is about; none for the album as a whole.
    pub asset_id: Option<String>,
    pub comment: Option<String>,
    pub user: GalleryUser,
    pub created_at: String,
}

impl From<Activity> for GalleryActivity {
    fn from(activity: Activity) -> GalleryActivity {
        GalleryActivity {
            id: activity.id,
            kind: activity.kind.as_str().to_owned(),
            asset_id: activity.asset_id,
            comment: activity.comment,
            user: activity.user.into(),
            created_at: written(activity.created_at),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct GalleryActivityStatistics {
    pub comments: u64,
    pub likes: u64,
}

impl From<ActivityStatistics> for GalleryActivityStatistics {
    fn from(statistics: ActivityStatistics) -> GalleryActivityStatistics {
        GalleryActivityStatistics { comments: statistics.comments, likes: statistics.likes }
    }
}

/// Which values search suggests: `kind` is `country`, `state`, `city`, `camera-make`, `camera-model` or
/// `camera-lens-model`, narrowed by the values chosen so far.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GallerySuggestionQuery {
    pub kind: String,
    pub country: Option<String>,
    pub state: Option<String>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
}

/// One of Explore's groups (places, things), each value with a photo that stands for it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryExploreGroup {
    pub field_name: String,
    pub items: Vec<GalleryExploreItem>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GalleryExploreItem {
    pub value: String,
    pub asset: GalleryAsset,
}

impl From<ExploreGroup> for GalleryExploreGroup {
    fn from(group: ExploreGroup) -> GalleryExploreGroup {
        GalleryExploreGroup {
            field_name: group.field_name,
            items: group.items.into_iter().map(|item| GalleryExploreItem { value: item.value, asset: item.asset.into() }).collect(),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    pub async fn stack(&self, id: String) -> Result<GalleryStackDetails, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.stack(&id).await.map_err(refused)?.into()) }).await
    }

    pub async fn duplicates(&self) -> Result<Vec<GalleryDuplicateGroup>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            Ok(client.duplicates().await.map_err(refused)?.into_iter().map(GalleryDuplicateGroup::from).collect())
        })
        .await
    }

    /// The faces on a photo.
    pub async fn faces(&self, asset_id: String) -> Result<Vec<GalleryFace>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.faces(&asset_id).await.map_err(refused)?.into_iter().map(GalleryFace::from).collect()) })
            .await
    }

    /// A photo's edit steps, in order.
    pub async fn asset_edits(&self, id: String) -> Result<Vec<GalleryEdit>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.asset_edits(&id).await.map_err(refused)?.into_iter().map(GalleryEdit::from).collect()) })
            .await
    }

    /// An album's comments and likes, oldest first, or one photo's in it.
    pub async fn activities(&self, album_id: String, asset_id: Option<String>) -> Result<Vec<GalleryActivity>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let filter = ActivityFilter { asset_id, ..ActivityFilter::default() };
            Ok(client.activities(&album_id, &filter).await.map_err(refused)?.into_iter().map(GalleryActivity::from).collect())
        })
        .await
    }

    pub async fn activity_statistics(&self, album_id: String, asset_id: Option<String>) -> Result<GalleryActivityStatistics, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.activity_statistics(&album_id, asset_id.as_deref()).await.map_err(refused)?.into()) }).await
    }

    pub async fn suggestions(&self, query: GallerySuggestionQuery) -> Result<Vec<String>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let query = SuggestionQuery {
                kind: SuggestionKind::from(query.kind),
                country: query.country,
                state: query.state,
                camera_make: query.camera_make,
                camera_model: query.camera_model,
            };
            client.suggestions(&query).await.map_err(refused)
        })
        .await
    }

    pub async fn explore(&self) -> Result<Vec<GalleryExploreGroup>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.explore().await.map_err(refused)?.into_iter().map(GalleryExploreGroup::from).collect()) }).await
    }

    /// The extensions of the images and videos the server takes, as `.jpg`, lower case; needs no credential.
    pub async fn media_types(&self) -> Result<Vec<String>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.server_media_types().await.map_err(refused) }).await
    }
}

// Changes to what surrounds a photo: stacks, duplicates, tags, memories, edits, comments, the Locked Folder.

impl GalleryEdit {
    /// The step immich-api sends: a crop, a turn or a flip needs its parameters; another kind goes as it came.
    fn into_edit(self) -> Result<AssetEdit, BridgeError> {
        let missing = |what: &str| failed(format!("a {} step without its {what}", self.action));
        Ok(match self.action.as_str() {
            "crop" => AssetEdit::Crop {
                x: self.x.ok_or_else(|| missing("x"))?,
                y: self.y.ok_or_else(|| missing("y"))?,
                width: self.width.ok_or_else(|| missing("width"))?,
                height: self.height.ok_or_else(|| missing("height"))?,
            },
            "rotate" => AssetEdit::Rotate { angle: self.angle.ok_or_else(|| missing("angle"))? },
            "mirror" => AssetEdit::Mirror { axis: MirrorAxis::from(self.axis.clone().ok_or_else(|| missing("axis"))?) },
            _ => {
                let mut parameters = serde_json::Map::new();
                let numbers = [("angle", self.angle.map(i64::from)), ("x", self.x.map(i64::from)), ("y", self.y.map(i64::from)),
                    ("width", self.width.map(i64::from)), ("height", self.height.map(i64::from))];
                for (name, value) in numbers {
                    if let Some(value) = value {
                        parameters.insert(name.to_owned(), value.into());
                    }
                }
                if let Some(axis) = &self.axis {
                    parameters.insert("axis".to_owned(), axis.clone().into());
                }
                AssetEdit::Other { action: self.action.clone(), parameters: parameters.into() }
            }
        })
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Stack photos, the first the primary.
    pub async fn create_stack(&self, asset_ids: Vec<String>) -> Result<GalleryStackDetails, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.create_stack(&asset_ids).await.map_err(refused)?.into()) }).await
    }

    pub async fn set_stack_primary(&self, id: String, asset_id: String) -> Result<GalleryStackDetails, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.set_stack_primary(&id, &asset_id).await.map_err(refused)?.into()) }).await
    }

    /// Unstack: the photos stay.
    pub async fn delete_stack(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_stack(&id).await.map_err(refused) }).await
    }

    pub async fn remove_from_stack(&self, id: String, asset_id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.remove_from_stack(&id, &asset_id).await.map_err(refused) }).await
    }

    /// Take a group off the duplicates: its photos are not duplicates.
    pub async fn dismiss_duplicates(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.dismiss_duplicate_group(&id).await.map_err(refused) }).await
    }

    /// Keep some of a group's photos and move the rest to the trash: each outcome.
    pub async fn resolve_duplicates(&self, id: String, keep: Vec<String>, trash: Vec<String>) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let resolution = DuplicateResolution { duplicate_id: id, keep_asset_ids: keep, trash_asset_ids: trash };
            Ok(client.resolve_duplicates(&[resolution]).await.map_err(refused)?.into_iter().map(GalleryIdResult::from).collect())
        })
        .await
    }

    /// Make a tag at a path (`Parent/Child`), its parents too; one that exists stays.
    pub async fn upsert_tag(&self, path: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.upsert_tags(&[path]).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Rename a tag, and give it a colour, or none when `color` is empty.
    pub async fn update_tag(&self, id: String, name: String, color: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = TagChanges { name: Some(name), color: Some(Some(color).filter(|color| !color.is_empty())) };
            client.update_tag(&id, &changes).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn delete_tag(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_tag(&id).await.map_err(refused) }).await
    }

    /// Tag photos, or untag them when `removing`: each photo's outcome.
    pub async fn change_tag_assets(&self, id: String, asset_ids: Vec<String>, removing: bool) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let results = if removing { client.untag_assets(&id, &asset_ids).await } else { client.tag_assets(&id, &asset_ids).await };
            Ok(results.map_err(refused)?.into_iter().map(GalleryIdResult::from).collect())
        })
        .await
    }

    /// Mark a memory seen, now.
    pub async fn mark_memory_seen(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = MemoryChanges { seen_at: Some(chrono::Utc::now()), ..MemoryChanges::default() };
            client.update_memory(&id, &changes).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Keep a memory, so Immich's cleanup leaves it, or let it go again.
    pub async fn set_memory_saved(&self, id: String, saved: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = MemoryChanges { is_saved: Some(saved), ..MemoryChanges::default() };
            client.update_memory(&id, &changes).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn delete_memory(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_memory(&id).await.map_err(refused) }).await
    }

    /// Take photos out of a memory: each photo's outcome.
    pub async fn remove_memory_assets(&self, id: String, asset_ids: Vec<String>) -> Result<Vec<GalleryIdResult>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            Ok(client.remove_memory_assets(&id, &asset_ids).await.map_err(refused)?.into_iter().map(GalleryIdResult::from).collect())
        })
        .await
    }

    /// Open the Locked Folder for this session with the PIN code, setting it first when `set_up`. A session's
    /// alone: an API key cannot.
    pub async fn unlock_locked_folder(&self, pin_code: String, set_up: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            if set_up {
                client.set_pin_code(&pin_code).await.map_err(refused)?;
            }
            client.unlock_session(&Proof::PinCode(pin_code)).await.map_err(refused)
        })
        .await
    }

    pub async fn lock_locked_folder(&self) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.lock_session().await.map_err(refused) }).await
    }

    /// A photo's edit steps, in order; none undoes its edit.
    pub async fn set_asset_edits(&self, id: String, edits: Vec<GalleryEdit>) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            if edits.is_empty() {
                return client.delete_asset_edits(&id).await.map_err(refused);
            }
            let edits = edits.into_iter().map(GalleryEdit::into_edit).collect::<Result<Vec<_>, _>>()?;
            client.set_asset_edits(&id, &edits).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// A comment in an album, or a like when `comment` is none; on one of its photos when `asset_id` is some.
    pub async fn add_activity(&self, album_id: String, asset_id: Option<String>, comment: Option<String>) -> Result<GalleryActivity, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let activity = match comment {
                Some(text) => client.comment(&album_id, asset_id.as_deref(), &text).await,
                None => client.like(&album_id, asset_id.as_deref()).await,
            };
            Ok(activity.map_err(refused)?.into())
        })
        .await
    }

    pub async fn delete_activity(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_activity(&id).await.map_err(refused) }).await
    }
}

// The account: its name, password, picture, API keys, sessions and notifications.

/// An API key, without its secret.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryApiKey {
    pub id: String,
    pub name: String,
    /// Permission names such as `asset.read`, or `all`.
    pub permissions: Vec<String>,
    pub created_at: String,
}

impl From<ApiKey> for GalleryApiKey {
    fn from(key: ApiKey) -> GalleryApiKey {
        GalleryApiKey { id: key.id, name: key.name, permissions: key.permissions, created_at: written(key.created_at) }
    }
}

/// A key just made, with its secret, which is shown only now.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryNewApiKey {
    pub key: GalleryApiKey,
    pub secret: String,
}

/// A device signed in to the account.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GallerySession {
    pub id: String,
    /// The session asking.
    pub current: bool,
    pub device_os: String,
    pub device_type: String,
    pub app_version: Option<String>,
    pub updated_at: String,
}

impl From<Session> for GallerySession {
    fn from(session: Session) -> GallerySession {
        GallerySession {
            id: session.id,
            current: session.current,
            device_os: session.device_os,
            device_type: session.device_type,
            app_version: session.app_version,
            updated_at: written(session.updated_at),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryNotification {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    /// `success`, `error`, `warning` or `info`.
    pub level: String,
    pub created_at: String,
    /// None while unread.
    pub read_at: Option<String>,
}

impl From<Notification> for GalleryNotification {
    fn from(notification: Notification) -> GalleryNotification {
        GalleryNotification {
            id: notification.id,
            title: notification.title,
            description: notification.description,
            level: notification.level.as_str().to_owned(),
            created_at: written(notification.created_at),
            read_at: notification.read_at.map(written),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Rename the account; the account as it then is.
    pub async fn rename_account(&self, name: String) -> Result<GalleryAccount, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = AccountChanges { name: Some(name), ..AccountChanges::default() };
            Ok(client.update_me(&changes).await.map_err(refused)?.into())
        })
        .await
    }

    /// Change the account's password, signing its other devices out when asked.
    pub async fn change_password(&self, current: String, new: String, sign_out_others: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.change_password(&current, &new, sign_out_others).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Set the account's picture from a JPEG's bytes.
    pub async fn set_profile_picture(&self, jpeg: Vec<u8>) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.set_profile_image(jpeg.into(), "profile.jpg", "image/jpeg").await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn remove_profile_picture(&self) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_profile_image().await.map_err(refused) }).await
    }

    pub async fn api_keys(&self) -> Result<Vec<GalleryApiKey>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.api_keys().await.map_err(refused)?.into_iter().map(GalleryApiKey::from).collect()) }).await
    }

    pub async fn create_api_key(&self, name: String, permissions: Vec<String>) -> Result<GalleryNewApiKey, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let made = client.create_api_key(&name, &permissions).await.map_err(refused)?;
            Ok(GalleryNewApiKey { secret: made.secret.expose().to_owned(), key: made.key.into() })
        })
        .await
    }

    pub async fn rename_api_key(&self, id: String, name: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.update_api_key(&id, Some(&name), None).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn delete_api_key(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_api_key(&id).await.map_err(refused) }).await
    }

    /// The devices signed in to the account.
    pub async fn sessions(&self) -> Result<Vec<GallerySession>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { Ok(client.sessions().await.map_err(refused)?.into_iter().map(GallerySession::from).collect()) }).await
    }

    /// Sign a device out.
    pub async fn delete_session(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_session(&id).await.map_err(refused) }).await
    }

    /// Sign every other device out.
    pub async fn delete_other_sessions(&self) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_other_sessions().await.map_err(refused) }).await
    }

    /// The account's notifications, newest first.
    pub async fn notifications(&self) -> Result<Vec<GalleryNotification>, BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let notifications = client.notifications(&NotificationFilter::default()).await.map_err(refused)?;
            Ok(notifications.into_iter().map(GalleryNotification::from).collect())
        })
        .await
    }

    /// Mark notifications read, now.
    pub async fn mark_notifications_read(&self, ids: Vec<String>) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.mark_notifications(&ids, Some(chrono::Utc::now())).await.map_err(refused) }).await
    }

    pub async fn delete_notification(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_notification(&id).await.map_err(refused) }).await
    }
}

// Administration's changes: accounts, external libraries, job queues.

/// An account as the administrator's editor sets it. An empty password leaves it as it is when changing an
/// account; no quota is no limit.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryAccountSettings {
    pub name: String,
    pub email: String,
    pub is_admin: bool,
    pub password: String,
    pub should_change_password: bool,
    pub quota_size_in_bytes: Option<u64>,
}

/// An external library as the administrator's editor sets it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GalleryLibrarySettings {
    pub name: String,
    pub import_paths: Vec<String>,
    pub exclusion_patterns: Vec<String>,
}

impl From<GalleryLibrarySettings> for LibrarySettings {
    fn from(settings: GalleryLibrarySettings) -> LibrarySettings {
        LibrarySettings {
            name: Some(settings.name),
            import_paths: Some(settings.import_paths),
            exclusion_patterns: Some(settings.exclusion_patterns),
        }
    }
}

#[uniffi::export]
impl ApiConnection {
    /// Make an account. Needs an administrator.
    pub async fn create_account(&self, settings: GalleryAccountSettings) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            if settings.password.is_empty() {
                return Err(failed("a new account needs a password"));
            }
            let user = NewUser {
                email: settings.email,
                name: settings.name,
                password: settings.password.into(),
                is_admin: settings.is_admin,
                should_change_password: settings.should_change_password,
                quota_size_in_bytes: settings.quota_size_in_bytes,
                ..NewUser::default()
            };
            client.create_user(&user).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Change an account: every setting, the quota removed when none, the password only when given.
    pub async fn update_account(&self, id: String, settings: GalleryAccountSettings) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let changes = UserChanges {
                email: Some(settings.email),
                name: Some(settings.name),
                password: Some(settings.password).filter(|password| !password.is_empty()).map(Into::into),
                is_admin: Some(settings.is_admin),
                should_change_password: Some(settings.should_change_password),
                quota_size_in_bytes: Some(settings.quota_size_in_bytes),
                ..UserChanges::default()
            };
            client.update_user(&id, &changes).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Delete an account: kept for the server's grace period, or at once with `force`.
    pub async fn delete_account(&self, id: String, force: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.delete_user(&id, force).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Bring back an account deleted within the grace period.
    pub async fn restore_account(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.restore_user(&id).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn create_library(&self, owner_id: String, settings: GalleryLibrarySettings) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.create_library(&owner_id, &settings.into()).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    pub async fn update_library(&self, id: String, settings: GalleryLibrarySettings) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            client.update_library(&id, &settings.into()).await.map_err(refused)?;
            Ok(())
        })
        .await
    }

    /// Look through a library's import paths for new and changed files.
    pub async fn scan_library(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.scan_library(&id).await.map_err(refused) }).await
    }

    pub async fn delete_library(&self, id: String) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move { client.delete_library(&id).await.map_err(refused) }).await
    }

    /// Tell a job queue to `pause`, `resume`, `empty` (its waiting jobs), `clear-failed`, or `start` its work for the
    /// photos that lack it (every photo with `force`), as the web app's job page does.
    pub async fn command_queue(&self, name: String, command: String, force: bool) -> Result<(), BridgeError> {
        let client = self.client.clone();
        on_runtime(async move {
            let queue = QueueName::from(name);
            match command.as_str() {
                "pause" | "resume" => {
                    client.set_queue_paused(&queue, command == "pause").await.map_err(refused)?;
                }
                "empty" => client.clear_queue(&queue, false).await.map_err(refused)?,
                _ => {
                    client.command_queue(&queue, &QueueCommand::from(command), force).await.map_err(refused)?;
                }
            }
            Ok(())
        })
        .await
    }
}

/// Why a typed call failed, in the kinds the app tells apart: signed out, refused, gone, out of reach.
fn refused(error: ApiError) -> BridgeError {
    match error {
        ApiError::Unauthorized => BridgeError::NotAuthenticated,
        ApiError::Forbidden { .. } => BridgeError::NotPermitted { message: error.to_string() },
        ApiError::NotFound => BridgeError::NoSuchItem,
        ApiError::Offline(_) | ApiError::Transient { .. } => BridgeError::ServerUnreachable { message: error.to_string() },
        other => match other.refusal() {
            Some((status, message)) => BridgeError::Refused { status, message: if message.is_empty() { other.to_string() } else { message } },
            None => failed(other),
        },
    }
}

fn pairs(fields: Vec<ApiField>) -> Vec<(String, String)> {
    fields.into_iter().map(|field| (field.name, field.value)).collect()
}

/// Why no answer came, in the kinds the app tells apart.
fn unanswered(error: ApiError) -> BridgeError {
    match error {
        ApiError::Offline(message) => BridgeError::ServerUnreachable { message },
        other => failed(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verso_says_which_it_is() {
        assert!(crate::user_agent().starts_with("verso/"));
        assert!(crate::user_agent().ends_with(" (macOS)"));
    }

    #[test]
    fn verso_drive_is_off_until_switched_on() {
        assert!(!crate::drive_switched_on(String::new()));
        assert!(crate::drive_switched_on("[mount]\nenabled = true\n".to_owned()));
    }

    #[test]
    fn a_server_address_is_taken_as_its_api() {
        assert!(ApiConnection::new("https://photos.example.org".to_owned(), None).is_ok());
        assert!(ApiConnection::new("https://photos.example.org/api/".to_owned(), None).is_ok());
        assert!(matches!(ApiConnection::new("photos".to_owned(), None), Err(BridgeError::Failed { .. })));
    }

    #[test]
    fn a_month_reads_as_the_app_lays_it_out() {
        use chrono::TimeZone;
        let asset = BucketAsset {
            id: "a".to_owned(),
            file_created_at: chrono::Utc.with_ymd_and_hms(2025, 3, 4, 10, 0, 0).unwrap(),
            local_offset_hours: 1.0,
            is_trashed: false,
            visibility: immich_api::Visibility::Archive,
            is_image: false,
            ratio: Some(1.5),
            thumbhash: None,
            is_favorite: true,
            duration_ms: Some(1500),
            live_photo_video_id: None,
            owner_id: Some("owner".to_owned()),
            stack: Some(("stack".to_owned(), 3)),
            coordinates: Some((50.8, 4.3)),
            city: Some("Brussels".to_owned()),
            country: Some("Belgium".to_owned()),
        };
        let shown = TimelineAsset::from(asset);
        assert_eq!(shown.file_created_at, "2025-03-04T10:00:00.000Z", "as Immich writes it");
        assert_eq!(shown.visibility, "archive");
        assert_eq!((shown.stack_id.as_deref(), shown.stack_count), (Some("stack"), Some(3)));
        assert_eq!((shown.latitude, shown.longitude), (Some(50.8), Some(4.3)));
        assert_eq!((shown.city.as_deref(), shown.country.as_deref()), (Some("Brussels"), Some("Belgium")));
    }

    #[test]
    fn an_album_reads_as_the_app_shows_it() {
        use chrono::TimeZone;
        let owner = User { id: "me".to_owned(), name: "Me".to_owned(), ..User::default() };
        let album = Album {
            id: "a".to_owned(),
            name: "Trip".to_owned(),
            created_at: chrono::Utc.with_ymd_and_hms(2025, 1, 2, 3, 4, 5).unwrap(),
            last_modified_asset_timestamp: Some(chrono::Utc.with_ymd_and_hms(2025, 6, 1, 0, 0, 0).unwrap()),
            members: vec![AlbumMember { user: owner, role: immich_api::AlbumRole::Owner }],
            order: Some(immich_api::AssetOrder::Asc),
            ..Album::default()
        };
        let shown = GalleryAlbum::from(album);
        assert_eq!(shown.created_at, "2025-01-02T03:04:05.000Z");
        assert_eq!(shown.last_modified_asset_timestamp.as_deref(), Some("2025-06-01T00:00:00.000Z"));
        assert_eq!(shown.start_date, None, "an empty album has no dates");
        assert_eq!((shown.members[0].role.as_str(), shown.members[0].user.id.as_str()), ("owner", "me"));
        assert_eq!(shown.members[0].user.profile_image_path, None, "no picture is none, not empty");
        assert_eq!(shown.order.as_deref(), Some("asc"));
    }

    #[test]
    fn a_person_reads_as_the_app_shows_it() {
        let person = Person {
            id: "p".to_owned(),
            name: "Ada".to_owned(),
            is_hidden: false,
            is_favorite: true,
            birth_date: chrono::NaiveDate::from_ymd_opt(1990, 4, 23),
            thumbnail_path: String::new(),
            color: None,
            created_at: None,
            updated_at: None,
        };
        let shown = GalleryPerson::from(person);
        assert_eq!(shown.birth_date.as_deref(), Some("1990-04-23"), "as Immich writes it");
        assert!(shown.is_favorite && !shown.is_hidden);
    }

    #[test]
    fn a_photo_reads_as_the_app_shows_it() {
        use chrono::TimeZone;
        let taken = chrono::Utc.with_ymd_and_hms(2025, 3, 4, 9, 0, 0).unwrap();
        let asset = AssetDetails {
            id: "a".to_owned(),
            file_created_at: taken,
            local_date_time: chrono::NaiveDate::from_ymd_opt(2025, 3, 4).and_then(|day| day.and_hms_opt(10, 0, 0)),
            kind: immich_api::AssetKind::Video,
            duration_ms: Some(1500),
            exif: Some(Exif { rating: Some(4), exposure_time: Some("1/250".to_owned()), ..Exif::default() }),
            ..AssetDetails::default()
        };
        let shown = GalleryAsset::from(asset);
        assert_eq!(shown.file_created_at, "2025-03-04T09:00:00.000Z");
        assert_eq!(shown.local_date_time, "2025-03-04T10:00:00.000Z", "the wall clock, as Immich writes it");
        assert_eq!(shown.kind, "VIDEO");
        let exif = shown.exif.unwrap();
        assert_eq!((exif.rating, exif.exposure_time.as_deref()), (Some(4), Some("1/250")));

        let without_local = GalleryAsset::from(AssetDetails { file_created_at: taken, ..AssetDetails::default() });
        assert_eq!(without_local.local_date_time, without_local.file_created_at, "no wall clock reads as the UTC time");
    }

    #[test]
    fn a_change_says_what_immich_api_sends() {
        let rated = GalleryAssetChanges { rating: Some(4), favorite: Some(true), ..GalleryAssetChanges::default() }.into_changes().unwrap();
        assert_eq!((rated.rating, rated.favorite), (Some(Some(4)), Some(true)));
        let cleared = GalleryAssetChanges { rating: Some(4), clear_rating: true, ..GalleryAssetChanges::default() }.into_changes().unwrap();
        assert_eq!(cleared.rating, Some(None), "clearing wins");
        let rejected = GalleryAssetChanges { rating: Some(-1), ..GalleryAssetChanges::default() }.into_changes().unwrap();
        assert_eq!(rejected.rating, Some(Some(-1)));
        let dated = GalleryAssetChanges { date_time_original: Some("2025-03-04T10:00:00+01:00".to_owned()), ..GalleryAssetChanges::default() };
        assert_eq!(dated.into_changes().unwrap().date_time_original.unwrap().offset().local_minus_utc(), 3600);
        let archived = GalleryAssetChanges { visibility: Some("archive".to_owned()), ..GalleryAssetChanges::default() }.into_changes().unwrap();
        assert_eq!(archived.visibility, Some(Visibility::Archive));
        assert!(GalleryAssetChanges { date_time_original: Some("yesterday".to_owned()), ..GalleryAssetChanges::default() }.into_changes().is_err());
    }

    #[test]
    fn a_link_editors_settings_say_what_immich_api_sends() {
        let options = GallerySharingOptions {
            description: "Trip".to_owned(),
            expires_at: Some("2026-12-24T18:00:00+01:00".to_owned()),
            allow_download: true,
            show_metadata: true,
            ..GallerySharingOptions::default()
        };
        let changes = options.clone().into_changes().unwrap();
        assert_eq!(changes.description, Some(Some("Trip".to_owned())));
        assert_eq!(changes.slug, Some(None), "an empty slug is removed");
        assert_eq!(changes.password, Some(None), "an empty password is removed");
        assert_eq!(changes.expires_at.unwrap().unwrap().to_rfc3339(), "2026-12-24T17:00:00+00:00");
        let kept = GallerySharingOptions { keep_password: true, ..options.clone() }.into_changes().unwrap();
        assert_eq!(kept.password, None, "a kept password is left out");
        let link = options.into_new_link(Some("album".to_owned()), vec!["photo".to_owned()]).unwrap();
        assert_eq!((link.kind, link.asset_ids.len(), link.password), (SharedLinkKind::Album, 0, None));
    }

    #[test]
    fn a_birth_date_is_set_or_cleared() {
        let set = GalleryPersonChanges { birth_date: Some("1990-04-23".to_owned()), ..GalleryPersonChanges::default() };
        assert_eq!(set.into_changes().unwrap().birth_date, Some(chrono::NaiveDate::from_ymd_opt(1990, 4, 23)));
        let cleared = GalleryPersonChanges { clear_birth_date: true, ..GalleryPersonChanges::default() };
        assert_eq!(cleared.into_changes().unwrap().birth_date, Some(None));
    }

    #[test]
    fn edit_steps_go_as_immich_api_sends_them_and_come_back_the_same() {
        let crop = GalleryEdit { action: "crop".to_owned(), x: Some(1), y: Some(2), width: Some(30), height: Some(40), ..GalleryEdit::default() };
        let turn = GalleryEdit { action: "rotate".to_owned(), angle: Some(90), ..GalleryEdit::default() };
        let flip = GalleryEdit { action: "mirror".to_owned(), axis: Some("horizontal".to_owned()), ..GalleryEdit::default() };
        for step in [crop, turn, flip] {
            assert_eq!(GalleryEdit::from(step.clone().into_edit().unwrap()), step);
        }
        let unknown = GalleryEdit { action: "blur".to_owned(), angle: Some(3), ..GalleryEdit::default() };
        assert_eq!(
            unknown.into_edit().unwrap(),
            AssetEdit::Other { action: "blur".to_owned(), parameters: serde_json::json!({ "angle": 3 }) }
        );
        let incomplete = GalleryEdit { action: "crop".to_owned(), x: Some(1), ..GalleryEdit::default() };
        assert!(incomplete.into_edit().is_err(), "a crop without its size is refused before it is sent");
    }

    #[test]
    fn the_apps_sources_are_immich_apis_scopes() {
        assert_eq!(TimelineScope::from(TimelineSource::Album { id: "x".to_owned() }), TimelineScope::Album("x".to_owned()));
        assert_eq!(TimelineScope::from(TimelineSource::Partner { user_id: "u".to_owned() }), TimelineScope::Partner("u".to_owned()));
        let settings = TimelineSettings { stacked: true, oldest_first: true, ..TimelineSettings::default() };
        let options = TimelineOptions::from(settings);
        assert!(options.stacked && options.oldest_first && !options.favorites_only && !options.by_date_added);
    }

    #[test]
    fn a_refusal_keeps_its_kind() {
        assert_eq!(refused(ApiError::Unauthorized), BridgeError::NotAuthenticated);
        assert_eq!(refused(ApiError::NotFound), BridgeError::NoSuchItem);
        assert!(matches!(refused(ApiError::Offline("down".to_owned())), BridgeError::ServerUnreachable { .. }));
        assert!(matches!(refused(ApiError::Protocol("odd".to_owned())), BridgeError::Failed { .. }));
        assert_eq!(
            refused(ApiError::Protocol("HTTP 400: Incorrect PIN code".to_owned())),
            BridgeError::Refused { status: 400, message: "Incorrect PIN code".to_owned() }
        );
    }

    #[tokio::test]
    async fn a_server_that_cannot_be_reached_is_unreachable() {
        let credential = Some(Credential::ApiKey { key: "key".to_owned() });
        let connection = ApiConnection::new("http://127.0.0.1:9".to_owned(), credential).unwrap();
        let answer = connection.send("GET".to_owned(), "albums".to_owned(), vec![], vec![], None).await;
        assert!(matches!(answer, Err(BridgeError::ServerUnreachable { .. })));
    }
}
