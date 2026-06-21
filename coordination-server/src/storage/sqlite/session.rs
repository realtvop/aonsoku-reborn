//! SQLite implementation of [`crate::storage::repository::SessionRepository`].

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{sqlite::SqliteRow, Row, SqlitePool};
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::models::{PlaybackSession, SessionStatus};
use crate::storage::repository::SessionRepository;

#[derive(Clone)]
pub struct SqliteSessionRepository {
    pool: SqlitePool,
}

impl SqliteSessionRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

fn parse_session(row: SqliteRow) -> Result<PlaybackSession, sqlx::Error> {
    let status_str: String = row.get("status");
    let status = SessionStatus::parse(&status_str).expect("valid status in db");
    Ok(PlaybackSession {
        id: Uuid::parse_str(row.get::<&str, _>("id")).expect("valid uuid"),
        device_id: Uuid::parse_str(row.get::<&str, _>("device_id")).expect("valid uuid"),
        account_id: Uuid::parse_str(row.get::<&str, _>("account_id")).expect("valid uuid"),
        generation: row.get("generation"),
        snapshot_revision: row.get("snapshot_revision"),
        status,
        last_snapshot: row.get("last_snapshot"),
        last_snapshot_at: row.get("last_snapshot_at"),
        offline_at: row.get("offline_at"),
        transferred_to_device: row
            .get::<Option<&str>, _>("transferred_to_device")
            .and_then(|s| Uuid::parse_str(s).ok()),
        transferred_to_session: row
            .get::<Option<&str>, _>("transferred_to_session")
            .and_then(|s| Uuid::parse_str(s).ok()),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    })
}

