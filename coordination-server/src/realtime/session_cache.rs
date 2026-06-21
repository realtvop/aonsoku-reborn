//! In-memory playback session cache with debounced SQLite persistence
//! (design §9.2, §14).
//!
//! [`SessionCache`] fronts [`SessionRepository`] with an in-memory map so that
//! snapshot upserts — the hottest write path (every 5s per playing device plus
//! on every playback state change) — only touch memory. A background ticker
//! flushes dirty sessions to SQLite at a configurable interval (default 30s).
//! Authoritative state transitions (`Offline`, `Transferred`, generation
//! bumps) flush immediately to preserve the offline-handoff 8h window and
//! restart-recovery guarantees (design §11.3, §9.2).
//!
//! Reads (`find_by_id`, `find_active_for_device`, `list_for_account`) are
//! served from memory after the cache is primed (per-account on connect, or
//! lazily on first miss). This collapses the per-snapshot SQLite write to
//! roughly one batched write per `flush_interval`, cutting the write load by
//! ~`flush_interval / 5s` (default ≈ 6x).

use std::collections::HashMap;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use parking_lot::RwLock;
use uuid::Uuid;

use crate::errors::CoordinationError;
use crate::storage::models::{PlaybackSession, SessionStatus};
use crate::storage::repository::SessionRepository;
use async_trait::async_trait;

/// Entry in the in-memory session map. `dirty` is set whenever the in-memory
/// copy has changes not yet persisted to SQLite.
#[derive(Clone)]
struct CachedSession {
    session: PlaybackSession,
    dirty: bool,
}

/// In-memory cache for playback sessions. Wraps a [`SessionRepository`] (the
/// SQLite backing store) and serves reads from memory while debouncing
/// snapshot writes.
pub struct SessionCache {
    inner: Arc<RwLock<HashMap<Uuid, CachedSession>>>,
    backing: Arc<dyn SessionRepository>,
}

impl SessionCache {
    pub fn new(backing: Arc<dyn SessionRepository>) -> Self {
        Self {
            inner: Arc::new(RwLock::new(HashMap::new())),
            backing,
        }
    }

    /// Prime the cache with all sessions for an account. Called when a device
    /// on that account connects so subsequent reads and handoffs are
    /// cache-served. Sessions already present in the cache are left in place
    /// (they may be dirty and more recent than the DB row).
    pub async fn prime_account(
        &self,
        account_id: Uuid,
    ) -> Result<(), CoordinationError> {
        let sessions = self.backing.list_for_account(account_id).await?;
        let mut map = self.inner.write();
        for session in sessions {
            if map.contains_key(&session.id) {
                continue;
            }
            map.insert(
                session.id,
                CachedSession {
                    session,
                    dirty: false,
                },
            );
        }
        Ok(())
    }

    /// Insert or update a session in the cache **without** hitting SQLite.
    /// The snapshot JSON is carried on the `PlaybackSession.last_snapshot`
    /// field; the background ticker persists it. Authoritative state
    /// transitions use [`SessionCache::set_status`] / [`SessionCache::transfer`]
    /// / [`SessionCache::bump_generation`], which write through immediately.
    pub async fn upsert_snapshot(
        &self,
        session: &PlaybackSession,
        snapshot_json: &str,
    ) -> Result<PlaybackSession, CoordinationError> {
        let mut to_store = session.clone();
        to_store.last_snapshot = Some(snapshot_json.to_string());
        to_store.last_snapshot_at = Some(Utc::now());
        to_store.updated_at = Utc::now();
        let mut map = self.inner.write();
        map.insert(
            to_store.id,
            CachedSession {
                session: to_store.clone(),
                dirty: true,
            },
        );
        Ok(to_store)
    }

