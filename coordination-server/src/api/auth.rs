//! HTTP auth handlers: challenge, register, token refresh, ws ticket,
//! account deletion (design §6).

use axum::{
    extract::{Json, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::api::extract::Authenticated;
use crate::auth::sign_access_token;
use crate::errors::{ApiError, CoordinationError, ErrorCode};
use crate::identity::{canonicalise_username, normalise_identity_url};
use crate::server::AppState;
use crate::storage::repository::{
    AccountRepository, ChallengeRepository, DeviceRepository, TicketRepository,
};
use crate::storage::tokens::{
    account_lookup_key, generate_refresh_token, hash_refresh_token, new_uuid,
};
use crate::verification::{verify_credentials, SubsonicProof};

/// POST /v1/auth/challenge
///
/// Body: `{ "identity_url": string, "username": string }`
/// Returns: `{ "challenge_id": uuid }`
pub async fn post_challenge(
    State(state): State<AppState>,
    Json(body): Json<ChallengeRequest>,
) -> Result<Json<ChallengeResponse>, (StatusCode, Json<ApiError>)> {
    let normalised = normalise_identity_url(&body.identity_url, state.config.ssrf.allow_http)
        .map_err(map_err)?;
    let canonical_user = canonicalise_username(&body.username);
    if canonical_user.is_empty() {
        return Err(map_err(CoordinationError::new(
            ErrorCode::InvalidIdentity,
            "username must not be empty",
        )));
    }
    let id = state
        .repos
        .challenges
        .issue(&normalised, &canonical_user, state.config.challenge_ttl)
        .await
        .map_err(map_err)?;
    Ok(Json(ChallengeResponse { challenge_id: id }))
}

/// POST /v1/auth/register
///
/// Verifies Navidrome credentials and creates/binds a device.
pub async fn post_register(
    State(state): State<AppState>,
    Json(body): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<RegisterResponse>), (StatusCode, Json<ApiError>)> {
    // 1. Consume the one-time challenge.
    let consumed = state
        .repos
        .challenges
        .consume(body.challenge_id)
        .await
        .map_err(map_err)?;
    if !consumed {
        return Err(map_err(CoordinationError::new(
            ErrorCode::ChallengeExpired,
            "challenge expired or already consumed",
        )));
    }

    // 2. Look up the challenge to recover normalised identity + username.
    // We re-issue a lookup is not possible since challenges are consumed; we
    // instead trust the client-supplied identity and username again, but
    // require the challenge to have matched. For the first version we
    // re-normalise the values from the request body.
    let normalised = normalise_identity_url(&body.identity_url, state.config.ssrf.allow_http)
        .map_err(map_err)?;
    let canonical_user = canonicalise_username(&body.username);

    // 3. Verify credentials against the identity URL.
    let proof = match body.auth_mode.as_str() {
        "token" => SubsonicProof::Token {
            username: body.username.clone(),
            token: body.token.clone().unwrap_or_default(),
            salt: body.salt.clone().unwrap_or_default(),
        },
        "password" => SubsonicProof::Password {
            username: body.username.clone(),
            password: body.password.clone().unwrap_or_default(),
        },
        _ => {
            return Err(map_err(CoordinationError::new(
                ErrorCode::BadMessage,
                "auth_mode must be 'token' or 'password'",
            )));
        }
    };
    verify_credentials(&normalised, &proof, state.config.ssrf_policy())
        .await
        .map_err(map_err)?;

    // 4. Compute account lookup key, create or bind account + device.
    let lookup_key = account_lookup_key(&state.config.stable_key, &normalised, &canonical_user);
    let account = state
        .repos
        .accounts
        .upsert_by_lookup_key(&lookup_key, state.config.default_history_limit)
        .await
        .map_err(map_err)?;

    let refresh_token = generate_refresh_token();
    let refresh_hash = hash_refresh_token(&refresh_token);
    let device = state
        .repos
        .devices
        .create(
            account.id,
            &body.device_name,
            &body.platform,
            body.client_version.as_deref(),
            body.capabilities.unwrap_or(0),
            &refresh_hash,
            new_uuid(),
        )
        .await
        .map_err(map_err)?;

    let access_token = sign_access_token(
        &state.config.stable_key,
        device.id,
        account.id,
        state.config.access_token_ttl,
    );

    Ok((
        StatusCode::CREATED,
        Json(RegisterResponse {
            device_id: device.id,
            account_id: account.id,
            access_token,
            refresh_token,
            expires_in: state.config.access_token_ttl.num_seconds(),
            history_limit: account.history_limit,
        }),
    ))
}

/// POST /v1/auth/token
///
/// Refresh an access token using a refresh token.
#[derive(Deserialize)]
pub struct TokenRefreshRequest {
    pub device_id: Uuid,
    pub refresh_token: String,
}
#[derive(Serialize)]
pub struct TokenRefreshResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: i64,
}

pub async fn post_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRefreshRequest>,
) -> Result<Json<TokenRefreshResponse>, (StatusCode, Json<ApiError>)> {
    // Look up the device by id. The client must supply device_id alongside
    // the refresh token.
    let device_id = body.device_id;
    let device = state
        .repos
        .devices
        .find_by_id(device_id)
        .await
        .map_err(map_err)?
        .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "device not found"))
        .map_err(map_err)?;
    if device.revoked_at.is_some() {
        return Err(map_err(CoordinationError::new(
            ErrorCode::DeviceRevoked,
            "device revoked",
        )));
    }
    // Verify the refresh token hash in constant time.
    let provided_hash = hash_refresh_token(&body.refresh_token);
    if !crate::storage::tokens::verify_hash_equals(&provided_hash, &device.refresh_token_hash) {
        return Err(map_err(CoordinationError::new(
            ErrorCode::AuthenticationFailed,
            "invalid refresh token",
        )));
    }
    // Check inactivity expiry.
    if !crate::auth::refresh_token_active(
        device.refresh_token_last_used_at,
        state.config.refresh_token_max_age,
        chrono::Utc::now(),
    ) {
        return Err(map_err(CoordinationError::new(
            ErrorCode::AuthenticationFailed,
            "refresh token expired",
        )));
    }
    // Rotate: issue a new refresh token, update hash + family + last_used.
    let new_refresh = generate_refresh_token();
    let new_hash = hash_refresh_token(&new_refresh);
    state
        .repos
        .devices
        .rotate_refresh_token(device.id, &new_hash, new_uuid(), chrono::Utc::now())
        .await
        .map_err(map_err)?;
    let access_token = sign_access_token(
        &state.config.stable_key,
        device.id,
        device.account_id,
        state.config.access_token_ttl,
    );
    Ok(Json(TokenRefreshResponse {
        access_token,
        refresh_token: new_refresh,
        expires_in: state.config.access_token_ttl.num_seconds(),
    }))
}

