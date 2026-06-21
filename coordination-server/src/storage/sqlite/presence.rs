//! SQLite implementation of [`crate::storage::repository::PresenceRepository`].

use async_trait::async_trait;
use sqlx::{sqlite::SqliteRow, Row, SqlitePool};
use uuid::Uuid;

use crate::errors::CoordinationError;
use crate::storage::models::DevicePresence;
use crate::storage::repository::PresenceRepository;

#[derive(Clone)]
pub struct SqlitePresenceRepository {
    pool: SqlitePool,
}

impl SqlitePresenceRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

fn parse_presence(row: SqliteRow) -> Result<DevicePresence, sqlx::Error> {
    Ok(DevicePresence {
        device_id: Uuid::parse_str(row.get::<&str, _>("device_id")).unwrap(),
        account_id: Uuid::parse_str(row.get::<&str, _>("account_id")).unwrap(),
        is_online: row.get::<i64, _>("is_online") != 0,
        last_seen_at: row.get("last_seen_at"),
        last_seq: row.get("last_seq"),
    })
}

#[async_trait]
impl PresenceRepository for SqlitePresenceRepository {
    async fn upsert(&self, presence: &DevicePresence) -> Result<(), CoordinationError> {
        sqlx::query(
            "INSERT INTO device_presence (device_id, account_id, is_online, last_seen_at, last_seq)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(device_id) DO UPDATE SET
               account_id = excluded.account_id,
               is_online = excluded.is_online,
               last_seen_at = excluded.last_seen_at,
               last_seq = excluded.last_seq",
        )
        .bind(presence.device_id.to_string())
        .bind(presence.account_id.to_string())
        .bind(presence.is_online as i64)
        .bind(presence.last_seen_at)
        .bind(presence.last_seq)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn find(&self, device_id: Uuid) -> Result<Option<DevicePresence>, CoordinationError> {
        sqlx::query("SELECT * FROM device_presence WHERE device_id = ?")
            .bind(device_id.to_string())
            .try_map(parse_presence)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn list_online_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<DevicePresence>, CoordinationError> {
        sqlx::query("SELECT * FROM device_presence WHERE account_id = ? AND is_online = 1")
            .bind(account_id.to_string())
            .try_map(parse_presence)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }
}
