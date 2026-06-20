//! Versioned protocol schema for the coordination realtime channel and the
//! JSON payloads shared with all clients (design §9, §7.3, §10, §11).
//!
//! The protocol is versioned (`PROTOCOL_VERSION`). Messages carry an explicit
//! version field so the server and clients negotiate capabilities on
//! handshake (design §9.1). Both the realtime WebSocket channel and the HTTP
//! API share the snapshot / command / handoff payloads defined here.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Current protocol major version (design §17.1).
pub const PROTOCOL_VERSION: u32 = 1;

/// Bit flags describing optional protocol capabilities (design §9.1).
/// Clients and the server negotiate which feature groups to enable on
/// handshake; disabled capabilities must not be assumed present.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct CapabilitySet(pub u32);

impl CapabilitySet {
    pub const NONE: Self = Self(0);
    pub const HISTORY: Self = Self(1 << 0);
    pub const OBSERVE: Self = Self(1 << 1);
    pub const CONTROL: Self = Self(1 << 2);
    pub const HANDOFF: Self = Self(1 << 3);

    pub fn has(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }
    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
    pub fn intersect(self, other: Self) -> Self {
        Self(self.0 & other.0)
    }
}

/// Identifies a realtime message uniquely across reconnect boundaries.
pub type MessageId = Uuid;
/// Connection identifier assigned by the server.
pub type ConnectionId = Uuid;
/// Stable device identifier.
pub type DeviceId = Uuid;
/// Stable account identifier.
pub type AccountId = Uuid;
/// Playback session identifier (design §7.3).
pub type SessionId = Uuid;
/// Logical playback session ID carried across handoff.
pub type LogicalPlaybackSessionId = Uuid;
/// History event identifier (UUIDv7, design §7.4).
pub type HistoryEventId = Uuid;
/// Idempotent history operation identifier.
pub type HistoryOperationId = Uuid;
/// Server-assigned monotonic history revision number.
pub type Revision = i64;
/// Monotonic session generation counter (design §7.3).
pub type SessionGeneration = i64;
/// Per-snapshot revision incremented when a device accepts a full snapshot.
pub type SnapshotRevision = i64;
/// Per-connection sequence number for ordering.
pub type ConnectionSeq = u64;

/// Media kinds that the coordination protocol understands. First version
/// only supports songs (design §18).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Song,
}

/// Playback state snapshot (design §7.3).
///
/// The snapshot is the authoritative versioned playback state. The server
/// validates protocol fields, ranges and size, but never resolves song IDs
/// into full media objects: B uses its own metadata cache or its Navidrome
/// API to recover song metadata (design §7.3).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackSnapshot {
    pub session_id: SessionId,
    pub logical_playback_session_id: LogicalPlaybackSessionId,
    pub media_kind: MediaKind,
    pub song_id: String,
    pub progress_seconds: f64,
    pub duration_seconds: f64,
    pub is_playing: bool,
    /// Server-side sample timestamp (Unix epoch seconds, design §9.2).
    pub sampled_at: i64,

    /// Context queue song IDs (design §7.3). At most [`Config::max_snapshot_songs`].
    pub context_queue: Vec<String>,
    /// Index within the context queue, or `None` when outside the context queue.
    pub context_index: Option<u32>,
    /// Playback source identifier/name reported by the originating device
    /// (album ID, playlist ID, etc.).
    pub source_id: Option<String>,
    pub source_name: Option<String>,

    /// User queue (songs queued by the user) and whether the session is
    /// currently playing from it.
    pub user_queue: Vec<String>,
    pub in_user_queue: bool,
    /// Minimal history of recently played songs needed to restore "previous".
    pub restore_previous: Vec<String>,

    pub shuffle: bool,
    /// `off` | `one` | `all`.
    pub repeat: String,

    pub volume: Option<f64>,

    /// Accumulated effective play time (seconds) for the current logical
    /// playback session (design §8.1).
    pub accumulated_play_seconds: f64,
    /// Whether the logical session has already produced an Aonsoku history entry.
    pub history_written: bool,
    /// Whether now-playing has been reported to Navidrome for this logical session.
    pub now_playing_sent: bool,
    /// Whether a completion-state Navidrome scrobble has been sent for this logical session.
    pub scrobble_sent: bool,
}

