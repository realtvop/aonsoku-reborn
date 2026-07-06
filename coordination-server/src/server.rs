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
use crate::handoff::HandoffCoordinator;
use crate::realtime::{ConnectionRegistry, SessionCache};
use crate::storage::sqlite::SqliteRepositories;
use crate::verification::{CredentialVerifier, HttpCredentialVerifier};

/// Shared application state.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub pool: SqlitePool,
    pub repos: SqliteRepositories,
    pub realtime: Arc<ConnectionRegistry>,
    pub handoff: Arc<HandoffCoordinator>,
    pub verifier: Arc<dyn CredentialVerifier>,
    /// In-memory front for `repos.sessions`. Snapshot upserts hit memory;
    /// authoritative transitions and a periodic ticker flush to SQLite
    /// (design §9.2 — debounced persistence).
    pub session_cache: Arc<SessionCache>,
    ready: Arc<std::sync::atomic::AtomicBool>,
}

impl AppState {
    pub fn new(config: Arc<Config>, pool: SqlitePool, repos: SqliteRepositories) -> Self {
        Self::with_verifier(config, pool, repos, Arc::new(HttpCredentialVerifier))
    }

    pub fn with_verifier(
        config: Arc<Config>,
        pool: SqlitePool,
        repos: SqliteRepositories,
        verifier: Arc<dyn CredentialVerifier>,
    ) -> Self {
        let session_cache = Arc::new(SessionCache::new(Arc::new(repos.sessions.clone())));
        Self {
            config,
            pool,
            repos,
            realtime: Arc::new(ConnectionRegistry::new()),
            handoff: Arc::new(HandoffCoordinator::new()),
            verifier,
            session_cache,
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
    let v1 = crate::api::router().route("/realtime", get(crate::realtime::handle_ws));
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

    let router = build_router(state.clone());
    // Spawn the dirty-session flush ticker (design §9.2). Debounced snapshot
    // upserts live in `session_cache`; this task periodically flushes them to
    // SQLite so a crash loses at most `snapshot_flush_interval` of snapshots.
    let flush_state = state.clone();
    let flush_handle = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(flush_state.config.snapshot_flush_interval);
        // Skip the first immediate tick — nothing is dirty at startup.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            match flush_state.session_cache.flush_dirty().await {
                Ok(n) if n > 0 => {
                    tracing::debug!(
                        target: "coordination::session_cache",
                        flushed = n,
                        "flushed dirty sessions to sqlite"
                    );
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!(
                        target: "coordination::session_cache",
                        error = ?e,
                        "dirty-session flush failed"
                    );
                }
            }
        }
    });

    // Spawn the transferred-session GC task (design §11.3). It periodically
    // deletes `transferred` session rows older than `transferred_retention`
    // to bound database growth from repeated handoffs. Goes through the cache
    // so the in-memory map stays consistent with the backing store.
    let gc_state = state.clone();
    let gc_handle = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(gc_state.config.transferred_gc_interval);
        // Skip the first immediate tick so we don't run GC at startup before
        // the server has served any traffic.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let cutoff = chrono::Utc::now() - gc_state.config.transferred_retention;
            match gc_state
                .session_cache
                .delete_transferred_before(cutoff)
                .await
            {
                Ok(n) if n > 0 => {
                    tracing::info!(target: "coordination::gc", removed = n, "gc deleted transferred sessions");
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!(target: "coordination::gc", error = ?e, "transferred-session gc failed");
                }
            }
        }
    });

    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    tracing::info!(addr = %config.listen, "coordination server listening");
    axum::serve(listener, router).await?;
    gc_handle.abort();
    flush_handle.abort();
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
