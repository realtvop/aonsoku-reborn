// Coordination protocol types — shared between client and server.
// Mirrors the Rust protocol schema in coordination-server/src/protocol.rs.
// Versioned: all messages carry an explicit protocol version (design §9.1).

export const COORDINATION_PROTOCOL_VERSION = 1;

// Capability flags (design §9.1).
export const CoordinationCapability = {
  NONE: 0,
  HISTORY: 1 << 0,
  OBSERVE: 1 << 1,
  CONTROL: 1 << 2,
  HANDOFF: 1 << 3,
} as const;

export type CoordinationCapabilities = number;

// Stable identifiers.
export type DeviceId = string;
export type AccountId = string;
export type SessionId = string;
export type LogicalPlaybackSessionId = string;
export type HistoryEventId = string;
export type HistoryOperationId = string;
export type MessageId = string;
export type ConnectionId = string;

export type Revision = number;
export type SessionGeneration = number;
export type SnapshotRevision = number;
export type ConnectionSeq = number;

// Media kinds — first version only supports songs (design §18).
export type MediaKind = "song";

// Playback snapshot (design §7.3).
export interface PlaybackSnapshot {
  sessionId: SessionId;
  logicalPlaybackSessionId: LogicalPlaybackSessionId;
  mediaKind: MediaKind;
  songId: string;
  progressSeconds: number;
  durationSeconds: number;
  isPlaying: boolean;
  sampledAt: number;
  contextQueue: string[];
  contextIndex: number | null;
  sourceId: string | null;
  sourceName: string | null;
  userQueue: string[];
  inUserQueue: boolean;
  restorePrevious: string[];
  shuffle: boolean;
  repeat: "off" | "one" | "all";
  volume: number | null;
  accumulatedPlaySeconds: number;
  historyWritten: boolean;
  nowPlayingSent: boolean;
  scrobbleSent: boolean;
}

// Remote control commands (design §10).
export type RemoteCommand =
  | { type: "play" }
  | { type: "pause" }
  | { type: "toggle_play_pause" }
  | { type: "previous" }
  | { type: "next" }
  | { type: "seek"; seconds: number }
  | { type: "set_volume"; volume: number }
  | { type: "set_shuffle"; enabled: boolean }
  | { type: "set_repeat"; mode: string }
  | { type: "toggle_like" }
  | { type: "play_song"; songId: string }
  | { type: "play_album"; albumId: string; index?: number }
  | { type: "play_playlist"; playlistId: string; index?: number }
  | { type: "add_to_queue_next"; songIds: string[] }
  | { type: "add_to_queue_last"; songIds: string[] }
  | { type: "remove_from_queue"; songIds: string[] }
  | { type: "reorder_queue"; from: number; to: number }
  | { type: "clear_queue" };

// Handoff phases (design §11.1, §12.2).
export type HandoffPhase =
  | "prepare"
  | "prepare_relinquish"
  | "relinquish"
  | "commit"
  | "committed"
  | "failed";

// Error codes (design §13) — must match the Rust ErrorCode enum.
export type CoordinationErrorCode =
  | "authentication_failed"
  | "device_revoked"
  | "target_offline"
  | "unsupported_media"
  | "snapshot_expired"
  | "stale_epoch"
  | "handoff_conflict"
  | "source_changed"
  | "source_pause_timeout"
  | "payload_too_large"
  | "protocol_incompatible"
  | "rate_limited"
  | "bad_message"
  | "not_found"
  | "forbidden"
  | "internal"
  | "challenge_expired"
  | "ticket_expired"
  | "invalid_identity"
  | "ssrf_blocked"
  | "verification_failed"
  | "not_ready";

export interface CoordinationError {
  code: CoordinationErrorCode;
  reason: string;
}

// Realtime envelope (design §9.1). The envelope carries routing metadata and
// a type discriminator matching the payload union.
export interface EnvelopeBase {
  version: number;
  messageId: MessageId;
  connectionId?: ConnectionId | null;
  sourceDeviceId?: DeviceId | null;
  targetDeviceId?: DeviceId | null;
  sessionId?: SessionId | null;
  expectedGeneration?: SessionGeneration | null;
  seq?: ConnectionSeq | null;
  serverTime?: number | null;
}

export type Envelope = EnvelopeBase & Payload;

