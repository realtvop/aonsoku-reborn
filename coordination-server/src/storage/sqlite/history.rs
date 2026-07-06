//! SQLite implementation of [`crate::storage::repository::HistoryRepository`].
//!
//! History operations are idempotent on `operation_id`. The server assigns a
//! monotonic account-level revision number to each accepted operation
//! (design §7.4, §8.1). Clear operations bump the account history generation
//! so old entries and uploads cannot resurrect (design §8.3).

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{sqlite::SqliteRow, Row, SqlitePool};
use uuid::Uuid;

use crate::errors::CoordinationError;
use crate::storage::models::{HistoryEntry, HistoryOperation, HistoryTombstone};
use crate::storage::repository::HistoryRepository;

#[derive(Clone)]
pub struct SqliteHistoryRepository {
    pool: SqlitePool,
}

impl SqliteHistoryRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

fn parse_entry(row: SqliteRow) -> Result<HistoryEntry, sqlx::Error> {
    Ok(HistoryEntry {
        event_id: Uuid::parse_str(row.get::<&str, _>("event_id")).unwrap(),
        account_id: Uuid::parse_str(row.get::<&str, _>("account_id")).unwrap(),
        history_generation: row.get("history_generation"),
        revision: row.get("revision"),
        logical_playback_session_id: Uuid::parse_str(
            row.get::<&str, _>("logical_playback_session_id"),
        )
        .unwrap(),
        song_id: row.get("song_id"),
        song_title: row.get("song_title"),
        song_artist: row.get("song_artist"),
        song_album: row.get("song_album"),
        song_duration: row.get("song_duration"),
        client_entered_at: row.get("client_entered_at"),
        server_clock_offset: row.get("server_clock_offset"),
        server_received_at: row.get("server_received_at"),
        deleted: row.get::<i64, _>("deleted") != 0,
    })
}

fn parse_tombstone(row: SqliteRow) -> Result<HistoryTombstone, sqlx::Error> {
    Ok(HistoryTombstone {
        event_id: Uuid::parse_str(row.get::<&str, _>("event_id")).unwrap(),
        account_id: Uuid::parse_str(row.get::<&str, _>("account_id")).unwrap(),
        revision: row.get("revision"),
        created_at: row.get("created_at"),
    })
}