impl PlaybackSnapshot {
    /// Enforce structural limits before the server stores a snapshot
    /// (design §7.3, §13).
    pub fn validate(
        &self,
        max_songs: u32,
        max_message_bytes: u64,
    ) -> Result<(), super::errors::CoordinationError> {
        use super::errors::{CoordinationError, ErrorCode};
        let total = self
            .context_queue
            .len()
            .saturating_add(self.user_queue.len())
            .saturating_add(self.restore_previous.len());
        if total as u32 > max_songs {
            return Err(CoordinationError::new(
                ErrorCode::PayloadTooLarge,
                "snapshot exceeds song count limit",
            ));
        }
        if self.song_id.is_empty() {
            return Err(CoordinationError::new(
                ErrorCode::BadMessage,
                "snapshot song_id is empty",
            ));
        }
        if !(0.0..=1.0).contains(&self.volume.unwrap_or(1.0)) {
            return Err(CoordinationError::new(
                ErrorCode::BadMessage,
                "snapshot volume out of range",
            ));
        }
        if self.progress_seconds < 0.0 || self.duration_seconds < 0.0 {
            return Err(CoordinationError::new(
                ErrorCode::BadMessage,
                "snapshot progress/duration must be non-negative",
            ));
        }
        match self.repeat.as_str() {
            "off" | "one" | "all" => {}
            _ => {
                return Err(CoordinationError::new(
                    ErrorCode::BadMessage,
                    "snapshot repeat must be off|one|all",
                ));
            }
        }
        let approx = serde_json::to_string(self)
            .map(|s| s.len() as u64)
            .unwrap_or(u64::MAX);
        if approx > max_message_bytes {
            return Err(CoordinationError::payload_too_large());
        }
        Ok(())
    }
}

/// Remote control commands (design §10). First-version remote capabilities.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RemoteCommand {
    Play,
    Pause,
    TogglePlayPause,
    Previous,
    Next,
    Seek {
        seconds: f64,
    },
    SetVolume {
        volume: f64,
    },
    SetShuffle {
        enabled: bool,
    },
    SetRepeat {
        mode: String,
    },
    ToggleLike,
    /// Play a song from B's local browsing context. A fetches metadata and
    /// executes (design §10 step 4).
    PlaySong {
        song_id: String,
    },
    PlayAlbum {
        album_id: String,
        index: Option<u32>,
    },
    PlayPlaylist {
        playlist_id: String,
        index: Option<u32>,
    },
    AddToQueueNext {
        song_ids: Vec<String>,
    },
    AddToQueueLast {
        song_ids: Vec<String>,
    },
    RemoveFromQueue {
        song_ids: Vec<String>,
    },
    ReorderQueue {
        from: u32,
        to: u32,
    },
    ClearQueue,
}

impl RemoteCommand {
    /// Validate command payload ranges (design §13).
    pub fn validate(&self, max_songs: u32) -> Result<(), super::errors::CoordinationError> {
        use super::errors::{CoordinationError, ErrorCode};
        let count_of = |ids: &[String]| -> u32 { ids.len() as u32 };
        match self {
            RemoteCommand::SetVolume { volume } => {
                if !(*volume >= 0.0 && *volume <= 1.0) {
                    return Err(CoordinationError::new(
                        ErrorCode::BadMessage,
                        "volume out of range",
                    ));
                }
            }
            RemoteCommand::SetRepeat { mode } => match mode.as_str() {
                "off" | "one" | "all" => {}
                _ => {
                    return Err(CoordinationError::new(
                        ErrorCode::BadMessage,
                        "repeat mode must be off|one|all",
                    ));
                }
            },
            RemoteCommand::Seek { seconds } if *seconds < 0.0 => {
                return Err(CoordinationError::new(
                    ErrorCode::BadMessage,
                    "seek seconds must be non-negative",
                ));
            }
            RemoteCommand::AddToQueueNext { song_ids }
            | RemoteCommand::AddToQueueLast { song_ids }
            | RemoteCommand::RemoveFromQueue { song_ids }
                if count_of(song_ids) > max_songs =>
            {
                return Err(CoordinationError::payload_too_large());
            }
            RemoteCommand::ReorderQueue { from, to } if from == to => {}
            _ => {}
        }
        Ok(())
    }
}

