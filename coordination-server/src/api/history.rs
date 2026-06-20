//! History sync HTTP handlers (design §8).
//!
//! - `GET /v1/history?after_revision=N&limit=L` — incremental pull.
//! - `POST /v1/history` — upload history operations (add/delete/clear).

use axum::{
    extract::{Json, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::extract::Authenticated;
use crate::errors::{ApiError, CoordinationError, ErrorCode};
use crate::server::AppState;
use crate::storage::models::{HistoryEntry, HistoryOperation, HistoryOperationKind};
use crate::storage::repository::{AccountRepository, HistoryRepository};

/// GET /v1/history
pub async fn get_history(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Query(params): Query<HistoryQuery>,
) -> Result<Json<HistoryPullResponse>, (StatusCode, Json<ApiError>)> {
    let limit = params.limit.unwrap_or(100).min(1000) as u32;
    let after = params.after_revision.unwrap_or(0);
    let entries = state
        .repos
        .history
        .list_after(claims.account_id, after, limit)
        .await
        .map_err(map_err)?;
    let tombstones = state
        .repos
        .history
        .list_tombstones_after(claims.account_id, after, limit)
        .await
        .map_err(map_err)?;
    let account = state
        .repos
        .accounts
        .find_by_id(claims.account_id)
        .await
        .map_err(map_err)?
        .ok_or_else(|| CoordinationError::not_found("account not found"))
        .map_err(map_err)?;
    Ok(Json(HistoryPullResponse {
        entries: entries.into_iter().map(HistoryEntryDto::from).collect(),
        tombstones: tombstones
            .into_iter()
            .map(HistoryTombstoneDto::from)
            .collect(),
        history_generation: account.history_generation,
        latest_revision: account.history_revision,
        history_limit: account.history_limit,
    }))
}

/// POST /v1/history
pub async fn post_history(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(body): Json<HistoryPushRequest>,
) -> Result<Json<HistoryPushResponse>, (StatusCode, Json<ApiError>)> {
    let account = state
        .repos
        .accounts
        .find_by_id(claims.account_id)
        .await
        .map_err(map_err)?
        .ok_or_else(|| CoordinationError::not_found("account not found"))
        .map_err(map_err)?;

    let mut results = Vec::with_capacity(body.operations.len());
    for op in body.operations {
        let kind = match op.kind.as_str() {
            "add" => HistoryOperationKind::Add,
            "delete_one" => HistoryOperationKind::DeleteOne,
            "clear" => HistoryOperationKind::Clear,
            "set_limit" => HistoryOperationKind::SetLimit,
            _ => {
                return Err(map_err(CoordinationError::new(
                    ErrorCode::BadMessage,
                    "unknown operation kind",
                )))
            }
        };
        let operation = HistoryOperation {
            operation_id: op.operation_id,
            account_id: claims.account_id,
            kind,
            revision: 0,
            created_at: chrono::Utc::now(),
        };
        match kind {
            HistoryOperationKind::Add => {
                let entry = HistoryEntry {
                    event_id: op.event_id.unwrap_or_else(Uuid::new_v4),
                    account_id: claims.account_id,
                    history_generation: account.history_generation,
                    revision: 0,
                    logical_playback_session_id: op
                        .logical_playback_session_id
                        .unwrap_or_else(Uuid::new_v4),
                    song_id: op.song_id.clone().unwrap_or_default(),
                    song_title: op.song_title.clone(),
                    song_artist: op.song_artist.clone(),
                    song_album: op.song_album.clone(),
                    song_duration: op.song_duration,
                    client_entered_at: op.client_entered_at.unwrap_or_else(chrono::Utc::now),
                    server_clock_offset: op.server_clock_offset,
                    server_received_at: chrono::Utc::now(),
                    deleted: false,
                };
                let rev = state
                    .repos
                    .history
                    .append(&operation, &entry)
                    .await
                    .map_err(map_err)?;
                // Prune to the account-level limit.
                let _ = state
                    .repos
                    .history
                    .prune_to_limit(claims.account_id, account.history_limit)
                    .await;
                results.push(HistoryPushResult {
                    operation_id: op.operation_id,
                    revision: rev,
                    accepted: true,
                    error: None,
                });
            }
            HistoryOperationKind::DeleteOne => {
                let event_id = op.event_id.unwrap_or_else(Uuid::new_v4);
                state
                    .repos
                    .history
                    .delete_one(&operation, event_id)
                    .await
                    .map_err(map_err)?;
                results.push(HistoryPushResult {
                    operation_id: op.operation_id,
                    revision: 0,
                    accepted: true,
                    error: None,
                });
            }
            HistoryOperationKind::Clear => {
                state
                    .repos
                    .history
                    .clear(&operation)
                    .await
                    .map_err(map_err)?;
                results.push(HistoryPushResult {
                    operation_id: op.operation_id,
                    revision: 0,
                    accepted: true,
                    error: None,
                });
            }
            HistoryOperationKind::SetLimit => {
                let limit = op.history_limit.unwrap_or(account.history_limit);
                let clamped = limit.clamp(
                    state.config.min_history_limit,
                    state.config.max_history_limit,
                );
                state
                    .repos
                    .accounts
                    .set_history_limit(claims.account_id, clamped)
                    .await
                    .map_err(map_err)?;
                let _ = state
                    .repos
                    .history
                    .prune_to_limit(claims.account_id, clamped)
                    .await;
                results.push(HistoryPushResult {
                    operation_id: op.operation_id,
                    revision: 0,
                    accepted: true,
                    error: None,
                });
            }
        }
    }
    Ok(Json(HistoryPushResponse { results }))
}

#[derive(Debug, Deserialize)]
pub struct HistoryQuery {
    pub after_revision: Option<i64>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPullResponse {
    pub entries: Vec<HistoryEntryDto>,
    pub tombstones: Vec<HistoryTombstoneDto>,
    pub history_generation: i64,
    pub latest_revision: i64,
    pub history_limit: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntryDto {
    pub event_id: Uuid,
    pub revision: i64,
    pub logical_playback_session_id: Uuid,
    pub song_id: String,
    pub song_title: Option<String>,
    pub song_artist: Option<String>,
    pub song_album: Option<String>,
    pub song_duration: Option<f64>,
    pub client_entered_at: chrono::DateTime<chrono::Utc>,
    pub server_clock_offset: Option<i64>,
    pub server_received_at: chrono::DateTime<chrono::Utc>,
    pub deleted: bool,
}

impl From<HistoryEntry> for HistoryEntryDto {
    fn from(e: HistoryEntry) -> Self {
        Self {
            event_id: e.event_id,
            revision: e.revision,
            logical_playback_session_id: e.logical_playback_session_id,
            song_id: e.song_id,
            song_title: e.song_title,
            song_artist: e.song_artist,
            song_album: e.song_album,
            song_duration: e.song_duration,
            client_entered_at: e.client_entered_at,
            server_clock_offset: e.server_clock_offset,
            server_received_at: e.server_received_at,
            deleted: e.deleted,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryTombstoneDto {
    pub event_id: Uuid,
    pub revision: i64,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

impl From<crate::storage::models::HistoryTombstone> for HistoryTombstoneDto {
    fn from(t: crate::storage::models::HistoryTombstone) -> Self {
        Self {
            event_id: t.event_id,
            revision: t.revision,
            created_at: t.created_at,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPushRequest {
    pub operations: Vec<HistoryOperationInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryOperationInput {
    pub operation_id: Uuid,
    pub kind: String,
    pub event_id: Option<Uuid>,
    pub logical_playback_session_id: Option<Uuid>,
    pub song_id: Option<String>,
    pub song_title: Option<String>,
    pub song_artist: Option<String>,
    pub song_album: Option<String>,
    pub song_duration: Option<f64>,
    pub client_entered_at: Option<chrono::DateTime<chrono::Utc>>,
    pub server_clock_offset: Option<i64>,
    pub history_limit: Option<u32>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPushResponse {
    pub results: Vec<HistoryPushResult>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPushResult {
    pub operation_id: Uuid,
    pub revision: i64,
    pub accepted: bool,
    pub error: Option<String>,
}

fn map_err(e: CoordinationError) -> (StatusCode, Json<ApiError>) {
    let status = StatusCode::from_u16(e.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(ApiError::from(&e)))
}

/// POST /v1/history/legacy-import
///
/// One-time legacy history import (design §8.2).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyImportRequest {
    pub entries: Vec<LegacyEntryInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyEntryInput {
    pub song_id: String,
    pub song_title: Option<String>,
    pub song_artist: Option<String>,
    pub song_album: Option<String>,
    pub song_duration: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyImportResponse {
    pub merged_song_ids: Vec<String>,
    pub is_first_device: bool,
}

pub async fn legacy_import(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(body): Json<LegacyImportRequest>,
) -> Result<Json<LegacyImportResponse>, (StatusCode, Json<ApiError>)> {
    let service = crate::history::HistoryService::new(
        state.repos.accounts.clone(),
        state.repos.devices.clone(),
        state.repos.history.clone(),
    );
    let entries: Vec<crate::legacy_import::LegacyEntry> = body
        .entries
        .into_iter()
        .map(|e| crate::legacy_import::LegacyEntry {
            song_id: e.song_id,
            song_title: e.song_title,
            song_artist: e.song_artist,
            song_album: e.song_album,
            song_duration: e.song_duration,
        })
        .collect();
    let result = service
        .legacy_import(claims.device_id, claims.account_id, entries)
        .await
        .map_err(map_err)?;
    Ok(Json(LegacyImportResponse {
        merged_song_ids: result.merged_song_ids,
        is_first_device: result.is_first_device,
    }))
}
