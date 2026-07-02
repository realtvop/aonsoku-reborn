//! In-memory implementations of the short-lived credential repositories
//! (`ChallengeRepository`, `TicketRepository`). These rows have second-to-
//! minute TTLs and are useless across restarts, so they need not touch SQLite
//! (design §6.2, §6.3). Keeping them in memory removes two low-frequency but
//! latency-sensitive write paths from the database.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use parking_lot::Mutex;
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};
use crate::storage::repository::{ChallengeRepository, ConsumedChallenge, TicketRepository};
use crate::storage::tokens::generate_ws_ticket;

#[derive(Clone)]
#[allow(dead_code)]
struct ChallengeEntry {
    normalised_identity: String,
    username: String,
    created_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    consumed: bool,
}

#[derive(Clone)]
#[allow(dead_code)]
struct TicketEntry {
    device_id: Uuid,
    issued_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    used: bool,
}

/// In-memory one-time registration challenge store (design §6.2). The map is
/// shared via `Arc` so cloning the repository (e.g. `AppState::clone`) is
/// cheap and all clones see the same underlying state.
#[derive(Default, Clone)]
pub struct InMemoryChallengeRepository {
    challenges: Arc<Mutex<HashMap<Uuid, ChallengeEntry>>>,
}

impl InMemoryChallengeRepository {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl ChallengeRepository for InMemoryChallengeRepository {
    async fn issue(
        &self,
        normalised_identity: &str,
        username: &str,
        ttl: chrono::Duration,
    ) -> Result<Uuid, CoordinationError> {
        let id = Uuid::new_v4();
        let now = Utc::now();
        self.challenges.lock().insert(
            id,
            ChallengeEntry {
                normalised_identity: normalised_identity.to_string(),
                username: username.to_string(),
                created_at: now,
                expires_at: now + ttl,
                consumed: false,
            },
        );
        Ok(id)
    }

    async fn consume(&self, id: Uuid) -> Result<ConsumedChallenge, CoordinationError> {
        let now = Utc::now();
        let mut map = self.challenges.lock();
        match map.get_mut(&id) {
            None => Err(CoordinationError::new(
                ErrorCode::NotFound,
                "challenge not found",
            )),
            Some(entry) if entry.consumed => Err(CoordinationError::new(
                ErrorCode::ChallengeExpired,
                "challenge already consumed",
            )),
            Some(entry) if entry.expires_at <= now => Err(CoordinationError::new(
                ErrorCode::ChallengeExpired,
                "challenge expired",
            )),
            Some(entry) => {
                entry.consumed = true;
                Ok(ConsumedChallenge {
                    normalised_identity: entry.normalised_identity.clone(),
                    normalised_username: entry.username.clone(),
                })
            }
        }
    }
}

/// In-memory one-time WebSocket ticket store (design §6.3). Shared via
/// `Arc` for cheap clones and a single source of truth.
#[derive(Default, Clone)]
pub struct InMemoryTicketRepository {
    tickets: Arc<Mutex<HashMap<String, TicketEntry>>>,
}

impl InMemoryTicketRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Drop expired tickets. Called opportunistically by the issuer to keep
    /// the map bounded without a dedicated background sweeper.
    fn sweep_expired(&self, now: DateTime<Utc>) {
        let mut map = self.tickets.lock();
        map.retain(|_, entry| entry.expires_at > now);
    }
}

#[async_trait]
impl TicketRepository for InMemoryTicketRepository {
    async fn issue(
        &self,
        device_id: Uuid,
        ttl: chrono::Duration,
    ) -> Result<String, CoordinationError> {
        let ticket = generate_ws_ticket();
        let now = Utc::now();
        // Opportunistic GC: prune expired tickets so the map does not grow
        // unboundedly across long uptimes.
        self.sweep_expired(now);
        self.tickets.lock().insert(
            ticket.clone(),
            TicketEntry {
                device_id,
                issued_at: now,
                expires_at: now + ttl,
                used: false,
            },
        );
        Ok(ticket)
    }

    async fn consume(&self, ticket: &str) -> Result<Option<Uuid>, CoordinationError> {
        let now = Utc::now();
        let mut map = self.tickets.lock();
        match map.get_mut(ticket) {
            Some(entry) if !entry.used && entry.expires_at > now => {
                entry.used = true;
                Ok(Some(entry.device_id))
            }
            _ => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn challenge_issue_and_consume_once() {
        let repo = InMemoryChallengeRepository::new();
        let id = repo
            .issue("https://x", "u", chrono::Duration::seconds(60))
            .await
            .unwrap();
        let consumed = repo.consume(id).await.unwrap();
        assert_eq!(consumed.normalised_identity, "https://x");
        assert_eq!(consumed.normalised_username, "u");
        let err = repo.consume(id).await.unwrap_err();
        assert_eq!(err.code, ErrorCode::ChallengeExpired);
    }

    #[tokio::test]
    async fn ticket_issue_and_consume_once() {
        let repo = InMemoryTicketRepository::new();
        let dev_id = Uuid::new_v4();
        let t = repo
            .issue(dev_id, chrono::Duration::seconds(30))
            .await
            .unwrap();
        assert_eq!(repo.consume(&t).await.unwrap(), Some(dev_id));
        assert_eq!(repo.consume(&t).await.unwrap(), None);
    }

    #[tokio::test]
    async fn ticket_expired_returns_none() {
        let repo = InMemoryTicketRepository::new();
        let dev_id = Uuid::new_v4();
        let t = repo
            .issue(dev_id, chrono::Duration::seconds(0))
            .await
            .unwrap();
        // expires_at == now, so the `expires_at > now` guard fails.
        // Yield once to ensure `now` advances past expiry.
        tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        assert_eq!(repo.consume(&t).await.unwrap(), None);
    }
}
