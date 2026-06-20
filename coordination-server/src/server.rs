//! Axum application builder and HTTP routes.
//!
//! The server exposes:
//! - `/healthz` — liveness (process up)
//! - `/readyz` — readiness (migrations applied, DB reachable)
//! - `/v1/*` — versioned HTTP API (auth, devices, history) — wired in later steps
//! - WebSocket endpoint at `/v1/realtime` — wired in later steps

use std::sync::Arc;

use axum::{extract::State, http::StatusCode, response::Json, routing::get, Router};
use serde_json::json;
use sqlx::SqlitePool;
use tower_http::{cors::CorsLayer, limit::RequestBodyLimitLayer, trace::TraceLayer};

use crate::config::Config;
use crate::errors::{ApiError, CoordinationError};
use crate::storage::sqlite::SqliteRepositories;

/// Shared application state.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub pool: SqlitePool,
    pub repos: SqliteRepositories,
    ready: Arc<std::sync::atomic::AtomicBool>,
}

impl AppState {
    pub fn new(config: Arc<Config>, pool: SqlitePool, repos: SqliteRepositories) -> Self {
        Self {
            config,
            pool,
            repos,
            ready: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    pub fn mark_ready(&self) {
        self.ready.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn mark_not_ready(&self) {
        self.ready.store(false, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn is_ready(&self) -> bool {
        self.ready.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Build the Axum router.
pub fn build_router(state: AppState) -> Router {
    let v1 = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz));

    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .nest("/v1", v1)
        .layer(RequestBodyLimitLayer::new(
            state.config.max_message_bytes as usize,
        ))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn readyz(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ApiError>)> {
    if !state.is_ready() {
        let err = CoordinationError::not_ready();
        return Err((StatusCode::SERVICE_UNAVAILABLE, Json(ApiError::from(&err))));
    }
    // Ping the database as a real readiness check.
    let res = sqlx::query("SELECT 1").execute(&state.pool).await;
    if res.is_err() {
        let err = CoordinationError::internal("database unreachable");
        return Err((StatusCode::SERVICE_UNAVAILABLE, Json(ApiError::from(&err))));
    }
    Ok(Json(json!({ "status": "ready" })))
}

/// Boot the server: open the pool, run migrations, mark ready, listen.
pub async fn run(config: Config) -> anyhow::Result<()> {
    crate::observability::init_logging();
    let pool = crate::storage::open_pool(&config.database_url).await?;
    crate::storage::run_migrations(&pool).await?;
    let repos = SqliteRepositories::new(pool.clone());
    let config = Arc::new(config);
    let state = AppState::new(config.clone(), pool.clone(), repos);
    state.mark_ready();

    let router = build_router(state);
    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    tracing::info!(addr = %config.listen, "coordination server listening");
    axum::serve(listener, router).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    async fn setup_state() -> (tempfile::TempDir, AppState) {
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

    #[tokio::test]
    async fn healthz_returns_ok() {
        let (_dir, state) = setup_state().await;
        let app = build_router(state);
        let resp = tower::ServiceExt::oneshot(
            app,
            axum::http::Request::builder()
                .uri("/healthz")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_ok_when_ready() {
        let (_dir, state) = setup_state().await;
        let app = build_router(state);
        let resp = tower::ServiceExt::oneshot(
            app,
            axum::http::Request::builder()
                .uri("/readyz")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn readyz_returns_503_when_not_ready() {
        let (_dir, state) = setup_state().await;
        state.mark_not_ready();
        let app = build_router(state);
        let resp = tower::ServiceExt::oneshot(
            app,
            axum::http::Request::builder()
                .uri("/readyz")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}
