//! What a server says about itself beyond its version: whether it answers, its build and tools, its version
//! history, and (for admins) its storage and what each user stores.

use chrono::{DateTime, Utc};
use reqwest::Method;
use serde::Deserialize;

use crate::client::{check, read_json, Client};
use crate::dates::serde_dates;
use crate::error::{ApiError, RequestShape};
use crate::wire::{endpoints, Endpoint};

/// How long a ping may take: an answer is quick, and a server that takes longer is as good as unreachable.
const PING_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

pub(crate) const ENDPOINTS: &[Endpoint] = endpoints![
    GET "/server/ping" -,
    GET "/server/about" "server.about",
    GET "/server/version-history" -,
    GET "/server/statistics" "server.statistics",
    GET "/server/storage" "server.storage",
];

/// The server's build and the tools it runs (`ServerAboutResponseDto`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ServerAbout {
    /// Such as `v3.3.6`.
    pub version: String,
    pub version_url: String,
    pub licensed: bool,
    pub build: Option<String>,
    pub source_commit: Option<String>,
    pub nodejs: Option<String>,
    pub ffmpeg: Option<String>,
    pub imagemagick: Option<String>,
    pub libvips: Option<String>,
    pub exiftool: Option<String>,
    pub repository_url: Option<String>,
}

/// A version the server has run, from its first start (`ServerVersionHistoryResponseDto`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct VersionHistoryEntry {
    pub id: String,
    /// Such as `3.3.6`.
    pub version: String,
    #[serde(deserialize_with = "serde_dates::utc")]
    pub created_at: DateTime<Utc>,
}

/// What the server stores, in all and per user (`ServerStatsResponseDto`). Sizes in bytes.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ServerStatistics {
    pub photos: u64,
    pub videos: u64,
    pub usage: u64,
    pub usage_photos: u64,
    pub usage_videos: u64,
    pub usage_by_user: Vec<UserUsage>,
}

/// What one user stores (`UsageByUserDto`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct UserUsage {
    pub user_id: String,
    pub user_name: String,
    pub photos: u64,
    pub videos: u64,
    pub usage: u64,
    pub usage_photos: u64,
    pub usage_videos: u64,
    pub quota_size_in_bytes: Option<u64>,
}

/// The disk the server stores Assets on (`ServerStorageResponseDto`). Sizes in bytes.
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ServerStorage {
    #[serde(rename = "diskSizeRaw")]
    pub disk_size: u64,
    #[serde(rename = "diskUseRaw")]
    pub disk_use: u64,
    #[serde(rename = "diskAvailableRaw")]
    pub disk_available: u64,
    pub disk_usage_percentage: f64,
}

impl Client {
    /// Whether the server answers (`GET /server/ping`), within a few seconds. Needs no credential.
    pub async fn ping(&self) -> Result<(), ApiError> {
        #[derive(Deserialize, Default)]
        #[serde(default)]
        struct Pong {
            res: String,
        }
        // Once, with a short limit, and asked even while the server is taken as unreachable: how an app finds out it
        // can be reached again (`Client::set_reachable`).
        let builder = self.request(Method::GET, &["server", "ping"]).timeout(PING_TIMEOUT);
        let response = check(self.execute_once(builder).await?, RequestShape::Plain).await?;
        let answer: Pong = read_json(response, "server/ping").await?;
        if answer.res == "pong" {
            Ok(())
        } else {
            Err(ApiError::Protocol(format!("the server answered the ping with `{}`", answer.res)))
        }
    }

    /// The server's build and tools (`GET /server/about`). Needs `server.about`.
    pub async fn server_about(&self) -> Result<ServerAbout, ApiError> {
        self.call(Method::GET, &["server", "about"], &[]).await
    }

    /// Every version the server has run (`GET /server/version-history`).
    /// Needs no credential.
    pub async fn version_history(&self) -> Result<Vec<VersionHistoryEntry>, ApiError> {
        self.call(Method::GET, &["server", "version-history"], &[]).await
    }

    /// What the server stores, per user (`GET /server/statistics`). Needs `server.statistics`.
    pub async fn server_statistics(&self) -> Result<ServerStatistics, ApiError> {
        self.call(Method::GET, &["server", "statistics"], &[]).await
    }

    /// The disk the server stores Assets on (`GET /server/storage`). Needs `server.storage`.
    pub async fn server_storage(&self) -> Result<ServerStorage, ApiError> {
        self.call(Method::GET, &["server", "storage"], &[]).await
    }
}
