//! SQLite repository implementations. Business modules see the trait
//! abstractions in [`super::repository`]; the SQL lives here.

mod account;
mod challenge;
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

use sqlx::SqlitePool;

/// Bundle of all SQLite repositories, satisfying
/// [`super::repository::FullRepository`] via composition.
#[derive(Clone)]
pub struct SqliteRepositories {
    pub accounts: SqliteAccountRepository,
    pub devices: SqliteDeviceRepository,
    pub sessions: SqliteSessionRepository,
    pub history: SqliteHistoryRepository,
    pub presence: SqlitePresenceRepository,
    pub challenges: SqliteChallengeRepository,
    pub tickets: SqliteTicketRepository,
}

impl SqliteRepositories {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            accounts: SqliteAccountRepository::new(pool.clone()),
            devices: SqliteDeviceRepository::new(pool.clone()),
            sessions: SqliteSessionRepository::new(pool.clone()),
            history: SqliteHistoryRepository::new(pool.clone()),
            presence: SqlitePresenceRepository::new(pool.clone()),
            challenges: SqliteChallengeRepository::new(pool.clone()),
            tickets: SqliteTicketRepository::new(pool),
        }
    }
}
