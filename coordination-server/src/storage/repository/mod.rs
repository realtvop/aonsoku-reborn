//! Repository trait family. Business modules depend on these traits, not on
//! SQL. SQLite implementations live alongside in `repository/` submodules.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use super::models::{
    Account, Device, DevicePresence, HistoryEntry, HistoryOperation, HistoryTombstone,
    PlaybackSession, SessionStatus,
};
use crate::errors::CoordinationError;

#[async_trait]
pub trait AccountRepository: Send + Sync + 'static {
    async fn upsert_by_lookup_key(
        &self,
        lookup_key: &str,
        history_limit: u32,
    ) -> Result<Account, CoordinationError>;
    async fn find_by_id(&self, id: Uuid) -> Result<Option<Account>, CoordinationError>;
    async fn find_by_lookup_key(&self, key: &str) -> Result<Option<Account>, CoordinationError>;
    async fn set_history_limit(&self, id: Uuid, limit: u32) -> Result<Account, CoordinationError>;
    async fn delete_account(&self, id: Uuid) -> Result<(), CoordinationError>;
}

#[async_trait]
pub trait DeviceRepository: Send + Sync + 'static {
    #[allow(clippy::too_many_arguments)]
    async fn create(
        &self,
        account_id: Uuid,
        name: &str,
        platform: &str,
        client_version: Option<&str>,
        capabilities: u32,
        refresh_token_hash: &str,
        refresh_token_family: Uuid,
    ) -> Result<Device, CoordinationError>;
    async fn find_by_id(&self, id: Uuid) -> Result<Option<Device>, CoordinationError>;
    async fn list_for_account(&self, account_id: Uuid) -> Result<Vec<Device>, CoordinationError>;
    async fn rename(&self, id: Uuid, name: &str) -> Result<Device, CoordinationError>;
    async fn revoke(&self, id: Uuid) -> Result<Device, CoordinationError>;
    async fn mark_online(&self, id: Uuid, at: DateTime<Utc>) -> Result<(), CoordinationError>;
    async fn mark_legacy_imported(&self, id: Uuid) -> Result<(), CoordinationError>;
    async fn rotate_refresh_token(
        &self,
        id: Uuid,
        new_hash: &str,
        new_family: Uuid,
        used_at: DateTime<Utc>,
    ) -> Result<(), CoordinationError>;
}

#[async_trait]
pub trait SessionRepository: Send + Sync + 'static {
    async fn upsert_snapshot(
        &self,
        session: &PlaybackSession,
        snapshot_json: &str,
    ) -> Result<PlaybackSession, CoordinationError>;
    async fn find_by_id(&self, id: Uuid) -> Result<Option<PlaybackSession>, CoordinationError>;
    async fn find_active_for_device(
        &self,
        device_id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError>;
    async fn list_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<PlaybackSession>, CoordinationError>;
    async fn set_status(
        &self,
        id: Uuid,
        status: SessionStatus,
        at: DateTime<Utc>,
    ) -> Result<(), CoordinationError>;
    async fn transfer(
        &self,
        id: Uuid,
        new_generation: i64,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<(), CoordinationError>;
    async fn bump_generation(&self, id: Uuid) -> Result<i64, CoordinationError>;
    /// Atomically bump a session's generation and mark it transferred in a
    /// single transaction (design §11.1 step 6, §14). Returns the new
    /// generation. Equivalent to calling `bump_generation` then `transfer`
    /// but guaranteed atomic — a crash between the two cannot leave the
    /// session with a bumped generation but not yet transferred.
    async fn bump_and_transfer(
        &self,
        id: Uuid,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<i64, CoordinationError>;
    /// Delete sessions in the `transferred` status whose `updated_at` is
    /// older than `cutoff`. Returns the number of rows removed. Used by the
    /// GC task to bound database growth (design §11.3).
    async fn delete_transferred_before(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, CoordinationError>;
    /// Hard-delete every `Offline`-status playback_sessions row owned by
    /// `device_id` except the one with the given `keep_session_id` (when
    /// `Some`). Returns the number of rows removed. Called when a device
    /// publishes a fresh snapshot: any older frozen offline candidates from
    /// the same device are no longer the "last activity" and must not remain
    /// replayable for offline handoff (design §11.3, §9.2 overwrite
    /// semantics — offline relay keeps only the last activity per device).
    async fn delete_offline_for_device(
        &self,
        device_id: Uuid,
        keep_session_id: Option<Uuid>,
    ) -> Result<u64, CoordinationError>;
}

#[async_trait]
pub trait HistoryRepository: Send + Sync + 'static {
    async fn append(
        &self,
        op: &HistoryOperation,
        entry: &HistoryEntry,
    ) -> Result<i64, CoordinationError>;
    async fn delete_one(
        &self,
        op: &HistoryOperation,
        event_id: Uuid,
    ) -> Result<(), CoordinationError>;
    async fn clear(&self, op: &HistoryOperation) -> Result<(), CoordinationError>;
    async fn list_after(
        &self,
        account_id: Uuid,
        after_revision: i64,
        limit: u32,
    ) -> Result<Vec<HistoryEntry>, CoordinationError>;
    async fn list_tombstones_after(
        &self,
        account_id: Uuid,
        after_revision: i64,
        limit: u32,
    ) -> Result<Vec<HistoryTombstone>, CoordinationError>;
    async fn prune_to_limit(&self, account_id: Uuid, limit: u32) -> Result<u64, CoordinationError>;
    async fn prune_tombstones(&self, older_than: DateTime<Utc>) -> Result<u64, CoordinationError>;
    async fn operation_seen(&self, operation_id: Uuid) -> Result<bool, CoordinationError>;
}

#[async_trait]
pub trait PresenceRepository: Send + Sync + 'static {
    async fn upsert(&self, presence: &DevicePresence) -> Result<(), CoordinationError>;
    async fn find(&self, device_id: Uuid) -> Result<Option<DevicePresence>, CoordinationError>;
    async fn list_online_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<DevicePresence>, CoordinationError>;
}

/// Values bound to a one-time registration challenge, returned when the
/// challenge is consumed so the caller can verify the register request
/// matches the challenge that was issued (design §6.2).
#[derive(Debug, Clone)]
pub struct ConsumedChallenge {
    pub normalised_identity: String,
    pub normalised_username: String,
}

#[async_trait]
pub trait ChallengeRepository: Send + Sync + 'static {
    async fn issue(
        &self,
        normalised_identity: &str,
        username: &str,
        ttl: chrono::Duration,
    ) -> Result<Uuid, CoordinationError>;
    async fn consume(&self, id: Uuid) -> Result<ConsumedChallenge, CoordinationError>;
}

#[async_trait]
pub trait TicketRepository: Send + Sync + 'static {
    async fn issue(
        &self,
        device_id: Uuid,
        ttl: chrono::Duration,
    ) -> Result<String, CoordinationError>;
    async fn consume(&self, ticket: &str) -> Result<Option<Uuid>, CoordinationError>;
}

/// Convenience marker for the full repository set.
pub trait FullRepository:
    AccountRepository
    + DeviceRepository
    + SessionRepository
    + HistoryRepository
    + PresenceRepository
    + ChallengeRepository
    + TicketRepository
{
}

impl<T> FullRepository for T where
    T: AccountRepository
        + DeviceRepository
        + SessionRepository
        + HistoryRepository
        + PresenceRepository
        + ChallengeRepository
        + TicketRepository
{
}