#[async_trait]
impl SessionRepository for SqliteSessionRepository {
    async fn upsert_snapshot(
        &self,
        session: &PlaybackSession,
        snapshot_json: &str,
    ) -> Result<PlaybackSession, CoordinationError> {
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO playback_sessions (id, device_id, account_id, generation, snapshot_revision, status, last_snapshot, last_snapshot_at, offline_at, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET
               generation = excluded.generation,
               snapshot_revision = excluded.snapshot_revision,
               status = excluded.status,
               last_snapshot = excluded.last_snapshot,
               last_snapshot_at = excluded.last_snapshot_at,
               offline_at = COALESCE(excluded.offline_at, offline_at),
               updated_at = excluded.updated_at",
        )
        .bind(session.id.to_string())
        .bind(session.device_id.to_string())
        .bind(session.account_id.to_string())
        .bind(session.generation)
        .bind(session.snapshot_revision)
        .bind(session.status.as_str())
        .bind(snapshot_json)
        .bind(session.last_snapshot_at.unwrap_or(now))
        .bind(session.offline_at)
        .bind(session.created_at)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(session.id)
            .await?
            .ok_or_else(|| CoordinationError::internal("session upsert failed"))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<PlaybackSession>, CoordinationError> {
        sqlx::query("SELECT * FROM playback_sessions WHERE id = ?")
            .bind(id.to_string())
            .try_map(parse_session)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn find_active_for_device(
        &self,
        device_id: Uuid,
    ) -> Result<Option<PlaybackSession>, CoordinationError> {
        sqlx::query("SELECT * FROM playback_sessions WHERE device_id = ? AND status != 'transferred' ORDER BY updated_at DESC LIMIT 1")
            .bind(device_id.to_string())
            .try_map(parse_session)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn list_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<PlaybackSession>, CoordinationError> {
        sqlx::query("SELECT * FROM playback_sessions WHERE account_id = ? ORDER BY updated_at DESC")
            .bind(account_id.to_string())
            .try_map(parse_session)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn set_status(
        &self,
        id: Uuid,
        status: SessionStatus,
        at: DateTime<Utc>,
    ) -> Result<(), CoordinationError> {
        let offline_at = if status == SessionStatus::Offline {
            Some(at)
        } else {
            None
        };
        sqlx::query("UPDATE playback_sessions SET status = ?, offline_at = COALESCE(?, offline_at), updated_at = ? WHERE id = ?")
            .bind(status.as_str())
            .bind(offline_at)
            .bind(at)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn transfer(
        &self,
        id: Uuid,
        new_generation: i64,
        transferred_to_device: Uuid,
        transferred_to_session: Uuid,
    ) -> Result<(), CoordinationError> {
        let now = Utc::now();
        let res = sqlx::query(
            "UPDATE playback_sessions SET status = 'transferred', generation = ?, transferred_to_device = ?, transferred_to_session = ?, updated_at = ? WHERE id = ?",
        )
        .bind(new_generation)
        .bind(transferred_to_device.to_string())
        .bind(transferred_to_session.to_string())
        .bind(now)
        .bind(id.to_string())
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if res.rows_affected() == 0 {
            return Err(CoordinationError::new(
                ErrorCode::NotFound,
                "session not found",
            ));
        }
        Ok(())
    }

    async fn bump_generation(&self, id: Uuid) -> Result<i64, CoordinationError> {
        let now = Utc::now();
        sqlx::query(
            "UPDATE playback_sessions SET generation = generation + 1, updated_at = ? WHERE id = ?",
        )
        .bind(now)
        .bind(id.to_string())
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        let row: (i64,) = sqlx::query_as("SELECT generation FROM playback_sessions WHERE id = ?")
            .bind(id.to_string())
            .fetch_one(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(row.0)
    }

    async fn delete_transferred_before(
        &self,
        cutoff: DateTime<Utc>,
    ) -> Result<u64, CoordinationError> {
        let res = sqlx::query(
            "DELETE FROM playback_sessions WHERE status = 'transferred' AND updated_at < ?",
        )
        .bind(cutoff)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(res.rows_affected())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::models::SessionStatus;
    use crate::storage::open_pool;
    use crate::storage::repository::{AccountRepository, DeviceRepository, SessionRepository};
    use crate::storage::sqlite::{SqliteAccountRepository, SqliteDeviceRepository};

    async fn setup() -> (tempfile::TempDir, SqlitePool, Uuid, Uuid) {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let acc = SqliteAccountRepository::new(pool.clone())
            .upsert_by_lookup_key("k", 100)
            .await
            .unwrap();
        let dev = SqliteDeviceRepository::new(pool.clone())
            .create(acc.id, "P", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        (dir, pool, acc.id, dev.id)
    }

    fn new_session(device: Uuid, account: Uuid) -> PlaybackSession {
        PlaybackSession {
            id: Uuid::new_v4(),
            device_id: device,
            account_id: account,
            generation: 1,
            snapshot_revision: 0,
            status: SessionStatus::Online,
            last_snapshot: None,
            last_snapshot_at: None,
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn upsert_creates_and_updates_snapshot() {
        let (_dir, pool, acc, dev) = setup().await;
        let repo = SqliteSessionRepository::new(pool);
        let mut s = new_session(dev, acc);
        s = repo.upsert_snapshot(&s, "{}").await.unwrap();
        assert_eq!(s.snapshot_revision, 0);
        let mut s2 = s.clone();
        s2.snapshot_revision = 5;
        let s2_back = repo.upsert_snapshot(&s2, "{\"v\":5}").await.unwrap();
        assert_eq!(s2_back.snapshot_revision, 5);
    }

    #[tokio::test]
    async fn transfer_marks_transferred() {
        let (_dir, pool, acc, dev) = setup().await;
        let repo = SqliteSessionRepository::new(pool.clone());
        let s = new_session(dev, acc);
        repo.upsert_snapshot(&s, "{}").await.unwrap();
        // Create a second real device and a real target session to transfer to.
        let new_dev = SqliteDeviceRepository::new(pool.clone())
            .create(acc, "P2", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();
        let target = new_session(new_dev.id, acc);
        repo.upsert_snapshot(&target, "{}").await.unwrap();
        repo.transfer(s.id, 2, new_dev.id, target.id).await.unwrap();
        let back = repo.find_by_id(s.id).await.unwrap().unwrap();
        assert_eq!(back.status, SessionStatus::Transferred);
    }

    #[tokio::test]
    async fn delete_transferred_before_removes_old_transferred_only() {
        let (_dir, pool, acc, dev) = setup().await;
        let repo = SqliteSessionRepository::new(pool.clone());
        let new_dev = SqliteDeviceRepository::new(pool.clone())
            .create(acc, "P2", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // Old transferred session (updated_at in the past).
        let old_s = new_session(dev, acc);
        repo.upsert_snapshot(&old_s, "{}").await.unwrap();
        let old_target = new_session(new_dev.id, acc);
        repo.upsert_snapshot(&old_target, "{}").await.unwrap();
        repo.transfer(old_s.id, 2, new_dev.id, old_target.id)
            .await
            .unwrap();
        // Manually backdate updated_at to 10 days ago.
        let ten_days_ago = Utc::now() - chrono::Duration::days(10);
        sqlx::query("UPDATE playback_sessions SET updated_at = ? WHERE id = ?")
            .bind(ten_days_ago)
            .bind(old_s.id.to_string())
            .execute(&pool)
            .await
            .unwrap();

        // Recent transferred session.
        let recent_s = new_session(dev, acc);
        repo.upsert_snapshot(&recent_s, "{}").await.unwrap();
        let recent_target = new_session(new_dev.id, acc);
        repo.upsert_snapshot(&recent_target, "{}").await.unwrap();
        repo.transfer(recent_s.id, 2, new_dev.id, recent_target.id)
            .await
            .unwrap();

        // Online session that should never be touched.
        let online_s = new_session(dev, acc);
        repo.upsert_snapshot(&online_s, "{}").await.unwrap();

        let cutoff = Utc::now() - chrono::Duration::days(7);
        let removed = repo.delete_transferred_before(cutoff).await.unwrap();
        assert_eq!(removed, 1);
        assert!(repo.find_by_id(old_s.id).await.unwrap().is_none());
        assert!(repo.find_by_id(recent_s.id).await.unwrap().is_some());
        assert!(repo.find_by_id(online_s.id).await.unwrap().is_some());
    }
}