#[async_trait]
impl HistoryRepository for SqliteHistoryRepository {
    async fn append(
        &self,
        op: &HistoryOperation,
        entry: &HistoryEntry,
    ) -> Result<i64, CoordinationError> {
        let now = Utc::now();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        // Idempotency: if we've seen this operation id, return the already
        // assigned revision (design §8.1).
        let existing_revision: Option<(i64,)> =
            sqlx::query_as("SELECT revision FROM history_operations WHERE operation_id = ?")
                .bind(op.operation_id.to_string())
                .fetch_optional(&mut *tx)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if let Some((rev,)) = existing_revision {
            return Ok(rev);
        }

        // Assign the next account-level revision.
        let (current_revision,): (i64,) = sqlx::query_as(
            "SELECT COALESCE(MAX(revision), 0) FROM history_operations WHERE account_id = ?",
        )
        .bind(op.account_id.to_string())
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        let new_revision = current_revision + 1;

        sqlx::query(
            "INSERT INTO history_operations (operation_id, account_id, kind, revision, created_at) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(op.operation_id.to_string())
        .bind(op.account_id.to_string())
        .bind(op.kind.as_str())
        .bind(new_revision)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;

        sqlx::query(
            "INSERT INTO history_entries (event_id, account_id, history_generation, revision, logical_playback_session_id, song_id, song_title, song_artist, song_album, song_duration, client_entered_at, server_clock_offset, server_received_at, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(event_id) DO NOTHING",
        )
        .bind(entry.event_id.to_string())
        .bind(entry.account_id.to_string())
        .bind(entry.history_generation)
        .bind(new_revision)
        .bind(entry.logical_playback_session_id.to_string())
        .bind(&entry.song_id)
        .bind(&entry.song_title)
        .bind(&entry.song_artist)
        .bind(&entry.song_album)
        .bind(entry.song_duration)
        .bind(entry.client_entered_at)
        .bind(entry.server_clock_offset)
        .bind(entry.server_received_at)
        .execute(&mut *tx)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(new_revision)
    }

    async fn delete_one(
        &self,
        op: &HistoryOperation,
        event_id: Uuid,
    ) -> Result<(), CoordinationError> {
        let now = Utc::now();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        let existing: Option<(i64,)> =
            sqlx::query_as("SELECT revision FROM history_operations WHERE operation_id = ?")
                .bind(op.operation_id.to_string())
                .fetch_optional(&mut *tx)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if existing.is_some() {
            return Ok(());
        }

        let (current,): (i64,) = sqlx::query_as(
            "SELECT COALESCE(MAX(revision), 0) FROM history_operations WHERE account_id = ?",
        )
        .bind(op.account_id.to_string())
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        let new_revision = current + 1;

        sqlx::query("INSERT INTO history_operations (operation_id, account_id, kind, revision, created_at) VALUES (?, ?, ?, ?, ?)")
            .bind(op.operation_id.to_string())
            .bind(op.account_id.to_string())
            .bind(op.kind.as_str())
            .bind(new_revision)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        sqlx::query("UPDATE history_entries SET deleted = 1 WHERE event_id = ? AND account_id = ?")
            .bind(event_id.to_string())
            .bind(op.account_id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        sqlx::query("INSERT INTO history_tombstones (event_id, account_id, revision, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(event_id) DO NOTHING")
            .bind(event_id.to_string())
            .bind(op.account_id.to_string())
            .bind(new_revision)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn clear(&self, op: &HistoryOperation) -> Result<(), CoordinationError> {
        let now = Utc::now();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        let existing: Option<(i64,)> =
            sqlx::query_as("SELECT revision FROM history_operations WHERE operation_id = ?")
                .bind(op.operation_id.to_string())
                .fetch_optional(&mut *tx)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if existing.is_some() {
            return Ok(());
        }

        let (current,): (i64,) = sqlx::query_as(
            "SELECT COALESCE(MAX(revision), 0) FROM history_operations WHERE account_id = ?",
        )
        .bind(op.account_id.to_string())
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        let new_revision = current + 1;

        // Bump the account history generation so old entries / uploads cannot
        // resurrect (design §8.3).
        sqlx::query("UPDATE accounts SET history_generation = history_generation + 1, updated_at = ? WHERE id = ?")
            .bind(now)
            .bind(op.account_id.to_string())
            .execute(&mut *tx)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        sqlx::query("INSERT INTO history_operations (operation_id, account_id, kind, revision, created_at) VALUES (?, ?, ?, ?, ?)")
            .bind(op.operation_id.to_string())
            .bind(op.account_id.to_string())
            .bind(op.kind.as_str())
            .bind(new_revision)
            .bind(now)
            .execute(&mut *tx)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn list_after(
        &self,
        account_id: Uuid,
        after_revision: i64,
        limit: u32,
    ) -> Result<Vec<HistoryEntry>, CoordinationError> {
        sqlx::query("SELECT * FROM history_entries WHERE account_id = ? AND revision > ? ORDER BY revision ASC LIMIT ?")
            .bind(account_id.to_string())
            .bind(after_revision)
            .bind(limit as i64)
            .try_map(parse_entry)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn list_tombstones_after(
        &self,
        account_id: Uuid,
        after_revision: i64,
        limit: u32,
    ) -> Result<Vec<HistoryTombstone>, CoordinationError> {
        sqlx::query("SELECT * FROM history_tombstones WHERE account_id = ? AND revision > ? ORDER BY revision ASC LIMIT ?")
            .bind(account_id.to_string())
            .bind(after_revision)
            .bind(limit as i64)
            .try_map(parse_tombstone)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn prune_to_limit(&self, account_id: Uuid, limit: u32) -> Result<u64, CoordinationError> {
        // Soft-delete entries beyond the account-level limit. We keep only
        // the newest `limit` non-deleted entries per account (design §8.1).
        let res = sqlx::query(
            "DELETE FROM history_entries WHERE account_id = ? AND deleted = 0 AND event_id NOT IN (
                SELECT event_id FROM history_entries WHERE account_id = ? AND deleted = 0
                ORDER BY revision DESC LIMIT ?
            )",
        )
        .bind(account_id.to_string())
        .bind(account_id.to_string())
        .bind(limit as i64)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(res.rows_affected())
    }

    async fn prune_tombstones(&self, older_than: DateTime<Utc>) -> Result<u64, CoordinationError> {
        let res = sqlx::query("DELETE FROM history_tombstones WHERE created_at < ?")
            .bind(older_than)
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(res.rows_affected())
    }

    async fn operation_seen(&self, operation_id: Uuid) -> Result<bool, CoordinationError> {
        let row: Option<(i64,)> =
            sqlx::query_as("SELECT COUNT(*) FROM history_operations WHERE operation_id = ?")
                .bind(operation_id.to_string())
                .fetch_optional(&self.pool)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(row.map(|(c,)| c > 0).unwrap_or(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::models::HistoryOperationKind;
    use crate::storage::open_pool;
    use crate::storage::repository::{AccountRepository, HistoryRepository};
    use crate::storage::sqlite::SqliteAccountRepository;

    async fn setup() -> (tempfile::TempDir, SqlitePool, Uuid) {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let acc = SqliteAccountRepository::new(pool.clone())
            .upsert_by_lookup_key("k", 100)
            .await
            .unwrap();
        (dir, pool, acc.id)
    }

    fn entry(account: Uuid, rev: i64) -> HistoryEntry {
        HistoryEntry {
            event_id: Uuid::new_v4(),
            account_id: account,
            history_generation: 1,
            revision: rev,
            logical_playback_session_id: Uuid::new_v4(),
            song_id: "song-1".into(),
            song_title: Some("t".into()),
            song_artist: Some("a".into()),
            song_album: None,
            song_duration: Some(180.0),
            client_entered_at: Utc::now(),
            server_clock_offset: None,
            server_received_at: Utc::now(),
            deleted: false,
        }
    }

    fn op(account: Uuid, kind: HistoryOperationKind) -> HistoryOperation {
        HistoryOperation {
            operation_id: Uuid::new_v4(),
            account_id: account,
            kind,
            revision: 0,
            created_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn append_assigns_revision_and_idempotent() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteHistoryRepository::new(pool);
        let mut e = entry(acc, 0);
        let o = op(acc, HistoryOperationKind::Add);
        let r1 = repo.append(&o, &e).await.unwrap();
        assert_eq!(r1, 1);
        // Idempotent: same operation id returns same revision.
        let r2 = repo.append(&o, &e).await.unwrap();
        assert_eq!(r1, r2);
        // Different op gets next revision.
        e.event_id = Uuid::new_v4();
        let r3 = repo
            .append(&op(acc, HistoryOperationKind::Add), &e)
            .await
            .unwrap();
        assert_eq!(r3, 2);
    }

    #[tokio::test]
    async fn clear_bumps_generation() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteHistoryRepository::new(pool.clone());
        let acc_repo = SqliteAccountRepository::new(pool);
        let before = acc_repo.find_by_id(acc).await.unwrap().unwrap();
        repo.clear(&op(acc, HistoryOperationKind::Clear))
            .await
            .unwrap();
        let after = acc_repo.find_by_id(acc).await.unwrap().unwrap();
        assert_eq!(after.history_generation, before.history_generation + 1);
    }

    #[tokio::test]
    async fn delete_one_creates_tombstone() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteHistoryRepository::new(pool);
        let e = entry(acc, 0);
        let o1 = op(acc, HistoryOperationKind::Add);
        repo.append(&o1, &e).await.unwrap();
        let o2 = op(acc, HistoryOperationKind::DeleteOne);
        repo.delete_one(&o2, e.event_id).await.unwrap();
        let tombs = repo.list_tombstones_after(acc, 0, 10).await.unwrap();
        assert_eq!(tombs.len(), 1);
        assert_eq!(tombs[0].event_id, e.event_id);
    }

    #[tokio::test]
    async fn prune_to_limit_keeps_newest() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteHistoryRepository::new(pool);
        for _ in 0..10 {
            let mut e = entry(acc, 0);
            e.event_id = Uuid::new_v4();
            repo.append(&op(acc, HistoryOperationKind::Add), &e)
                .await
                .unwrap();
        }
        let removed = repo.prune_to_limit(acc, 3).await.unwrap();
        assert!(removed >= 7);
        let kept = repo.list_after(acc, 0, 100).await.unwrap();
        assert_eq!(kept.len(), 3);
    }
}
