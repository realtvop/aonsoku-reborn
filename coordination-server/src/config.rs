//! Runtime configuration for the coordination server.
//!
//! The server ships as a single binary used for both self-hosted and public
//! deployments. Public mode applies strict SSRF rules (HTTPS-only Navidrome
//! identity URLs, private/loopback addresses rejected); self-hosted mode may
//! relax those via explicit opt-in flags. See design §6.4 and §14.

use std::{net::SocketAddr, path::PathBuf};

/// Deployment trust profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeploymentMode {
    /// Public multi-tenant profile: strict SSRF protection, conservative
    /// quotas. This is the default.
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
}

impl Config {
    pub fn new(listen: SocketAddr, data_dir: PathBuf, stable_key: String) -> Self {
        let database_url = format!("sqlite://{}/coordination.db", data_dir.display());
        let deployment = DeploymentMode::Public;
        let ssrf = match deployment {
            DeploymentMode::Public => SsrfPolicy::strict(),
            DeploymentMode::SelfHosted => SsrfPolicy::permissive(),
        };
        Self {
            listen,
            database_url,
            data_dir,
            deployment,
            ssrf,
            stable_key,
            access_token_ttl: chrono::Duration::minutes(15),
            refresh_token_max_age: chrono::Duration::days(90),
            ws_ticket_ttl: chrono::Duration::seconds(30),
            challenge_ttl: chrono::Duration::seconds(60),
            heartbeat_interval: std::time::Duration::from_secs(15),
            heartbeat_grace: std::time::Duration::from_secs(45),
            offline_snapshot_ttl: chrono::Duration::hours(8),
            default_history_limit: 100,
            min_history_limit: 1,
            max_history_limit: 1000,
            max_message_bytes: 512 * 1024,
            max_snapshot_songs: 2000,
            tombstone_retention: chrono::Duration::days(30),
        }
    }

    pub fn ssrf_policy(&self) -> &SsrfPolicy {
        &self.ssrf
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
}
