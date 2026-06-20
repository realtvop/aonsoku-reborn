//! Aonsoku cross-device coordination server binary.

use anyhow::Result;
use aonsoku_coordination_server::config::Config;

#[tokio::main]
async fn main() -> Result<()> {
    let listen: std::net::SocketAddr = std::env::var("AONSOKU_COORD_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:3000".into())
        .parse()
        .expect("valid AONSOKU_COORD_LISTEN");

    let data_dir = std::env::var("AONSOKU_COORD_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::env::current_dir().unwrap().join("data"));

    let stable_key = std::env::var("AONSOKU_COORD_STABLE_KEY").unwrap_or_else(|_| {
        eprintln!("WARNING: AONSOKU_COORD_STABLE_KEY not set; using ephemeral key. Account lookups will not survive restart.");
        "ephemeral-dev-key-do-not-use-in-production".to_string()
    });

    if !data_dir.exists() {
        std::fs::create_dir_all(&data_dir)?;
    }

    let config = Config::new(listen, data_dir, stable_key);
    aonsoku_coordination_server::server::run(config).await
}
