-- Initial schema for the coordination service (design §7, §14).
-- SQLite is the only supported storage for the first version.
-- Note: PRAGMA journal_mode / foreign_keys / synchronous are set at connection
-- time in `storage/mod.rs`; they cannot be issued inside a migration
-- transaction.

-- Server-level single-row metadata: stable key fingerprint, protocol
-- version, deployment profile. Used to detect mismatched data directories.
CREATE TABLE IF NOT EXISTS server_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Accounts (design §7.1).
CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    lookup_key TEXT NOT NULL UNIQUE,
    history_limit INTEGER NOT NULL DEFAULT 100,
    history_generation INTEGER NOT NULL DEFAULT 1,
    history_revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_accounts_lookup_key ON accounts(lookup_key);

-- Devices (design §7.2).
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    client_version TEXT,
    capabilities INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    last_online_at TEXT,
    revoked_at TEXT,
    history_sync_cursor INTEGER NOT NULL DEFAULT 0,
    legacy_history_imported INTEGER NOT NULL DEFAULT 0,
    refresh_token_hash TEXT NOT NULL,
    refresh_token_family TEXT NOT NULL,
    refresh_token_last_used_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
CREATE INDEX IF NOT EXISTS idx_devices_account_online ON devices(account_id, last_online_at);

-- Playback sessions (design §7.3).
CREATE TABLE IF NOT EXISTS playback_sessions (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    generation INTEGER NOT NULL DEFAULT 1,
    snapshot_revision INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'online',
    last_snapshot TEXT,
    last_snapshot_at TEXT,
    offline_at TEXT,
    transferred_to_device TEXT REFERENCES devices(id),
    transferred_to_session TEXT REFERENCES playback_sessions(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_device ON playback_sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_account ON playback_sessions(account_id);

-- History entries (design §7.4, §8).
CREATE TABLE IF NOT EXISTS history_entries (
    event_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    history_generation INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    logical_playback_session_id TEXT NOT NULL,
    song_id TEXT NOT NULL,
    song_title TEXT,
    song_artist TEXT,
    song_album TEXT,
    song_duration REAL,
    client_entered_at TEXT NOT NULL,
    server_clock_offset INTEGER,
    server_received_at TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_history_account_rev ON history_entries(account_id, history_generation, revision);
CREATE INDEX IF NOT EXISTS idx_history_account_song ON history_entries(account_id, song_id);

-- History operations (idempotency log; design §7.4).
CREATE TABLE IF NOT EXISTS history_operations (
    operation_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    revision INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_history_ops_account ON history_operations(account_id, revision);

-- Tombstones for deleted history entries (design §8.3).
CREATE TABLE IF NOT EXISTS history_tombstones (
    event_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tombstones_account ON history_tombstones(account_id, revision);

-- Device presence / connection recovery (design §9.2, §14).
CREATE TABLE IF NOT EXISTS device_presence (
    device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    account_id TEXT NOT NULL,
    is_online INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT,
    last_seq INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_presence_account ON device_presence(account_id, is_online);

-- One-time registration challenges (design §6.2).
CREATE TABLE IF NOT EXISTS auth_challenges (
    id TEXT PRIMARY KEY,
    normalised_identity TEXT NOT NULL,
    username TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_challenges_expires ON auth_challenges(expires_at);

-- WebSocket tickets (design §6.3).
CREATE TABLE IF NOT EXISTS ws_tickets (
    ticket TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_ws_tickets_device ON ws_tickets(device_id);
CREATE INDEX IF NOT EXISTS idx_ws_tickets_expires ON ws_tickets(expires_at);