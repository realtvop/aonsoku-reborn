//! Aonsoku cross-device coordination server binary.

use anyhow::Result;
use aonsoku_coordination_server::config::Config;

#[tokio::main]
async fn main() -> Result<()> {
    let config_path = std::env::var("AONSOKU_COORD_CONFIG")
        .map(std::path::PathBuf::from)
        .ok();
    let config = Config::load(config_path)?;

    if !config.data_dir.exists() {
        std::fs::create_dir_all(&config.data_dir)?;
    }

    aonsoku_coordination_server::server::run(config).await
}
