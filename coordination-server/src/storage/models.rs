//! Core data models (design §7). Repository implementations live in
//! `repository.rs`; these structs are the in-memory shapes returned to
//! business modules.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Account row (design §7.1).
#[derive(Debug, Clone)]
pub struct Account {
    pub id: Uuid,
    /// HMAC lookup key over (normalised identity URL, normalised username).
    pub lookup_key: String,
    pub history_limit: u32,
    pub history_generation: i64,
    pub history_revision: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub deleted_at: Option<DateTime<Utc>>,
}

/// Device row (design §7.2).
#[derive(Debug, Clone)]
pub struct Device {
    pub id: Uuid,
    pub account_id: Uuid,
    pub name: String,
    pub platform: String,
    pub client_version: Option<String>,
    pub capabilities: u32,
    pub created_at: DateTime<Utc>,
    pub last_online_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub history_sync_cursor: i64,
    pub legacy_history_imported: bool,
    /// Argon2id-style hash of the refresh token (we use SHA-256 for first
    /// version; hash storage is the contract, not the algorithm).
    pub refresh_token_hash: String,
    /// Rotating refresh token family id.
    pub refresh_token_family: Uuid,
    pub refresh_token_last_used_at: Option<DateTime<Utc>>,
}

/// Playback session row (design §7.3).
#[derive(Debug, Clone)]
pub struct PlaybackSession {
    pub id: Uuid,
    pub device_id: Uuid,
    pub account_id: Uuid,
    pub generation: i64,
    pub snapshot_revision: i64,
    pub status: SessionStatus,
    pub last_snapshot: Option<String>,
    pub last_snapshot_at: Option<DateTime<Utc>>,
    pub offline_at: Option<DateTime<Utc>>,
    pub transferred_to_device: Option<Uuid>,
    pub transferred_to_session: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Session lifecycle (design §7.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStatus {
    Online,
    Offline,
    Transferred,
}

impl SessionStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            SessionStatus::Online => "online",
            SessionStatus::Offline => "offline",
            SessionStatus::Transferred => "transferred",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "online" => Some(SessionStatus::Online),
            "offline" => Some(SessionStatus::Offline),
            "transferred" => Some(SessionStatus::Transferred),
            _ => None,
        }
    }
}

/// History entry row (design §7.4, §8).
#[derive(Debug, Clone)]
pub struct HistoryEntry {
    pub event_id: Uuid,
    pub account_id: Uuid,
    pub history_generation: i64,
    pub revision: i64,
    pub logical_playback_session_id: Uuid,
    pub song_id: String,
    pub song_title: Option<String>,
    pub song_artist: Option<String>,
    pub song_album: Option<String>,
    pub song_duration: Option<f64>,
    pub client_entered_at: DateTime<Utc>,
    pub server_clock_offset: Option<i64>,
    pub server_received_at: DateTime<Utc>,
    pub deleted: bool,
}

/// History operation (design §7.4).
#[derive(Debug, Clone)]
pub struct HistoryOperation {
    pub operation_id: Uuid,
    pub account_id: Uuid,
    pub kind: HistoryOperationKind,
    pub revision: i64,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryOperationKind {
    Add,
    DeleteOne,
    Clear,
    SetLimit,
}

impl HistoryOperationKind {
    pub fn as_str(self) -> &'static str {
        match self {
            HistoryOperationKind::Add => "add",
            HistoryOperationKind::DeleteOne => "delete_one",
            HistoryOperationKind::Clear => "clear",
            HistoryOperationKind::SetLimit => "set_limit",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "add" => Some(HistoryOperationKind::Add),
            "delete_one" => Some(HistoryOperationKind::DeleteOne),
            "clear" => Some(HistoryOperationKind::Clear),
            "set_limit" => Some(HistoryOperationKind::SetLimit),
            _ => None,
        }
    }
}

/// Tombstone for a deleted history event (design §8.3).
#[derive(Debug, Clone)]
pub struct HistoryTombstone {
    pub event_id: Uuid,
    pub account_id: Uuid,
    pub revision: i64,
    pub created_at: DateTime<Utc>,
}

/// Device presence / connection metadata kept in SQLite (design §9.2,
/// §14 "service restart recovery").
#[derive(Debug, Clone)]
pub struct DevicePresence {
    pub device_id: Uuid,
    pub account_id: Uuid,
    pub is_online: bool,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub last_seq: i64,
}
