//! SQLite implementation of [`crate::storage::repository::TicketRepository`].
//! One-time WebSocket tickets (design §6.3).

use async_trait::async_trait;
use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::CoordinationError;
use crate::storage::repository::TicketRepository;
use crate::storage::tokens::generate_ws_ticket;

#[derive(Clone)]
pub struct SqliteTicketRepository {
    pool: SqlitePool,
}

impl SqliteTicketRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl TicketRepository for SqliteTicketRepository {
    async fn issue(
        &self,
        device_id: Uuid,
        ttl: chrono::Duration,
    ) -> Result<String, CoordinationError> {
        let ticket = generate_ws_ticket();
        let now = Utc::now();
        let expires = now + ttl;
        sqlx::query(
            "INSERT INTO ws_tickets (ticket, device_id, issued_at, expires_at) VALUES (?, ?, ?, ?)",
        )
        .bind(&ticket)
        .bind(device_id.to_string())
        .bind(now)
        .bind(expires)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(ticket)
    }

    async fn consume(&self, ticket: &str) -> Result<Option<Uuid>, CoordinationError> {
        let now = Utc::now();
        let res = sqlx::query(
            "UPDATE ws_tickets SET used = 1 WHERE ticket = ? AND used = 0 AND expires_at > ?",
        )
        .bind(ticket)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if res.rows_affected() == 0 {
            return Ok(None);
        }
        let row: Option<(String,)> =
            sqlx::query_as("SELECT device_id FROM ws_tickets WHERE ticket = ?")
                .bind(ticket)
                .fetch_optional(&self.pool)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(row.and_then(|(d,)| Uuid::parse_str(&d).ok()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::open_pool;
    use crate::storage::repository::{AccountRepository, DeviceRepository, TicketRepository};
    use crate::storage::sqlite::{SqliteAccountRepository, SqliteDeviceRepository};

    #[tokio::test]
    async fn issue_and_consume_once() {
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
        let repo = SqliteTicketRepository::new(pool);
        let t = repo
            .issue(dev.id, chrono::Duration::seconds(30))
            .await
            .unwrap();
        let d = repo.consume(&t).await.unwrap();
        assert_eq!(d, Some(dev.id));
        // Second consume returns None.
        assert_eq!(repo.consume(&t).await.unwrap(), None);
        drop(dir);
    }
}