/// Handoff request payload (design §11.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoffRequest {
    pub target_device_id: DeviceId,
    pub session_id: SessionId,
    /// Expected generation of the source session at the time of the request.
    pub expected_generation: SessionGeneration,
    /// Expected snapshot revision last observed by B.
    pub expected_snapshot_revision: SnapshotRevision,
}

/// Phase reported by the orchestrator to B and A during the two-phase
/// handoff (design §11.1, §12.2 UI mapping).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HandoffPhase {
    Prepare,
    PrepareRelinquish,
    Relinquish,
    Commit,
    Committed,
    Failed,
}

/// Handoff transaction state stored by the server (design §11.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoffState {
    pub transaction_id: Uuid,
    pub source_device_id: DeviceId,
    pub source_session_id: SessionId,
    pub source_generation: SessionGeneration,
    pub source_snapshot_revision: SnapshotRevision,
    pub target_device_id: DeviceId,
    pub phase: HandoffPhase,
    /// Server-side deadline for B's `target_ready` and A's relinquish ack.
    pub deadline: i64,
    pub error_code: Option<super::errors::ErrorCode>,
}

/// Realtime envelope (design §9.1).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub version: u32,
    pub message_id: MessageId,
    pub connection_id: Option<ConnectionId>,
    pub source_device_id: Option<DeviceId>,
    pub target_device_id: Option<DeviceId>,
    pub session_id: Option<SessionId>,
    pub expected_generation: Option<SessionGeneration>,
    pub seq: Option<ConnectionSeq>,
    pub server_time: Option<i64>,
    #[serde(flatten)]
    pub payload: Payload,
}

/// Realtime payload (design §9.1, §9.2, §10, §11).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Payload {
    /// Initial handshake. Client → server.
    Hello {
        protocol_version: u32,
        capabilities: CapabilitySet,
        device_id: Option<DeviceId>,
        ticket: String,
        last_seq: Option<ConnectionSeq>,
    },
    /// Server → client handshake response.
    Welcome {
        server_protocol_version: u32,
        negotiated: CapabilitySet,
        connection_id: ConnectionId,
        device_id: DeviceId,
        server_time: i64,
    },
    /// Client → server heartbeat.
    Heartbeat,
    /// Server → client heartbeat ack.
    HeartbeatAck { server_time: i64 },
    /// Full snapshot published by a device.
    Snapshot {
        session_id: SessionId,
        generation: SessionGeneration,
        snapshot_revision: SnapshotRevision,
        snapshot: PlaybackSnapshot,
    },
    /// Server-side projection of a device snapshot, delivered to observers.
    SnapshotProjection {
        device_id: DeviceId,
        session_id: SessionId,
        generation: SessionGeneration,
        snapshot_revision: SnapshotRevision,
        snapshot: PlaybackSnapshot,
        is_online: bool,
        last_confirmed_at: i64,
    },
    /// B → server → A command (design §10).
    Command {
        target_device_id: DeviceId,
        expected_generation: SessionGeneration,
        command: RemoteCommand,
    },
    /// Ack returned for a previously-sent command.
    CommandAck {
        message_id: MessageId,
        result: CommandResult,
    },
    /// B requests handoff candidate snapshot (design §11.1 step 1).
    HandoffCandidateRequest {
        source_device_id: DeviceId,
        expected_generation: SessionGeneration,
        expected_snapshot_revision: SnapshotRevision,
    },
    /// Server → B: candidate snapshot is valid, B may preload.
    HandoffCandidate {
        transaction_id: Uuid,
        snapshot: PlaybackSnapshot,
        generation: SessionGeneration,
        snapshot_revision: SnapshotRevision,
        deadline: i64,
    },
    /// B → server: B has preloaded and is ready (design §11.1 step 3).
    TargetReady {
        transaction_id: Uuid,
        generation: SessionGeneration,
        snapshot_revision: SnapshotRevision,
    },
    /// Server → A: pause and relinquish (design §11.1 step 4).
    PrepareRelinquish {
        transaction_id: Uuid,
        expected_snapshot_revision: SnapshotRevision,
        deadline: i64,
    },
    /// A → server: relinquish barrier committed with final precise snapshot.
    RelinquishAck {
        transaction_id: Uuid,
        snapshot: PlaybackSnapshot,
    },
    /// Server → B: handoff committed; apply snapshot and begin playback.
    HandoffCommitted {
        transaction_id: Uuid,
        new_generation: SessionGeneration,
        snapshot: PlaybackSnapshot,
    },
    /// Server → both: handoff failed.
    HandoffFailed {
        transaction_id: Uuid,
        code: super::errors::ErrorCode,
    },
    /// Server → client: protocol-level error.
    Error {
        code: super::errors::ErrorCode,
        reason: String,
    },
    /// Server → client: requested feature disabled by negotiated capabilities.
    CapabilityDisabled { feature: String },
}