// Payload types — tagged union (design §9.1, §9.2, §10, §11).
export type Payload =
  | {
      type: "hello";
      protocolVersion: number;
      capabilities: CoordinationCapabilities;
      deviceId?: DeviceId | null;
      ticket: string;
      lastSeq?: ConnectionSeq | null;
    }
  | {
      type: "welcome";
      serverProtocolVersion: number;
      negotiated: CoordinationCapabilities;
      connectionId: ConnectionId;
      deviceId: DeviceId;
      serverTime: number;
    }
  | { type: "heartbeat" }
  | { type: "heartbeat_ack"; serverTime: number }
  | { type: "devices_changed"; devices: DeviceDto[] }
  | {
      type: "snapshot";
      sessionId: SessionId;
      generation: SessionGeneration;
      snapshotRevision: SnapshotRevision;
      snapshot: PlaybackSnapshot;
    }
  | {
      type: "snapshot_projection";
      deviceId: DeviceId;
      sessionId: SessionId;
      generation: SessionGeneration;
      snapshotRevision: SnapshotRevision;
      snapshot: PlaybackSnapshot;
      isOnline: boolean;
      lastConfirmedAt: number;
    }
  | {
      type: "command";
      targetDeviceId: DeviceId;
      expectedGeneration: SessionGeneration;
      command: RemoteCommand;
    }
  | { type: "command_ack"; messageId: MessageId; result: CommandResult }
  | {
      type: "handoff_candidate_request";
      sourceDeviceId: DeviceId;
      expectedGeneration: SessionGeneration;
      expectedSnapshotRevision: SnapshotRevision;
    }
  | {
      type: "handoff_candidate";
      transactionId: string;
      snapshot: PlaybackSnapshot;
      generation: SessionGeneration;
      snapshotRevision: SnapshotRevision;
      deadline: number;
    }
  | {
      type: "target_ready";
      transactionId: string;
      generation: SessionGeneration;
      snapshotRevision: SnapshotRevision;
    }
  | {
      type: "prepare_relinquish";
      transactionId: string;
      expectedSnapshotRevision: SnapshotRevision;
      deadline: number;
    }
  | {
      type: "relinquish_ack";
      transactionId: string;
      snapshot: PlaybackSnapshot;
    }
  | {
      type: "handoff_committed";
      transactionId: string;
      newGeneration: SessionGeneration;
      snapshot: PlaybackSnapshot;
    }
  | {
      type: "handoff_failed";
      transactionId: string;
      code: CoordinationErrorCode;
    }
  | { type: "error"; code: CoordinationErrorCode; reason: string }
  | { type: "capability_disabled"; feature: string };

export type CommandResult =
  | { status: "ok" }
  | { status: "error"; code: CoordinationErrorCode; reason: string };

// HTTP API request/response types (design §6, §8).
export interface ChallengeRequest {
  identityUrl: string;
  username: string;
}
export interface ChallengeResponse {
  challengeId: string;
}

export interface RegisterRequest {
  challengeId: string;
  identityUrl: string;
  username: string;
  authMode: "token" | "password";
  token?: string;
  salt?: string;
  password?: string;
  deviceName: string;
  platform: string;
  clientVersion?: string;
  capabilities?: number;
}
export interface RegisterResponse {
  deviceId: DeviceId;
  accountId: AccountId;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  historyLimit: number;
}

export interface TokenRefreshRequest {
  deviceId: DeviceId;
  refreshToken: string;
}
export interface TokenRefreshResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export interface WsTicketResponse {
  ticket: string;
  expiresIn: number;
}

export interface DeviceDto {
  id: DeviceId;
  name: string;
  platform: string;
  clientVersion: string | null;
  capabilities: number;
  createdAt: string;
  lastOnlineAt: string | null;
  revokedAt: string | null;
  historySyncCursor: number;
  legacyHistoryImported: boolean;
}

export interface HistoryEntryDto {
  eventId: HistoryEventId;
  revision: Revision;
  logicalPlaybackSessionId: LogicalPlaybackSessionId;
  songId: string;
  songTitle: string | null;
  songArtist: string | null;
  songAlbum: string | null;
  songDuration: number | null;
  clientEnteredAt: string;
  serverClockOffset: number | null;
  serverReceivedAt: string;
  deleted: boolean;
}

export interface HistoryTombstoneDto {
  eventId: HistoryEventId;
  revision: Revision;
  createdAt: string;
}

export interface HistoryPullResponse {
  entries: HistoryEntryDto[];
  tombstones: HistoryTombstoneDto[];
  historyGeneration: number;
  latestRevision: number;
  historyLimit: number;
}

export interface HistoryOperationInput {
  operationId: HistoryOperationId;
  kind: "add" | "delete_one" | "clear" | "set_limit";
  eventId?: HistoryEventId;
  logicalPlaybackSessionId?: LogicalPlaybackSessionId;
  songId?: string;
  songTitle?: string;
  songArtist?: string;
  songAlbum?: string;
  songDuration?: number;
  clientEnteredAt?: string;
  serverClockOffset?: number;
  historyLimit?: number;
}

export interface HistoryPushResult {
  operationId: HistoryOperationId;
  revision: Revision;
  accepted: boolean;
  error: string | null;
}

export interface HistoryPushResponse {
  results: HistoryPushResult[];
}

export interface LegacyImportRequest {
  entries: {
    songId: string;
    songTitle?: string;
    songArtist?: string;
    songAlbum?: string;
    songDuration?: number;
  }[];
}
export interface LegacyImportResponse {
  mergedSongIds: string[];
  isFirstDevice: boolean;
}
