//! SQLite implementation of [`crate::storage::repository::ChallengeRepository`].
//! One-time registration challenges (design §6.2).

use async_trait::async_trait;
use chrono::Utc;
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::repository::{ChallengeRepository, ConsumedChallenge};

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

    async fn consume(&self, id: Uuid) -> Result<ConsumedChallenge, CoordinationError> {
        let now = Utc::now();
        // Atomic: only consume if not yet consumed and not expired, returning
        // the bound identity/username in the same statement so the caller can
        // verify the register request matches the challenge that was issued.
        let row: Option<(String, String)> = sqlx::query_as(
            "UPDATE auth_challenges SET consumed = 1 \
             WHERE id = ? AND consumed = 0 AND expires_at > ? \
             RETURNING normalised_identity, username",
        )
        .bind(id.to_string())
        .bind(now)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
        match row {
            Some((identity, username)) => Ok(ConsumedChallenge {
                normalised_identity: identity,
                normalised_username: username,
            }),
            None => {
                // Distinguish expired vs already consumed vs not found.
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
                    _ => Err(CoordinationError::new(
                        ErrorCode::ChallengeExpired,
                        "challenge could not be consumed",
                    )),
                }
            }
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
        let consumed = repo.consume(id).await.unwrap();
        assert_eq!(consumed.normalised_identity, "https://x");
        assert_eq!(consumed.normalised_username, "u");
        // Second consume fails with challenge_expired.
        let err = repo.consume(id).await.unwrap_err();
        assert_eq!(err.code, ErrorCode::ChallengeExpired);
        drop(dir);
    }
}
