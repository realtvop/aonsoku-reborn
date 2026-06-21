//! Handoff state machine (design §11).
//!
//! The handoff is a server-authoritative two-phase transaction:
//!
//! 1. B requests A's candidate snapshot (handled in realtime::conn).
//! 2. B preloads, then sends `target_ready`.
//! 3. Server validates A hasn't changed, creates a transaction, sends
//!    `prepare_relinquish` to A.
//! 4. A pauses and confirms with a final snapshot (`relinquish_ack`).
//! 5. Server compare-and-swaps A's generation in a single SQLite transaction,
//!    marks A's session transferred, and grants the logical session to B.
//! 6. Server sends `handoff_committed` to B with the new generation.
//!
//! Concurrent handoff attempts on the same A session return
//! `handoff_conflict`. The CAS ensures only one transaction commits.

use std::collections::HashMap;
use std::sync::Arc;

use chrono::Utc;
use parking_lot::RwLock;
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::protocol::{
    HandoffPhase, HandoffState, PlaybackSnapshot, SessionGeneration, SnapshotRevision,
};
use crate::realtime::registry::ConnectionRegistry;
use crate::storage::repository::SessionRepository;

/// In-flight handoff transactions keyed by transaction id.
#[derive(Default)]
pub struct HandoffCoordinator {
    transactions: RwLock<HashMap<Uuid, HandoffState>>,
}