    /// Read a session by id. Served from the cache; on a miss, falls back to
    /// the backing store and primes the cache (non-dirty).
    pub async fn find_by_id(
        &self,
        id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError> {
        {
            let map = self.inner.read();
            if let Some(entry) = map.get(&id) {
                return Ok(Some(entry.session.clone()));
            }
        }
        let session = self.backing.find_by_id(id).await?;
        if let Some(ref s) = session {
            let mut map = self.inner.write();
            map.entry(s.id).or_insert_with(|| CachedSession {
                session: s.clone(),
                dirty: false,
            });
        }
        Ok(session)
    }

    /// Find the active (non-`Transferred`) session for a device, preferring
    /// the most recently updated. Served from the cache; on a miss falls back
    /// to the backing store.
    pub async fn find_active_for_device(
        &self,
        device_id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError> {
        // Inspect the cache under a short-lived read guard. Any await happens
        // only after the guard is dropped, so the future stays `Send`.
        let cached_best = {
            let map = self.inner.read();
            let mut best: Option<PlaybackSession> = None;
            let mut any_for_device = false;
            for entry in map.values() {
                if entry.session.device_id != device_id {
                    continue;
                }
                any_for_device = true;
                if entry.session.status == SessionStatus::Transferred {
                    continue;
                }
                match &best {
                    Some(b) if b.updated_at >= entry.session.updated_at => {}
                    _ => best = Some(entry.session.clone()),
                }
            }
            (any_for_device, best)
        };
        if cached_best.0 {
            return Ok(cached_best.1);
        }
        // Cold-start: nothing for this device in the cache — fall back to the
        // backing store and prime.
        let session = self.backing.find_active_for_device(device_id).await?;
        if let Some(ref s) = session {
            let mut map = self.inner.write();
            map.entry(s.id).or_insert_with(|| CachedSession {
                session: s.clone(),
                dirty: false,
            });
        }
        Ok(session)
    }

    /// List sessions for an account, ordered by `updated_at` descending.
    /// Served from the cache when the account has been primed; otherwise
    /// falls back to the backing store and primes.
    pub async fn list_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<PlaybackSession>, CoordinationError> {
        // Read the cache under a short-lived guard; the await happens after.
        let cached = {
            let map = self.inner.read();
            let mut sessions: Vec<PlaybackSession> = Vec::new();
            for entry in map.values() {
                if entry.session.account_id == account_id {
                    sessions.push(entry.session.clone());
                }
            }
            sessions
        };
        if !cached.is_empty() {
            let mut sessions = cached;
            sessions.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
            return Ok(sessions);
        }
        // Not primed — load and prime.
        let sessions = self.backing.list_for_account(account_id).await?;
        {
            let mut map = self.inner.write();
            for s in &sessions {
                map.entry(s.id).or_insert_with(|| CachedSession {
                    session: s.clone(),
                    dirty: false,
                });
            }
        }
        Ok(sessions)
    }

    /// Set a session's status. Writes through to the backing store immediately
    /// (status transitions are authoritative and must survive restart), then
    /// updates the cache.
    pub async fn set_status(
        &self,
        id: Uuid,
        status: SessionStatus,
        at: DateTime<Utc>,
    ) -> Result<(), CoordinationError> {
        self.backing.set_status(id, status, at).await?;
        // After the write-through, reload the row from the backing store so the
        // cache holds the authoritative persisted shape (preserves
        // `last_snapshot` etc.).
        let persisted = self.backing.find_by_id(id).await?;
        let mut map = self.inner.write();
        match persisted {
            Some(s) => {
                map.insert(id, CachedSession {
                    session: s,
                    dirty: false,
                });
            }
            None => {
                map.remove(&id);
            }
        }
        Ok(())
    }

    /// Bump a session's generation. Writes through immediately (used by the
    /// handoff CAS commit) and returns the new generation.
    pub async fn bump_generation(
        &self,
        id: Uuid,
    ) -> Result<i64, CoordinationError> {
        let new_generation = self.backing.bump_generation(id).await?;
        let persisted = self.backing.find_by_id(id).await?;
        let mut map = self.inner.write();
        if let Some(s) = persisted {
            map.insert(id, CachedSession {
                session: s,
                dirty: false,
            });
        }
        Ok(new_generation)
    }

    /// Mark a session transferred. Writes through immediately.
    pub async fn transfer(
        &self,
        id: Uuid,
        new_generation: i64,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<(), CoordinationError> {
        self.backing
            .transfer(id, new_generation, transferred_to_device, transferred_to_session)
            .await?;
        let persisted = self.backing.find_by_id(id).await?;
        let mut map = self.inner.write();
        match persisted {
            Some(s) => {
                map.insert(id, CachedSession {
                    session: s,
                    dirty: false,
                });
            }
            None => {
                map.remove(&id);
            }
        }
        Ok(())
    }

    /// Atomically bump a session's generation and mark it transferred in a
    /// single SQLite transaction (design §11.1 step 6, §14). Writes through
    /// immediately and reloads the row into the cache. Returns the new
    /// generation.
    pub async fn bump_and_transfer(
        &self,
        id: Uuid,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<i64, CoordinationError> {
        let new_generation = self
            .backing
            .bump_and_transfer(id, transferred_to_device, transferred_to_session)
            .await?;
        let persisted = self.backing.find_by_id(id).await?;
        let mut map = self.inner.write();
        if let Some(s) = persisted {
            map.insert(id, CachedSession {
                session: s,
                dirty: false,
            });
        }
        Ok(new_generation)
    }

    /// Hard-delete `Transferred` sessions older than `cutoff`. Delegates to
    /// the backing store and removes matching entries from the cache.
    pub async fn delete_transferred_before(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, CoordinationError> {
        let removed = self.backing.delete_transferred_before(cutoff).await?;
        let mut map = self.inner.write();
        map.retain(|_, entry| {
            !(entry.session.status == SessionStatus::Transferred
                && entry.session.updated_at < cutoff)
        });
        Ok(removed)
    }

    /// Hard-delete `Offline` sessions for a device except the one with
    /// `keep_session_id` (if `Some`). Delegates to the backing store and
    /// removes matching entries from the cache.
    pub async fn delete_offline_for_device(
        &self,
        device_id: Uuid,
        keep_session_id: Option<Uuid>,
    ) -> Result<u64, CoordinationError> {
        let removed = self
            .backing
            .delete_offline_for_device(device_id, keep_session_id)
            .await?;
        let mut map = self.inner.write();
        map.retain(|id, entry| {
            !(entry.session.device_id == device_id
                && entry.session.status == SessionStatus::Offline
                && Some(*id) != keep_session_id)
        });
        Ok(removed)
    }

    /// Flush all dirty sessions to the backing store. Called by the background
    /// ticker. Returns the number of sessions flushed.
    pub async fn flush_dirty(&self) -> Result<usize, CoordinationError> {
        // Snapshot the dirty entries under a short-lived write lock, then drop
        // the lock while we do the (async) DB writes.
        let dirty: Vec<PlaybackSession> = {
            let map = self.inner.read();
            map.values()
                .filter(|e| e.dirty)
                .map(|e| e.session.clone())
                .collect()
        };
        let n = dirty.len();
        for session in dirty {
            let snapshot_json = session.last_snapshot.clone().unwrap_or_default();
            // upsert_snapshot on the backing store does an INSERT ... ON
            // CONFLICT UPDATE, which is exactly the semantics we want for a
            // flush.
            if let Err(e) = self.backing.upsert_snapshot(&session, &snapshot_json).await {
                tracing::warn!(
                    target: "coordination::session_cache",
                    error = ?e,
                    session_id = %session.id,
                    "flush_dirty: backing upsert failed; session remains dirty"
                );
                // Leave the entry dirty so the next tick retries it.
                continue;
            }
            // Mark clean.
            let mut map = self.inner.write();
            if let Some(entry) = map.get_mut(&session.id) {
                // Only clear if the in-memory copy hasn't been mutated since we
                // snapshotted it (otherwise a newer in-memory change would be
                // lost from the dirty set). Compare `updated_at` as a proxy.
                if entry.session.updated_at == session.updated_at {
                    entry.dirty = false;
                }
            }
        }
        Ok(n)
    }
}

/// `SessionCache` satisfies the `SessionRepository` trait so it can be passed
/// anywhere the SQLite repo was previously used (e.g. handoff coordinator).
/// The trait methods delegate to the cache-aware methods above; `upsert_snapshot`
/// is debounced (memory-only) while status/mutation methods write through.
#[async_trait]
impl SessionRepository for SessionCache {
    async fn upsert_snapshot(
        &self,
        session: &PlaybackSession,
        snapshot_json: &str,
    ) -> Result<PlaybackSession, CoordinationError> {
        SessionCache::upsert_snapshot(self, session, snapshot_json).await
    }
    async fn find_by_id(
        &self,
        id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError> {
        SessionCache::find_by_id(self, id).await
    }
    async fn find_active_for_device(
        &self,
        device_id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError> {
        SessionCache::find_active_for_device(self, device_id).await
    }
    async fn list_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<PlaybackSession>, CoordinationError> {
        SessionCache::list_for_account(self, account_id).await
    }
    async fn set_status(
        &self,
        id: Uuid,
        status: SessionStatus,
        at: DateTime<Utc>,
    ) -> Result<(), CoordinationError> {
        SessionCache::set_status(self, id, status, at).await
    }
    async fn transfer(
        &self,
        id: Uuid,
        new_generation: i64,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<(), CoordinationError> {
        SessionCache::transfer(self, id, new_generation, transferred_to_device, transferred_to_session).await
    }
    async fn bump_generation(&self, id: Uuid) -> Result<i64, CoordinationError> {
        SessionCache::bump_generation(self, id).await
    }
    async fn bump_and_transfer(
        &self,
        id: Uuid,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<i64, CoordinationError> {
        SessionCache::bump_and_transfer(self, id, transferred_to_device, transferred_to_session)
            .await
    }
    async fn delete_transferred_before(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, CoordinationError> {
        SessionCache::delete_transferred_before(self, cutoff).await
    }
    async fn delete_offline_for_device(
        &self,
        device_id: Uuid,
        keep_session_id: Option<Uuid>,
    ) -> Result<u64, CoordinationError> {
        SessionCache::delete_offline_for_device(self, device_id, keep_session_id).await
    }
}