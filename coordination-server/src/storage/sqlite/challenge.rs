//! SQLite implementation of [`crate::storage::repository::ChallengeRepository`].
//! One-time registration challenges (design §6.2).

use async_trait::async_trait;
use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::repository::ChallengeRepository;

#[derive(Clone)]
pub struct SqliteChallengeRepository {
    pool: SqlitePool,
}

impl SqliteChallengeRepository {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl ChallengeRepository for SqliteChallengeRepository {
    async fn issue(
        &self,
        normalised_identity: &str,
        username: &str,
        ttl: chrono::Duration,
    ) -> Result<Uuid, CoordinationError> {
        let id = Uuid::new_v4();
        let now = Utc::now();
        let expires = now + ttl;
        sqlx::query("INSERT INTO auth_challenges (id, normalised_identity, username, created_at, expires_at) VALUES (?, ?, ?, ?, ?)")
            .bind(id.to_string())
            .bind(normalised_identity)
            .bind(username)
            .bind(now)
            .bind(expires)
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        Ok(id)
    }

    async fn consume(&self, id: Uuid) -> Result<bool, CoordinationError> {
        let now = Utc::now();
        // Atomic: only consume if not yet consumed and not expired.
        let res = sqlx::query("UPDATE auth_challenges SET consumed = 1 WHERE id = ? AND consumed = 0 AND expires_at > ?")
            .bind(id.to_string())
            .bind(now)
            .execute(&self.pool)
            .await
            .map_err(|e| CoordinationError::internal(e.to_string()))?;
        if res.rows_affected() == 0 {
            // Distinguish expired vs already consumed for clearer errors.
            let row: Option<(i64, chrono::DateTime<Utc>)> =
                sqlx::query_as("SELECT consumed, expires_at FROM auth_challenges WHERE id = ?")
                    .bind(id.to_string())
                    .fetch_optional(&self.pool)
                    .await
                    .map_err(|e| CoordinationError::internal(e.to_string()))?;
            match row {
                None => Err(CoordinationError::new(
                    ErrorCode::NotFound,
                    "challenge not found",
                )),
                Some((consumed, _expires)) if consumed != 0 => Err(CoordinationError::new(
                    ErrorCode::ChallengeExpired,
                    "challenge already consumed",
                )),
                Some((_, expires)) if expires <= now => Err(CoordinationError::new(
                    ErrorCode::ChallengeExpired,
                    "challenge expired",
                )),
                _ => Ok(false),
            }
        } else {
            Ok(true)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::open_pool;
    use crate::storage::repository::ChallengeRepository;

    #[tokio::test]
    async fn issue_and_consume_once() {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let repo = SqliteChallengeRepository::new(pool);
        let id = repo
            .issue("https://x", "u", chrono::Duration::seconds(60))
            .await
            .unwrap();
        assert!(repo.consume(id).await.unwrap());
        // Second consume fails with challenge_expired.
        let err = repo.consume(id).await.unwrap_err();
        assert_eq!(err.code, ErrorCode::ChallengeExpired);
        drop(dir);
    }
}
