//! Integration tests for the HTTP API layer.
//!
//! These tests exercise the Axum router in-process using `tower::ServiceExt`
//! without spawning a real server. Verification against a live Navidrome
//! instance is out of scope; the `/v1/auth/register` happy path is covered
//! by a mocked verifier in a follow-up test once a verifier abstraction is
//! introduced.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use crate::config::Config;
use crate::server::{build_router, AppState};
use crate::storage::sqlite::SqliteRepositories;

async fn setup() -> (tempfile::TempDir, AppState) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite://{}/test.db", dir.path().display());
    let pool = crate::storage::open_pool(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let repos = SqliteRepositories::new(pool.clone());
    let config = Arc::new(Config::new(
        "127.0.0.1:0".parse().unwrap(),
        dir.path().to_path_buf(),
        "stable-key-test".into(),
    ));
    let state = AppState::new(config, pool, repos);
    state.mark_ready();
    (dir, state)
}

async fn send(
    state: &AppState,
    method: &str,
    uri: &str,
    body: Option<String>,
) -> axum::response::Response {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(b) = body {
        builder = builder.header("content-type", "application/json");
        let req = builder.body(Body::from(b)).unwrap();
        build_router(state.clone()).oneshot(req).await.unwrap()
    } else {
        let req = builder.body(Body::empty()).unwrap();
        build_router(state.clone()).oneshot(req).await.unwrap()
    }
}

#[tokio::test]
async fn healthz_works() {
    let (_dir, state) = setup().await;
    let resp = send(&state, "GET", "/healthz", None).await;
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn challenge_requires_valid_identity_url() {
    let (_dir, state) = setup().await;
    let body = serde_json::json!({
        "identity_url": "not-a-url",
        "username": "alice",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/challenge", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn challenge_succeeds_for_https_url() {
    let (_dir, state) = setup().await;
    let body = serde_json::json!({
        "identity_url": "https://navidrome.example",
        "username": "Alice",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/challenge", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn devices_require_authentication() {
    let (_dir, state) = setup().await;
    let resp = send(&state, "GET", "/v1/devices", None).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn history_requires_authentication() {
    let (_dir, state) = setup().await;
    let resp = send(&state, "GET", "/v1/history", None).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn ws_ticket_requires_authentication() {
    let (_dir, state) = setup().await;
    let body = serde_json::json!({}).to_string();
    let resp = send(&state, "POST", "/v1/auth/ws-ticket", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
