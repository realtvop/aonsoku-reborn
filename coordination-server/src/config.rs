//! Runtime configuration for the coordination server.
//!
//! The server ships as a single binary used for both self-hosted and public
//! deployments. Public mode applies strict SSRF rules (HTTPS-only Navidrome
//! identity URLs, private/loopback addresses rejected); self-hosted mode may
//! relax those via explicit opt-in flags. See design §6.4 and §14.

use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

/// Deployment trust profile.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum DeploymentMode {
    /// Public multi-tenant profile: strict SSRF protection, conservative
    /// quotas. This is the default.
    #[default]
    Public,
    /// Self-hosted profile: administrators may opt into HTTP and private
    /// network Navidrome identity URLs.
    SelfHosted,
}

impl DeploymentMode {
    pub fn allow_http_identity(self) -> bool {
        matches!(self, DeploymentMode::SelfHosted)
    }

    pub fn allow_private_network_identity(self) -> bool {
        matches!(self, DeploymentMode::SelfHosted)
    }
}

impl<'de> Deserialize<'de> for DeploymentMode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        match value.as_str() {
            "public" => Ok(Self::Public),
            "self-hosted" | "self_hosted" => Ok(Self::SelfHosted),
            _ => Err(serde::de::Error::custom(
                "deployment must be `public` or `self-hosted`",
            )),
        }
    }
}

/// SSRF / verification policy.
#[derive(Debug, Clone)]
pub struct SsrfPolicy {
    pub allow_http: bool,
    pub allow_private_network: bool,
    pub connect_timeout: std::time::Duration,
    pub first_byte_timeout: std::time::Duration,
    pub total_timeout: std::time::Duration,
    pub max_body_bytes: u64,
    pub max_redirects: u32,
}

impl SsrfPolicy {
    pub fn strict() -> Self {
        Self {
            allow_http: false,
            allow_private_network: false,
            connect_timeout: std::time::Duration::from_secs(5),
            first_byte_timeout: std::time::Duration::from_secs(5),
            total_timeout: std::time::Duration::from_secs(15),
            max_body_bytes: 64 * 1024,
            max_redirects: 2,
        }
    }

    pub fn permissive() -> Self {
        let mut s = Self::strict();
        s.allow_http = true;
        s.allow_private_network = true;
        s
    }
}

/// Top-level server configuration.
#[derive(Debug, Clone)]
pub struct Config {
    pub listen: SocketAddr,
    pub database_url: String,
    pub data_dir: PathBuf,
    pub deployment: DeploymentMode,
    pub ssrf: SsrfPolicy,
    /// Stable secret key used for HMAC account lookup keys and short id
    /// derivation. Must be persisted across restarts and included in
    /// backups; loss invalidates existing account lookups (design §6.1).
    pub stable_key: String,
    /// Access token lifetime for HTTP auth (design §6.3).
    pub access_token_ttl: chrono::Duration,
    /// Refresh token inactivity expiry (design §6.3).
    pub refresh_token_max_age: chrono::Duration,
    /// WebSocket ticket lifetime (design §6.3).
    pub ws_ticket_ttl: chrono::Duration,
    /// Challenge lifetime for one-time registration challenge (design §6.2).
    pub challenge_ttl: chrono::Duration,
    /// Heartbeat interval / offline detection thresholds (design §9.2).
    pub heartbeat_interval: std::time::Duration,
    pub heartbeat_grace: std::time::Duration,
    /// Offline snapshot retention window (design §9.2, §11.3).
    pub offline_snapshot_ttl: chrono::Duration,
    /// History defaults (design §7.1).
    pub default_history_limit: u32,
    pub min_history_limit: u32,
    pub max_history_limit: u32,
    /// Maximum serialized realtime message size (design §7.3).
    pub max_message_bytes: u64,
    /// Maximum songs per snapshot (design §7.3).
    pub max_snapshot_songs: u32,
    /// Tombstone retention for history deletion sync (design §8.3).
    pub tombstone_retention: chrono::Duration,
    /// Retention for `transferred` playback session rows before GC deletes
    /// them (design §11.3). Bounds database growth from repeated handoffs.
    pub transferred_retention: chrono::Duration,
    /// Interval between transferred-session GC sweeps.
    pub transferred_gc_interval: std::time::Duration,
    /// Interval between background flushes of dirty in-memory playback
    /// sessions to SQLite (design §9.2). Snapshot upserts are debounced:
    /// they hit the cache immediately and the backing store at most once
    /// per interval. Authoritative state transitions (Offline/Transferred/
    /// generation bumps) flush immediately regardless of this interval.
    pub snapshot_flush_interval: std::time::Duration,
}

