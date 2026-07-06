//! HTTP API (design §5.1, §6, §12.1).
//!
//! All HTTP routes are under `/v1`. Auth flow:
//! - `POST /v1/auth/challenge` — request a one-time registration challenge.
//! - `POST /v1/auth/register` — verify Navidrome credentials and create/bind a device.
//! - `POST /v1/auth/token` — refresh access token using refresh token.
//! - `POST /v1/auth/ws-ticket` — obtain a one-time WebSocket ticket.
//! - `GET  /v1/devices` — list devices for the current account.
//! - `PATCH /v1/devices/{id}` — rename a device.
//! - `DELETE /v1/devices/{id}` — revoke a device.
//! - `GET  /v1/history` — incremental history sync.
//! - `POST /v1/history` — upload history operations.
//! - `POST /v1/history/legacy-import` — one-time legacy history import.
//! - `DELETE /v1/account` — delete coordination data for this account.

pub mod auth;
pub mod devices;
pub mod extract;
pub mod history;

#[cfg(test)]
mod tests;

use axum::{
    routing::{delete, get, patch, post},
    Router,
};

use crate::server::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/auth/challenge", post(auth::post_challenge))
        .route("/auth/register", post(auth::post_register))
        .route("/auth/token", post(auth::post_token))
        .route("/auth/ws-ticket", post(auth::post_ws_ticket))
        .route("/devices", get(devices::list_devices))
        .route(
            "/devices/{id}",
            patch(devices::patch_device).delete(devices::delete_device),
        )
        .route(
            "/history",
            get(history::get_history).post(history::post_history),
        )
        .route("/history/legacy-import", post(history::legacy_import))
        .route("/account", delete(auth::delete_account))
}
