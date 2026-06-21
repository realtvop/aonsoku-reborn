//! SQLite storage layer: migrations, connection setup, repository traits
//! and data models (design §7, §14).
//!
//! The storage module owns all SQL. Business modules see repository traits
//! that hide SQL details (design §5.1). The server runs migrations on boot
//! before accepting traffic (design §14).

pub mod inmemory;
pub mod models;
pub mod repository;
pub mod sqlite;
pub mod tokens;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::str::FromStr;

/// Configure and open a SQLite connection pool with WAL, foreign keys and a
/// reasonable busy timeout (design §14).
pub async fn open_pool(database_url: &str) -> anyhow::Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .foreign_keys(true)
        .busy_timeout(std::time::Duration::from_secs(5))
        .synchronous(sqlx::sqlite::SqliteSynchronous::Normal);

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await?;
    Ok(pool)
}

/// Run pending migrations. Failure must flip readiness to false (design §14).
pub async fn run_migrations(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::migrate!("./migrations").run(pool).await?;
    Ok(())
}