impl Config {
    pub fn new(listen: SocketAddr, data_dir: PathBuf, stable_key: String) -> Self {
        Self::from_file_config(FileConfig {
            server: Some(ServerConfig {
                listen: Some(listen),
                data_dir: Some(data_dir),
                stable_key: Some(stable_key),
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    pub fn load(path: Option<PathBuf>) -> Result<Self> {
        let mut file_config = match path {
            Some(path) => {
                let raw = std::fs::read_to_string(&path)
                    .with_context(|| format!("failed to read {}", path.display()))?;
                toml::from_str::<FileConfig>(&raw)
                    .with_context(|| format!("failed to parse {}", path.display()))?
            }
            None => FileConfig::default(),
        };
        file_config.apply_env_overrides()?;
        Ok(Self::from_file_config(file_config))
    }

    fn from_file_config(file_config: FileConfig) -> Self {
        let defaults = FileConfig::default();
        let server = file_config.server.unwrap_or_default();
        let default_server = defaults.server.unwrap_or_default();
        let data_dir = server
            .data_dir
            .or(default_server.data_dir)
            .expect("default data_dir");
        let database_url = server
            .database_url
            .unwrap_or_else(|| format!("sqlite://{}/coordination.db", data_dir.display()));
        let deployment = server
            .deployment
            .or(default_server.deployment)
            .unwrap_or_default();
        let mut ssrf = match deployment {
            DeploymentMode::Public => SsrfPolicy::strict(),
            DeploymentMode::SelfHosted => SsrfPolicy::permissive(),
        };
        let ssrf_config = file_config.ssrf.unwrap_or_default();
        if let Some(v) = ssrf_config.allow_http {
            ssrf.allow_http = v;
        }
        if let Some(v) = ssrf_config.allow_private_network {
            ssrf.allow_private_network = v;
        }
        if let Some(v) = ssrf_config.connect_timeout_seconds {
            ssrf.connect_timeout = std::time::Duration::from_secs(v);
        }
        if let Some(v) = ssrf_config.first_byte_timeout_seconds {
            ssrf.first_byte_timeout = std::time::Duration::from_secs(v);
        }
        if let Some(v) = ssrf_config.total_timeout_seconds {
            ssrf.total_timeout = std::time::Duration::from_secs(v);
        }
        if let Some(v) = ssrf_config.max_body_bytes {
            ssrf.max_body_bytes = v;
        }
        if let Some(v) = ssrf_config.max_redirects {
            ssrf.max_redirects = v;
        }

        let auth = file_config.auth.unwrap_or_default();
        let realtime = file_config.realtime.unwrap_or_default();
        let history = file_config.history.unwrap_or_default();
        let retention = file_config.retention.unwrap_or_default();
        Self {
            listen: server
                .listen
                .or(default_server.listen)
                .expect("default listen"),
            database_url,
            data_dir,
            deployment,
            ssrf,
            stable_key: server.stable_key.unwrap_or_else(|| {
                tracing::warn!(
                    "stable_key not set; using ephemeral key. Account lookups will not survive restart."
                );
                "ephemeral-dev-key-do-not-use-in-production".to_string()
            }),
            access_token_ttl: chrono_seconds(auth.access_token_ttl_seconds.unwrap_or(15 * 60)),
            refresh_token_max_age: chrono_seconds(
                auth.refresh_token_max_age_seconds.unwrap_or(90 * 24 * 60 * 60),
            ),
            ws_ticket_ttl: chrono_seconds(auth.ws_ticket_ttl_seconds.unwrap_or(30)),
            challenge_ttl: chrono_seconds(auth.challenge_ttl_seconds.unwrap_or(60)),
            heartbeat_interval: std::time::Duration::from_secs(
                realtime.heartbeat_interval_seconds.unwrap_or(15),
            ),
            heartbeat_grace: std::time::Duration::from_secs(
                realtime.heartbeat_grace_seconds.unwrap_or(45),
            ),
            offline_snapshot_ttl: chrono_seconds(
                retention
                    .offline_snapshot_ttl_seconds
                    .unwrap_or(8 * 60 * 60),
            ),
            default_history_limit: history.default_history_limit.unwrap_or(100),
            min_history_limit: history.min_history_limit.unwrap_or(1),
            max_history_limit: history.max_history_limit.unwrap_or(1000),
            max_message_bytes: realtime.max_message_bytes.unwrap_or(512 * 1024),
            max_snapshot_songs: realtime.max_snapshot_songs.unwrap_or(2000),
            tombstone_retention: chrono_seconds(
                retention
                    .tombstone_retention_seconds
                    .unwrap_or(30 * 24 * 60 * 60),
            ),
            transferred_retention: chrono_seconds(
                retention
                    .transferred_retention_seconds
                    .unwrap_or(7 * 24 * 60 * 60),
            ),
            transferred_gc_interval: std::time::Duration::from_secs(
                retention
                    .transferred_gc_interval_seconds
                    .unwrap_or(24 * 60 * 60),
            ),
            snapshot_flush_interval: std::time::Duration::from_secs(
                realtime.snapshot_flush_interval_seconds.unwrap_or(30),
            ),
        }
    }

    pub fn ssrf_policy(&self) -> &SsrfPolicy {
        &self.ssrf
    }
}

fn chrono_seconds(seconds: u64) -> chrono::Duration {
    chrono::Duration::seconds(seconds.try_into().unwrap_or(i64::MAX))
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct FileConfig {
    server: Option<ServerConfig>,
    auth: Option<AuthConfig>,
    ssrf: Option<SsrfConfig>,
    realtime: Option<RealtimeConfig>,
    history: Option<HistoryConfig>,
    retention: Option<RetentionConfig>,
}

impl FileConfig {
    fn apply_env_overrides(&mut self) -> Result<()> {
        let server = self.server.get_or_insert_with(ServerConfig::default);
        if let Ok(value) = std::env::var("AONSOKU_COORD_LISTEN") {
            server.listen = Some(value.parse().context("valid AONSOKU_COORD_LISTEN")?);
        }
        if let Ok(value) = std::env::var("AONSOKU_COORD_DATA_DIR") {
            server.data_dir = Some(PathBuf::from(value));
        }
        if let Ok(value) = std::env::var("AONSOKU_COORD_DATABASE_URL") {
            server.database_url = Some(value);
        }
        if let Ok(value) = std::env::var("AONSOKU_COORD_STABLE_KEY") {
            server.stable_key = Some(value);
        }
        if let Ok(value) = std::env::var("AONSOKU_COORD_DEPLOYMENT") {
            server.deployment = Some(parse_deployment_mode(&value)?);
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
struct ServerConfig {
    listen: Option<SocketAddr>,
    data_dir: Option<PathBuf>,
    database_url: Option<String>,
    deployment: Option<DeploymentMode>,
    stable_key: Option<String>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            listen: Some("127.0.0.1:3000".parse().expect("default listen addr")),
            data_dir: Some(std::env::current_dir().unwrap().join("data")),
            database_url: None,
            deployment: Some(DeploymentMode::Public),
            stable_key: None,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct AuthConfig {
    access_token_ttl_seconds: Option<u64>,
    refresh_token_max_age_seconds: Option<u64>,
    ws_ticket_ttl_seconds: Option<u64>,
    challenge_ttl_seconds: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct SsrfConfig {
    allow_http: Option<bool>,
    allow_private_network: Option<bool>,
    connect_timeout_seconds: Option<u64>,
    first_byte_timeout_seconds: Option<u64>,
    total_timeout_seconds: Option<u64>,
    max_body_bytes: Option<u64>,
    max_redirects: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RealtimeConfig {
    heartbeat_interval_seconds: Option<u64>,
    heartbeat_grace_seconds: Option<u64>,
    max_message_bytes: Option<u64>,
    max_snapshot_songs: Option<u32>,
    snapshot_flush_interval_seconds: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct HistoryConfig {
    default_history_limit: Option<u32>,
    min_history_limit: Option<u32>,
    max_history_limit: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RetentionConfig {
    offline_snapshot_ttl_seconds: Option<u64>,
    tombstone_retention_seconds: Option<u64>,
    transferred_retention_seconds: Option<u64>,
    transferred_gc_interval_seconds: Option<u64>,
}

fn parse_deployment_mode(value: &str) -> Result<DeploymentMode> {
    match value {
        "public" => Ok(DeploymentMode::Public),
        "self-hosted" | "self_hosted" => Ok(DeploymentMode::SelfHosted),
        _ => anyhow::bail!("AONSOKU_COORD_DEPLOYMENT must be `public` or `self-hosted`"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_mode_is_strict() {
        let c = Config::new(
            "127.0.0.1:0".parse().unwrap(),
            std::env::temp_dir().join("aonsoku-test"),
            "k".into(),
        );
        assert!(!c.ssrf.allow_http);
        assert!(!c.ssrf.allow_private_network);
        assert_eq!(c.deployment, DeploymentMode::Public);
    }

    #[test]
    fn file_config_overrides_hardcoded_defaults() {
        let raw = r#"
[server]
listen = "127.0.0.1:4000"
data_dir = "/tmp/aonsoku-coord"
stable_key = "stable"
deployment = "self-hosted"

[auth]
access_token_ttl_seconds = 120

[ssrf]
allow_http = false
connect_timeout_seconds = 9

[realtime]
heartbeat_interval_seconds = 3
max_message_bytes = 1024
max_snapshot_songs = 10
snapshot_flush_interval_seconds = 5

[history]
default_history_limit = 50
min_history_limit = 5
max_history_limit = 500

[retention]
tombstone_retention_seconds = 600
"#;
        let parsed: FileConfig = toml::from_str(raw).unwrap();
        let c = Config::from_file_config(parsed);
        assert_eq!(c.listen, "127.0.0.1:4000".parse().unwrap());
        assert_eq!(c.deployment, DeploymentMode::SelfHosted);
        assert!(!c.ssrf.allow_http);
        assert!(c.ssrf.allow_private_network);
        assert_eq!(c.ssrf.connect_timeout, std::time::Duration::from_secs(9));
        assert_eq!(c.access_token_ttl, chrono::Duration::seconds(120));
        assert_eq!(c.heartbeat_interval, std::time::Duration::from_secs(3));
        assert_eq!(c.max_message_bytes, 1024);
        assert_eq!(c.max_snapshot_songs, 10);
        assert_eq!(c.snapshot_flush_interval, std::time::Duration::from_secs(5));
        assert_eq!(c.default_history_limit, 50);
        assert_eq!(c.min_history_limit, 5);
        assert_eq!(c.max_history_limit, 500);
        assert_eq!(c.tombstone_retention, chrono::Duration::seconds(600));
    }
}
