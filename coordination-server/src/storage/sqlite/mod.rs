//! SQLite repository implementations. Business modules see the trait
//! abstractions in [`super::repository`]; the SQL lives here.
//!
//! Note: the challenge and ticket repositories are **in-memory** (see
//! [`crate::storage::inmemory`]) since they hold only short-TTL one-time
//! credentials that are useless across restarts. Keeping them out of SQLite
//! removes two write paths from the database.

mod account;
mod device;
mod history;
mod presence;
mod session;
mod ticket;

pub use account::SqliteAccountRepository;
pub use challenge::SqliteChallengeRepository;
pub use device::SqliteDeviceRepository;
pub use history::SqliteHistoryRepository;
pub use presence::SqlitePresenceRepository;
pub use session::SqliteSessionRepository;
pub use ticket::SqliteTicketRepository;

// Keep the SQLite challenge/ticket modules compiled (they carry tests and
// remain available for callers that want SQLite-backed short-lived creds).
mod challenge;
pub use challenge::SqliteChallengeRepository as _SqliteChallengeRepository;

use crate::storage::inmemory::{InMemoryChallengeRepository, InMemoryTicketRepository};
use sqlx::SqlitePool;

/// Bundle of all repositories. Account/device/session/history/presence are
/// SQLite-backed; challenges and tickets are in-memory.
#[derive(Clone)]
pub struct SqliteRepositories {
    pub accounts: SqliteAccountRepository,
    pub devices: SqliteDeviceRepository,
    pub sessions: SqliteSessionRepository,
    pub history: SqliteHistoryRepository,
    pub presence: SqlitePresenceRepository,
    pub challenges: InMemoryChallengeRepository,
    pub tickets: InMemoryTicketRepository,
}

impl SqliteRepositories {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            accounts: SqliteAccountRepository::new(pool.clone()),
            devices: SqliteDeviceRepository::new(pool.clone()),
            sessions: SqliteSessionRepository::new(pool.clone()),
            history: SqliteHistoryRepository::new(pool.clone()),
            presence: SqlitePresenceRepository::new(pool),
            challenges: InMemoryChallengeRepository::new(),
            tickets: InMemoryTicketRepository::new(),
        }
    }
}