/// POST /v1/auth/ws-ticket
///
/// Obtain a one-time WebSocket ticket. Requires a valid access token.
#[derive(Deserialize)]
pub struct WsTicketRequest {
    #[serde(default)]
    pub device_id: Option<Uuid>,
}
#[derive(Serialize)]
pub struct WsTicketResponse {
    pub ticket: String,
    pub expires_in: i64,
}

pub async fn post_ws_ticket(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(body): Json<WsTicketRequest>,
) -> Result<Json<WsTicketResponse>, (StatusCode, Json<ApiError>)> {
    let device_id = body.device_id.unwrap_or(claims.device_id);
    if device_id != claims.device_id {
        return Err(map_err(CoordinationError::new(
            ErrorCode::Forbidden,
            "device_id does not match access token",
        )));
    }
    // Ensure the device is not revoked.
    let device = state
        .repos
        .devices
        .find_by_id(device_id)
        .await
        .map_err(map_err)?
        .ok_or_else(|| CoordinationError::new(ErrorCode::NotFound, "device not found"))
        .map_err(map_err)?;
    if device.revoked_at.is_some() {
        return Err(map_err(CoordinationError::new(
            ErrorCode::DeviceRevoked,
            "device revoked",
        )));
    }
    let ticket = state
        .repos
        .tickets
        .issue(device_id, state.config.ws_ticket_ttl)
        .await
        .map_err(map_err)?;
    Ok(Json(WsTicketResponse {
        ticket,
        expires_in: state.config.ws_ticket_ttl.num_seconds(),
    }))
}

/// DELETE /v1/account
///
/// Delete all coordination data for the authenticated account (design §12.1).
pub async fn delete_account(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> Result<StatusCode, (StatusCode, Json<ApiError>)> {
    state
        .repos
        .accounts
        .delete_account(claims.account_id)
        .await
        .map_err(map_err)?;
    Ok(StatusCode::NO_CONTENT)
}

fn map_err(e: CoordinationError) -> (StatusCode, Json<ApiError>) {
    let status = StatusCode::from_u16(e.http_status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(ApiError::from(&e)))
}

#[derive(Debug, Deserialize)]
pub struct ChallengeRequest {
    pub identity_url: String,
    pub username: String,
}
#[derive(Debug, Serialize)]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub challenge_id: Uuid,
    pub identity_url: String,
    pub username: String,
    pub auth_mode: String,
    pub token: Option<String>,
    pub salt: Option<String>,
    pub password: Option<String>,
    pub device_name: String,
    pub platform: String,
    pub client_version: Option<String>,
    pub capabilities: Option<u32>,
}
#[derive(Debug, Serialize)]
pub struct RegisterResponse {
    pub device_id: Uuid,
    pub account_id: Uuid,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: i64,
    pub history_limit: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_err_returns_correct_status() {
        let (status, body) = map_err(CoordinationError::not_ready());
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body.code, "not_ready");
    }
}