/// Result returned by command execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum CommandResult {
    Ok,
    Error {
        code: super::errors::ErrorCode,
        reason: String,
    },
}

/// Handshake response returned by the server on `Hello`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelloResponse {
    pub server_protocol_version: u32,
    pub negotiated: CapabilitySet,
    pub connection_id: ConnectionId,
    pub device_id: DeviceId,
    pub server_time: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::ErrorCode;

    fn sample_snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot {
            session_id: Uuid::new_v4(),
            logical_playback_session_id: Uuid::new_v4(),
            media_kind: MediaKind::Song,
            song_id: "song-1".into(),
            progress_seconds: 10.0,
            duration_seconds: 180.0,
            is_playing: true,
            sampled_at: 1_700_000_000,
            context_queue: vec!["song-1".into()],
            context_index: Some(0),
            source_id: Some("album-1".into()),
            source_name: Some("album".into()),
            user_queue: vec![],
            in_user_queue: false,
            restore_previous: vec![],
            shuffle: false,
            repeat: "off".into(),
            volume: Some(0.5),
            accumulated_play_seconds: 12.0,
            history_written: false,
            now_playing_sent: true,
            scrobble_sent: false,
        }
    }

    #[test]
    fn snapshot_validates_within_limits() {
        let s = sample_snapshot();
        s.validate(2000, 512 * 1024).unwrap();
    }

    #[test]
    fn snapshot_rejects_too_many_songs() {
        let mut s = sample_snapshot();
        s.context_queue = (0..2100).map(|i| format!("s{i}")).collect();
        let err = s.validate(2000, 512 * 1024).unwrap_err();
        assert_eq!(err.code, ErrorCode::PayloadTooLarge);
    }

    #[test]
    fn snapshot_rejects_bad_repeat() {
        let mut s = sample_snapshot();
        s.repeat = "weird".into();
        let err = s.validate(2000, 512 * 1024).unwrap_err();
        assert_eq!(err.code, ErrorCode::BadMessage);
    }

    #[test]
    fn envelope_roundtrip() {
        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(Uuid::new_v4()),
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: Some(1_700_000_000),
            payload: Payload::Heartbeat,
        };
        let json = serde_json::to_string(&env).unwrap();
        let back: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, PROTOCOL_VERSION);
        assert!(matches!(back.payload, Payload::Heartbeat));
    }

    #[test]
    fn capability_negotiation_intersects() {
        let server = CapabilitySet::HISTORY
            .union(CapabilitySet::OBSERVE)
            .union(CapabilitySet::CONTROL)
            .union(CapabilitySet::HANDOFF);
        let client = CapabilitySet::OBSERVE.union(CapabilitySet::CONTROL);
        let nego = server.intersect(client);
        assert!(nego.has(CapabilitySet::OBSERVE));
        assert!(nego.has(CapabilitySet::CONTROL));
        assert!(!nego.has(CapabilitySet::HANDOFF));
    }
}
