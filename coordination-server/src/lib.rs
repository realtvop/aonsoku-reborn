//! Aonsoku cross-device coordination server.
//!
//! See `docs/spark/2026-06-20-cross-device-coordination-server-design.md` for
//! the authoritative design document. The server is a single-instance,
//! multi-tenant SQLite-backed Tokio/Axum service that synchronizes Aonsoku
//! playback history, device presence and playback handoff for devices bound
//! to the same Navidrome account.

#![forbid(unsafe_code)]
#![warn(clippy::dbg_macro, clippy::print_stdout, clippy::print_stderr)]

pub mod config;
pub mod errors;
pub mod observability;
pub mod protocol;
pub mod server;
pub mod storage;

pub use config::{Config, DeploymentMode};
pub use errors::{ApiError, CoordinationError, ErrorCode};
