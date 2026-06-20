//! SQLite implementation of [`crate::storage::repository::DeviceRepository`].

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{sqlite::SqliteRow, Row, SqlitePool};
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::models::Device;
use crate::storage::repository::DeviceRepository;

#[derive(Clone)]
pub struct SqliteDeviceRepository {
    pool: SqlitePool,
}

impl SqliteDeviceRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

fn parse_device(row: SqliteRow) -> Result<Device, sqlx::Error> {
    Ok(Device {
        id: Uuid::parse_str(row.get::<&str, _>("id")).expect("valid uuid"),
        account_id: Uuid::parse_str(row.get::<&str, _>("account_id")).expect("valid uuid"),
        name: row.get("name"),
        platform: row.get("platform"),
        client_version: row.get("client_version"),
        capabilities: row.get::<i64, _>("capabilities") as u32,
        created_at: row.get("created_at"),
        last_online_at: row.get("last_online_at"),
        revoked_at: row.get("revoked_at"),
        history_sync_cursor: row.get("history_sync_cursor"),
        legacy_history_imported: row.get::<i64, _>("legacy_history_imported") != 0,
        refresh_token_hash: row.get("refresh_token_hash"),
        refresh_token_family: Uuid::parse_str(row.get::<&str, _>("refresh_token_family")).unwrap(),
        refresh_token_last_used_at: row.get("refresh_token_last_used_at"),
    })
}

#[async_trait]
impl DeviceRepository for SqliteDeviceRepository {
    async fn create(
        &self,
        account_id: Uuid,
        name: &str,
        platform: &str,
        client_version: Option<&str>,
        capabilities: u32,
        refresh_token_hash: &str,
        refresh_token_family: Uuid,
    ) -> Result<Device, CoordinationError> {
        let id = Uuid::new_v4();
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO devices (id, account_id, name, platform, client_version, capabilities, created_at, refresh_token_hash, refresh_token_family) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id.to_string())
        .bind(account_id.to_string())
        .bind(name)
        .bind(platform)
        .bind(client_version)
        .bind(capabilities as i64)
        .bind(now)
        .bind(refresh_token_hash)
        .bind(refresh_token_family.to_string())
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::internal("device insert failed"))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Device>, CoordinationError> {
        sqlx::query("SELECT * FROM devices WHERE id = ?")
            .bind(id.to_string())
            .try_map(parse_device)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn list_for_account(&self, account_id: Uuid) -> Result<Vec<Device>, CoordinationError> {
        sqlx::query("SELECT * FROM devices WHERE account_id = ? AND revoked_at IS NULL ORDER BY created_at ASC")
            .bind(account_id.to_string())
            .try_map(parse_device)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn rename(&self, id: Uuid, name: &str) -> Result<Device, CoordinationError> {
        sqlx::query("UPDATE devices SET name = ? WHERE id = ?")
            .bind(name)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "device not found"))
    }

    async fn revoke(&self, id: Uuid) -> Result<Device, CoordinationError> {
        let now = Utc::now();
        sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ?")
            .bind(now)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "device not found"))
    }

    async fn mark_online(&self, id: Uuid, at: DateTime<Utc>) -> Result<(), CoordinationError> {
        sqlx::query("UPDATE devices SET last_online_at = ? WHERE id = ?")
            .bind(at)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn mark_offline(&self, _id: Uuid, _at: DateTime<Utc>) -> Result<(), CoordinationError> {
        // Keep last_online_at as the last *online* moment; don't overwrite it.
        Ok(())
    }

    async fn set_history_cursor(&self, id: Uuid, cursor: i64) -> Result<(), CoordinationError> {
        sqlx::query("UPDATE devices SET history_sync_cursor = ? WHERE id = ?")
            .bind(cursor)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn mark_legacy_imported(&self, id: Uuid) -> Result<(), CoordinationError> {
        sqlx::query("UPDATE devices SET legacy_history_imported = 1 WHERE id = ?")
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn rotate_refresh_token(
        &self,
        id: Uuid,
        new_hash: &str,
        new_family: Uuid,
        used_at: DateTime<Utc>,
    ) -> Result<(), CoordinationError> {
        sqlx::query("UPDATE devices SET refresh_token_hash = ?, refresh_token_family = ?, refresh_token_last_used_at = ? WHERE id = ?")
            .bind(new_hash)
            .bind(new_family.to_string())
            .bind(used_at)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn touch_refresh_token(
        &self,
        id: Uuid,
        used_at: DateTime<Utc>,
    ) -> Result<(), CoordinationError> {
        sqlx::query("UPDATE devices SET refresh_token_last_used_at = ? WHERE id = ?")
            .bind(used_at)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::open_pool;
    use crate::storage::repository::{AccountRepository, DeviceRepository};
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

    #[tokio::test]
    async fn create_and_list() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteDeviceRepository::new(pool.clone());
        let d = repo
            .create(
                acc,
                "Phone",
                "capacitor-ios",
                Some("0.30.0"),
                0,
                "hash",
                Uuid::new_v4(),
            )
            .await
            .unwrap();
        let list = repo.list_for_account(acc).await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, d.id);
    }

    #[tokio::test]
    async fn revoke_hides_from_list() {
        let (_dir, pool, acc) = setup().await;
        let repo = SqliteDeviceRepository::new(pool.clone());
        let d = repo
            .create(
                acc,
                "Phone",
                "capacitor-ios",
                None,
                0,
                "hash",
                Uuid::new_v4(),
            )
            .await
            .unwrap();
        repo.revoke(d.id).await.unwrap();
        assert!(repo.list_for_account(acc).await.unwrap().is_empty());
    }
}
