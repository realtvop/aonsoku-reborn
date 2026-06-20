//! Realtime WebSocket protocol (design §9, §10).
//!
//! The WebSocket endpoint at `/v1/realtime` handles:
//! - Hello handshake with capability negotiation and ticket auth
//! - Heartbeat (15s) with offline detection (45s grace)
//! - Snapshot publish/subscribe (observers receive projections)
//! - Remote command routing (B → server → A)
//! - Handoff candidate request / target ready / relinquish
//!
//! Connection state lives in an in-memory `ConnectionRegistry`; the server
//! recovers presence and sessions from SQLite on restart (design §14).

pub mod conn;
pub mod registry;

pub use conn::handle_ws;
pub use registry::{ConnectionRegistry, DeviceConnection};
