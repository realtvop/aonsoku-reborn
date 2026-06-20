//! SQLite implementation of [`crate::storage::repository::AccountRepository`].

use async_trait::async_trait;
use chrono::Utc;
use sqlx::{sqlite::SqliteRow, Row, SqlitePool};
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::models::Account;
use crate::storage::repository::AccountRepository;

#[derive(Clone)]
pub struct SqliteAccountRepository {
    pool: SqlitePool,
}

impl SqliteAccountRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

fn parse_account(row: SqliteRow) -> Result<Account, sqlx::Error> {
    Ok(Account {
        id: Uuid::parse_str(row.get::<&str, _>("id")).expect("valid uuid in db"),
        lookup_key: row.get("lookup_key"),
        history_limit: row.get::<i64, _>("history_limit") as u32,
        history_generation: row.get("history_generation"),
        history_revision: row.get("history_revision"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        deleted_at: row.get("deleted_at"),
    })
}

#[async_trait]
impl AccountRepository for SqliteAccountRepository {
    async fn upsert_by_lookup_key(
        &self,
        lookup_key: &str,
        history_limit: u32,
    ) -> Result<Account, CoordinationError> {
        let now = Utc::now();
        let id = Uuid::new_v4();
        // Upsert: if the lookup key exists and the account is not deleted,
        // return it; otherwise insert.
        let existing: Option<Account> =
            sqlx::query("SELECT * FROM accounts WHERE lookup_key = ? AND deleted_at IS NULL")
                .bind(lookup_key)
                .try_map(parse_account)
                .fetch_optional(&self.pool)
                .await
                .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if let Some(acc) = existing {
            return Ok(acc);
        }
        let _ = sqlx::query(
            "INSERT INTO accounts (id, lookup_key, history_limit, history_generation, history_revision, created_at, updated_at) VALUES (?, ?, ?, 1, 0, ?, ?)",
        )
        .bind(id.to_string())
        .bind(lookup_key)
        .bind(history_limit as i64)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::internal("account insert failed"))
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<Account>, CoordinationError> {
        sqlx::query("SELECT * FROM accounts WHERE id = ? AND deleted_at IS NULL")
            .bind(id.to_string())
            .try_map(parse_account)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn find_by_lookup_key(&self, key: &str) -> Result<Option<Account>, CoordinationError> {
        sqlx::query("SELECT * FROM accounts WHERE lookup_key = ? AND deleted_at IS NULL")
            .bind(key)
            .try_map(parse_account)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))
    }

    async fn set_history_limit(&self, id: Uuid, limit: u32) -> Result<Account, CoordinationError> {
        let now = Utc::now();
        sqlx::query("UPDATE accounts SET history_limit = ?, updated_at = ? WHERE id = ?")
            .bind(limit as i64)
            .bind(now)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "account not found"))
    }

    async fn bump_history_generation(&self, id: Uuid) -> Result<Account, CoordinationError> {
        let now = Utc::now();
        sqlx::query("UPDATE accounts SET history_generation = history_generation + 1, updated_at = ? WHERE id = ?")
            .bind(now)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        self.find_by_id(id)
            .await?
            .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "account not found"))
    }

    async fn delete_account(&self, id: Uuid) -> Result<(), CoordinationError> {
        let now = Utc::now();
        sqlx::query("UPDATE accounts SET deleted_at = ?, updated_at = ? WHERE id = ?")
            .bind(now)
            .bind(now)
            .bind(id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(())
    }

    async fn touch(&self, id: Uuid) -> Result<(), CoordinationError> {
        let now = Utc::now();
        sqlx::query("UPDATE accounts SET updated_at = ? WHERE id = ?")
            .bind(now)
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
    use crate::storage::repository::AccountRepository;

    async fn setup() -> (tempfile::TempDir, SqlitePool) {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        (dir, pool)
    }

    #[tokio::test]
    async fn upsert_returns_same_account_for_same_key() {
        let (_dir, pool) = setup().await;
        let repo = SqliteAccountRepository::new(pool);
        let a = repo.upsert_by_lookup_key("k1", 100).await.unwrap();
        let b = repo.upsert_by_lookup_key("k1", 100).await.unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(a.history_limit, 100);
    }

    #[tokio::test]
    async fn bump_generation_increments() {
        let (_dir, pool) = setup().await;
        let repo = SqliteAccountRepository::new(pool);
        let a = repo.upsert_by_lookup_key("k2", 100).await.unwrap();
        let b = repo.bump_history_generation(a.id).await.unwrap();
        assert_eq!(b.history_generation, a.history_generation + 1);
    }

    #[tokio::test]
    async fn delete_marks_tombstone() {
        let (_dir, pool) = setup().await;
        let repo = SqliteAccountRepository::new(pool);
        let a = repo.upsert_by_lookup_key("k3", 100).await.unwrap();
        repo.delete_account(a.id).await.unwrap();
        let gone = repo.find_by_id(a.id).await.unwrap();
        assert!(gone.is_none());
    }
}