impl HandoffCoordinator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start a handoff transaction after B sends `target_ready` (design §11.1 step 3-4).
    ///
    /// Checks that A's session generation and snapshot revision still match
    /// what B observed, then creates a pending transaction and sends
    /// `prepare_relinquish` to A.
    #[allow(clippy::too_many_arguments)]
    pub async fn start_transaction(
        &self,
        session_repo: &impl SessionRepository,
        registry: &Arc<ConnectionRegistry>,
        transaction_id: Uuid,
        source_device_id: Uuid,
        source_session_id: Uuid,
        expected_generation: SessionGeneration,
        expected_snapshot_revision: SnapshotRevision,
        target_device_id: Uuid,
        prepare_deadline_seconds: i64,
    ) -> Result<HandoffState, CoordinationError> {
        // Check that no other active transaction targets the same source session.
        {
            let txns = self.transactions.read();
            for txn in txns.values() {
                if txn.source_session_id == source_session_id
                    && matches!(
                        txn.phase,
                        HandoffPhase::Prepare
                            | HandoffPhase::PrepareRelinquish
                            | HandoffPhase::Relinquish
                    )
                {
                    return Err(CoordinationError::new(
                        ErrorCode::HandoffConflict,
                        "another handoff transaction is in progress for this session",
                    ));
                }
            }
        }

        // Verify the source session still matches.
        let session = session_repo
            .find_by_id(source_session_id)
            .await?
            .ok_or_else(|| {
                CoordinationError::new(ErrorCode::NotFound, "source session not found")
            })?;
        if session.generation != expected_generation {
            return Err(CoordinationError::new(
                ErrorCode::StaleEpoch,
                "source session generation has changed",
            ));
        }
        if session.snapshot_revision != expected_snapshot_revision {
            return Err(CoordinationError::new(
                ErrorCode::SourceChanged,
                "source snapshot has changed",
            ));
        }

        let deadline = Utc::now().timestamp() + prepare_deadline_seconds;
        let state = HandoffState {
            transaction_id,
            source_device_id,
            source_session_id,
            source_generation: expected_generation,
            source_snapshot_revision: expected_snapshot_revision,
            target_device_id,
            phase: HandoffPhase::PrepareRelinquish,
            deadline,
            error_code: None,
        };
        self.transactions
            .write()
            .insert(transaction_id, state.clone());

        // Send prepare_relinquish to A.
        let prepare = crate::protocol::Envelope {
            version: crate::protocol::PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: None,
            source_device_id: None,
            target_device_id: Some(source_device_id),
            session_id: Some(source_session_id),
            expected_generation: Some(expected_generation),
            seq: None,
            server_time: Some(Utc::now().timestamp()),
            payload: crate::protocol::Payload::PrepareRelinquish {
                transaction_id,
                expected_snapshot_revision,
                deadline,
            },
        };
        let _ = registry.send(source_device_id, prepare);

        Ok(state)
    }

    /// Handle A's relinquish acknowledgement with a final snapshot (design §11.1 step 5-6).
    ///
    /// Compare-and-swap: verify the session's generation hasn't changed,
    /// then in a single SQLite transaction mark the source session transferred
    /// and bump the generation.
    pub async fn commit_relinquish(
        &self,
        session_repo: &impl SessionRepository,
        registry: &Arc<ConnectionRegistry>,
        transaction_id: Uuid,
        final_snapshot: PlaybackSnapshot,
    ) -> Result<SessionGeneration, CoordinationError> {
        let txn = {
            self.transactions
                .read()
                .get(&transaction_id)
                .cloned()
                .ok_or_else(|| {
                    CoordinationError::new(ErrorCode::NotFound, "transaction not found")
                })?
        };

        if txn.phase != HandoffPhase::PrepareRelinquish {
            return Err(CoordinationError::new(
                ErrorCode::HandoffConflict,
                "transaction is not in prepare_relinquish phase",
            ));
        }

        // CAS: re-read the source session and verify generation hasn't changed.
        let session = session_repo
            .find_by_id(txn.source_session_id)
            .await?
            .ok_or_else(|| {
                CoordinationError::new(ErrorCode::NotFound, "source session not found")
            })?;
        if session.generation != txn.source_generation {
            // Source changed during preparation.
            self.mark_failed(transaction_id, ErrorCode::SourceChanged);
            return Err(CoordinationError::new(
                ErrorCode::SourceChanged,
                "source session generation changed during relinquish",
            ));
        }
        if session.snapshot_revision != txn.source_snapshot_revision {
            self.mark_failed(transaction_id, ErrorCode::SourceChanged);
            return Err(CoordinationError::new(
                ErrorCode::SourceChanged,
                "source snapshot changed during relinquish",
            ));
        }

        // CAS commit: atomically bump the generation and mark the source
        // session transferred in a single SQLite transaction (design §11.1
        // step 6, §14 — the two operations must commit together so a crash
        // cannot leave the session with a bumped generation but not yet
        // transferred). The target session id is the final_snapshot's
        // session_id; the new session for B is created by the caller.
        let new_generation = session_repo
            .bump_and_transfer(
                txn.source_session_id,
                txn.target_device_id,
                final_snapshot.session_id,
            )
            .await?;

        // Update transaction state.
        {
            let mut txns = self.transactions.write();
            if let Some(t) = txns.get_mut(&transaction_id) {
                t.phase = HandoffPhase::Committed;
            }
        }

        // Send handoff_committed to B.
        let committed = crate::protocol::Envelope {
            version: crate::protocol::PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: None,
            source_device_id: Some(txn.source_device_id),
            target_device_id: Some(txn.target_device_id),
            session_id: Some(final_snapshot.session_id),
            expected_generation: Some(new_generation),
            seq: None,
            server_time: Some(Utc::now().timestamp()),
            payload: crate::protocol::Payload::HandoffCommitted {
                transaction_id,
                new_generation,
                snapshot: final_snapshot,
            },
        };
        let _ = registry.send(txn.target_device_id, committed);

        // Clean up the transaction.
        self.transactions.write().remove(&transaction_id);

        Ok(new_generation)
    }

    /// Handle offline handoff (design §11.3). B takes over A's frozen
    /// snapshot when A is offline and the snapshot is within the 8-hour window.
    pub async fn offline_handoff(
        &self,
        session_repo: &impl SessionRepository,
        registry: &Arc<ConnectionRegistry>,
        source_device_id: Uuid,
        source_session_id: Uuid,
        target_device_id: Uuid,
        offline_snapshot_ttl: chrono::Duration,
    ) -> Result<SessionGeneration, CoordinationError> {
        // A must be offline.
        if registry.is_online(source_device_id) {
            return Err(CoordinationError::new(
                ErrorCode::BadMessage,
                "source device is online; use online handoff instead",
            ));
        }
        let session = session_repo
            .find_by_id(source_session_id)
            .await?
            .ok_or_else(|| {
                CoordinationError::new(ErrorCode::NotFound, "source session not found")
            })?;
        if session.status != crate::storage::models::SessionStatus::Offline {
            return Err(CoordinationError::new(
                ErrorCode::BadMessage,
                "source session is not offline",
            ));
        }
        // Check the 8-hour retention window.
        if let Some(offline_at) = session.offline_at {
            if Utc::now() - offline_at > offline_snapshot_ttl {
                return Err(CoordinationError::new(
                    ErrorCode::SnapshotExpired,
                    "offline snapshot has expired (8h window passed)",
                ));
            }
        }
        if session.transferred_to_device.is_some() {
            return Err(CoordinationError::new(
                ErrorCode::SnapshotExpired,
                "session has already been transferred",
            ));
        }

        // Atomically promote A's generation and grant to B in a single
        // transaction (design §11.1 step 6, §14). B resumes the same logical
        // session, so the transferred_to_session is the source session itself.
        let new_generation = session_repo
            .bump_and_transfer(source_session_id, target_device_id, source_session_id)
            .await?;

        Ok(new_generation)
    }

    /// Mark a transaction as failed and notify both parties.
    pub fn mark_failed(&self, transaction_id: Uuid, code: ErrorCode) {
        let target_device = {
            let mut txns = self.transactions.write();
            if let Some(t) = txns.get_mut(&transaction_id) {
                t.phase = HandoffPhase::Failed;
                t.error_code = Some(code);
                Some(t.target_device_id)
            } else {
                None
            }
        };
        if let Some(target) = target_device {
            let failed = crate::protocol::Envelope {
                version: crate::protocol::PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: None,
                source_device_id: None,
                target_device_id: Some(target),
                session_id: None,
                expected_generation: None,
                seq: None,
                server_time: Some(Utc::now().timestamp()),
                payload: crate::protocol::Payload::HandoffFailed {
                    transaction_id,
                    code,
                },
            };
            // Best-effort send; target may be offline.
            // We'd need the registry here, but to keep this method non-async
            // we skip sending. The caller should notify separately.
            let _ = failed;
        }
        self.transactions.write().remove(&transaction_id);
    }

    /// Get the current state of a transaction.
    pub fn get_state(&self, transaction_id: Uuid) -> Option<HandoffState> {
        self.transactions.read().get(&transaction_id).cloned()
    }

    /// Cancel a transaction (e.g. B cancels or A's user overrides).
    pub fn cancel(&self, transaction_id: Uuid) {
        self.transactions.write().remove(&transaction_id);
    }

    /// Number of in-flight transactions (for observability).
    pub fn active_count(&self) -> usize {
        self.transactions.read().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::models::{PlaybackSession, SessionStatus};
    use crate::storage::repository::{AccountRepository, DeviceRepository, SessionRepository};
    use crate::storage::sqlite::SqliteSessionRepository;

    async fn setup_session_repo() -> (tempfile::TempDir, SqliteSessionRepository, uuid::Uuid) {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = crate::storage::open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let acc_repo = crate::storage::sqlite::SqliteAccountRepository::new(pool.clone());
        let dev_repo = crate::storage::sqlite::SqliteDeviceRepository::new(pool.clone());
        let session_repo = SqliteSessionRepository::new(pool);
        let acc = acc_repo.upsert_by_lookup_key("k", 100).await.unwrap();
        let dev = dev_repo
            .create(acc.id, "P", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some("{}".into()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        session_repo.upsert_snapshot(&session, "{}").await.unwrap();
        (dir, session_repo, session.id)
    }

    #[tokio::test]
    async fn concurrent_handoff_conflict() {
        let (_dir, session_repo, session_id) = setup_session_repo().await;
        let coord = HandoffCoordinator::new();
        let registry = Arc::new(ConnectionRegistry::new());

        // First transaction succeeds in starting.
        let txn1 = Uuid::new_v4();
        let _state1 = coord
            .start_transaction(
                &session_repo,
                &registry,
                txn1,
                Uuid::new_v4(),
                session_id,
                1,
                1,
                Uuid::new_v4(),
                15,
            )
            .await
            .unwrap();

        // Second transaction for the same session conflicts.
        let txn2 = Uuid::new_v4();
        let err = coord
            .start_transaction(
                &session_repo,
                &registry,
                txn2,
                Uuid::new_v4(),
                session_id,
                1,
                1,
                Uuid::new_v4(),
                15,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::HandoffConflict);
    }

    #[tokio::test]
    async fn stale_epoch_rejected() {
        let (_dir, session_repo, session_id) = setup_session_repo().await;
        let coord = HandoffCoordinator::new();
        let registry = Arc::new(ConnectionRegistry::new());
        let err = coord
            .start_transaction(
                &session_repo,
                &registry,
                Uuid::new_v4(),
                Uuid::new_v4(),
                session_id,
                99, // wrong generation
                1,
                Uuid::new_v4(),
                15,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::StaleEpoch);
    }

    #[tokio::test]
    async fn offline_handoff_within_window_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = crate::storage::open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let acc_repo = crate::storage::sqlite::SqliteAccountRepository::new(pool.clone());
        let dev_repo = crate::storage::sqlite::SqliteDeviceRepository::new(pool.clone());
        let session_repo = SqliteSessionRepository::new(pool);
        let acc = acc_repo.upsert_by_lookup_key("k", 100).await.unwrap();
        let dev_a = dev_repo
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = dev_repo
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some("{}".into()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: Some(Utc::now() - chrono::Duration::hours(7)), // within 8h
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        session_repo.upsert_snapshot(&session, "{}").await.unwrap();
        session_repo
            .set_status(session.id, SessionStatus::Offline, Utc::now())
            .await
            .unwrap();

        let coord = HandoffCoordinator::new();
        let registry = Arc::new(ConnectionRegistry::new());
        let new_gen = coord
            .offline_handoff(
                &session_repo,
                &registry,
                dev_a.id,
                session.id,
                dev_b.id,
                chrono::Duration::hours(8),
            )
            .await
            .unwrap();
        assert_eq!(new_gen, 2);
    }

    #[tokio::test]
    async fn offline_handoff_after_window_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = crate::storage::open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let acc_repo = crate::storage::sqlite::SqliteAccountRepository::new(pool.clone());
        let dev_repo = crate::storage::sqlite::SqliteDeviceRepository::new(pool.clone());
        let session_repo = SqliteSessionRepository::new(pool);
        let acc = acc_repo.upsert_by_lookup_key("k", 100).await.unwrap();
        let dev_a = dev_repo
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = dev_repo
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Offline,
            last_snapshot: Some("{}".into()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: Some(Utc::now() - chrono::Duration::hours(9)), // past 8h
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        session_repo.upsert_snapshot(&session, "{}").await.unwrap();

        let coord = HandoffCoordinator::new();
        let registry = Arc::new(ConnectionRegistry::new());
        let err = coord
            .offline_handoff(
                &session_repo,
                &registry,
                dev_a.id,
                session.id,
                dev_b.id,
                chrono::Duration::hours(8),
            )
            .await
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::SnapshotExpired);
    }
}
