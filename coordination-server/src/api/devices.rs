//! Device management HTTP handlers (design §6.3, §12.1).

use axum::{
    extract::{Json, Path, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::extract::Authenticated;
use crate::errors::{ApiError, CoordinationError};
use crate::server::AppState;
use crate::storage::repository::DeviceRepository;

/// GET /v1/devices
pub async fn list_devices(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> Result<Json<Vec<DeviceDto>>, (StatusCode, Json<ApiError>)> {
    let devices = state
        .repos
        .devices
        .list_for_account(claims.account_id)
        .await
        .map_err(map_err)?;
    Ok(Json(devices.into_iter().map(DeviceDto::from).collect()))
}

/// PATCH /v1/devices/:id
pub async fn patch_device(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchDeviceRequest>,
) -> Result<Json<DeviceDto>, (StatusCode, Json<ApiError>)> {
    let device = state.repos.devices.find_by_id(id).await.map_err(map_err)?;
    match device {
        Some(d) if d.account_id == claims.account_id && d.revoked_at.is_none() => {}
        _ => return Err(map_err(CoordinationError::not_found("device not found"))),
    }
    let updated = state
        .repos
        .devices
        .rename(id, &body.name)
        .await
        .map_err(map_err)?;
    Ok(Json(DeviceDto::from(updated)))
}

/// DELETE /v1/devices/:id
pub async fn delete_device(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    let device = state.repos.devices.find_by_id(id).await.map_err(map_err)?;
    match device {
        Some(d) if d.account_id == claims.account_id => {
            state.repos.devices.revoke(id).await.map_err(map_err)?;
            Ok(StatusCode::NO_CONTENT)
        }
        _ => Err(map_err(CoordinationError::not_found("device not found"))),
    }
}

#[derive(Debug, Serialize)]
pub struct DeviceDto {
    pub id: Uuid,
    pub name: String,
    pub platform: String,
    pub client_version: Option<String>,
    pub capabilities: u32,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub last_online_at: Option<chrono::DateTime<chrono::Utc>>,
    pub revoked_at: Option<chrono::DateTime<chrono::Utc>>,
    pub history_sync_cursor: i64,
    pub legacy_history_imported: bool,
}

impl From<crate::storage::models::Device> for DeviceDto {
    fn from(d: crate::storage::models::Device) -> Self {
        Self {
            id: d.id,
            name: d.name,
            platform: d.platform,
            client_version: d.client_version,
            capabilities: d.capabilities,
            created_at: d.created_at,
            last_online_at: d.last_online_at,
            revoked_at: d.revoked_at,
            history_sync_cursor: d.history_sync_cursor,
            legacy_history_imported: d.legacy_history_imported,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct PatchDeviceRequest {
    pub name: String,
}

fn map_err(e: CoordinationError) -> (StatusCode, Json<ApiError>) {
    let status = StatusCode::from_u16(e.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(ApiError::from(&e)))
}
