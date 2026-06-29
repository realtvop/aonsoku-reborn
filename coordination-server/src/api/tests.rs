//! Integration tests for the HTTP API layer.
//!
//! These tests exercise the Axum router in-process using `tower::ServiceExt`
//! without spawning a real server. Verification against a live Navidrome
//! instance is out of scope; the `/v1/auth/register` happy path is covered
//! by a mocked verifier in a follow-up test once a verifier abstraction is
//! introduced.

use std::sync::Arc;

use axum::body::to_bytes;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;
use uuid::Uuid;

use crate::config::Config;
use crate::server::{build_router, AppState};
use crate::storage::repository::{AccountRepository, ChallengeRepository, DeviceRepository};
use crate::storage::sqlite::SqliteRepositories;
use crate::storage::tokens::{account_lookup_key, generate_refresh_token, hash_refresh_token};
use crate::verification::{CredentialVerifier, SubsonicProof};

#[derive(Clone)]
struct MockVerifier {
    accepted_username: String,
}

#[async_trait::async_trait]
impl CredentialVerifier for MockVerifier {
    async fn verify(
        &self,
        _normalised_identity: &str,
        proof: &SubsonicProof,
        _policy: &crate::config::SsrfPolicy,
    ) -> Result<(), crate::errors::CoordinationError> {
        if proof.username() == self.accepted_username {
            Ok(())
        } else {
            Err(crate::errors::CoordinationError::new(
                crate::errors::ErrorCode::VerificationFailed,
                "mock verification failed",
            ))
        }
    }
}

async fn setup() -> (tempfile::TempDir, AppState) {
    setup_with_verifier(Arc::new(MockVerifier {
        accepted_username: "alice".into(),
    }))
    .await
}

async fn setup_with_verifier(
    verifier: Arc<dyn CredentialVerifier>,
) -> (tempfile::TempDir, AppState) {
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
    let state = AppState::with_verifier(config, pool, repos, verifier);
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

async fn response_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn seed_device(
    state: &AppState,
    identity_url: &str,
    username: &str,
    refresh_token: &str,
) -> (Uuid, Uuid) {
    let normalised =
        crate::identity::normalise_identity_url(identity_url, state.config.ssrf.allow_http)
            .unwrap();
    let canonical_user = crate::identity::canonicalise_username(username);
    let lookup_key = account_lookup_key(&state.config.stable_key, &normalised, &canonical_user);
    let account = state
        .repos
        .accounts
        .upsert_by_lookup_key(&lookup_key, state.config.default_history_limit)
        .await
        .unwrap();
    let hash = hash_refresh_token(refresh_token);
    let device = state
        .repos
        .devices
        .create(
            account.id,
            "Desktop",
            "web",
            Some("0.1.0"),
            0,
            &hash,
            Uuid::new_v4(),
        )
        .await
        .unwrap();
    (account.id, device.id)
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
        "identityUrl": "not-a-url",
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
        "identityUrl": "https://navidrome.example",
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

#[tokio::test]
async fn token_refresh_rotates_valid_refresh_token() {
    let (_dir, state) = setup().await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "refresh-a",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let json = response_json(resp).await;
    assert!(json["accessToken"].as_str().unwrap().len() > 20);
    assert_ne!(json["refreshToken"].as_str().unwrap(), "refresh-a");
}

#[tokio::test]
async fn token_refresh_rejects_invalid_refresh_without_recovery() {
    let (_dir, state) = setup().await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "wrong",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "authentication_failed");
}

#[tokio::test]
async fn token_refresh_recovers_invalid_refresh_for_same_device() {
    let (_dir, state) = setup().await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "alice",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "wrong",
        "challengeId": challenge,
        "identityUrl": "https://navidrome.example",
        "username": "alice",
        "authMode": "password",
        "password": "enc:616c696365",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let json = response_json(resp).await;
    let new_refresh = json["refreshToken"].as_str().unwrap();
    assert_ne!(new_refresh, "wrong");

    let device = state
        .repos
        .devices
        .find_by_id(device_id)
        .await
        .unwrap()
        .unwrap();
    assert!(crate::storage::tokens::verify_hash_equals(
        &hash_refresh_token(new_refresh),
        &device.refresh_token_hash,
    ));
}

#[tokio::test]
async fn token_recovery_rejects_different_account() {
    let (_dir, state) = setup_with_verifier(Arc::new(MockVerifier {
        accepted_username: "bob".into(),
    }))
    .await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    let _other = seed_device(
        &state,
        "https://navidrome.example",
        "bob",
        &generate_refresh_token(),
    )
    .await;
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "bob",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "wrong",
        "challengeId": challenge,
        "identityUrl": "https://navidrome.example",
        "username": "bob",
        "authMode": "password",
        "password": "enc:626f62",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "authentication_failed");
}

#[tokio::test]
async fn token_recovery_rejects_revoked_device() {
    let (_dir, state) = setup().await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    state.repos.devices.revoke(device_id).await.unwrap();
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "alice",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "wrong",
        "challengeId": challenge,
        "identityUrl": "https://navidrome.example",
        "username": "alice",
        "authMode": "password",
        "password": "enc:616c696365",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "device_revoked");
}

#[tokio::test]
async fn register_rejects_identity_mismatch_with_challenge() {
    let (_dir, state) = setup().await;
    // Challenge issued for one identity...
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "alice",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    // ...but register submitted with a different identity. Must be rejected
    // before verification is attempted (prevents SSRF redirect via challenge
    // swap, design §6.2).
    let body = serde_json::json!({
        "challengeId": challenge,
        "identityUrl": "https://evil.example",
        "username": "alice",
        "authMode": "password",
        "password": "enc:616c696365",
        "deviceName": "Dev",
        "platform": "web",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/register", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "challenge_expired");
}

#[tokio::test]
async fn register_rejects_username_mismatch_with_challenge() {
    let (_dir, state) = setup().await;
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "alice",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    let body = serde_json::json!({
        "challengeId": challenge,
        "identityUrl": "https://navidrome.example",
        "username": "bob",
        "authMode": "password",
        "password": "enc:626f62",
        "deviceName": "Dev",
        "platform": "web",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/register", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "challenge_expired");
}

#[tokio::test]
async fn token_recovery_rejects_identity_mismatch_with_challenge() {
    let (_dir, state) = setup().await;
    let (_account_id, device_id) =
        seed_device(&state, "https://navidrome.example", "alice", "refresh-a").await;
    let challenge = state
        .repos
        .challenges
        .issue(
            "https://navidrome.example/",
            "alice",
            chrono::Duration::seconds(60),
        )
        .await
        .unwrap();
    let body = serde_json::json!({
        "deviceId": device_id,
        "refreshToken": "wrong",
        "challengeId": challenge,
        "identityUrl": "https://evil.example",
        "username": "alice",
        "authMode": "password",
        "password": "enc:616c696365",
    })
    .to_string();
    let resp = send(&state, "POST", "/v1/auth/token", Some(body)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    let json = response_json(resp).await;
    assert_eq!(json["code"], "challenge_expired");
}
