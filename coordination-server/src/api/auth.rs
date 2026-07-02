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
use crate::verification::SubsonicProof;

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
    // 1. Consume the one-time challenge. The challenge binds the
    //    normalised identity URL and canonical username that were declared
    //    when the challenge was issued; the register request must match
    //    those values exactly (design §6.2). This prevents an attacker from
    //    obtaining a challenge for one identity and then registering with a
    //    different identity (e.g. to redirect the SSRF-sensitive verification
    //    request to an internal address).
    let consumed = state
        .repos
        .challenges
        .consume(body.challenge_id)
        .await
        .map_err(map_err)?;

    // 2. Verify the request body matches the challenge binding.
    let request_normalised =
        normalise_identity_url(&body.identity_url, state.config.ssrf.allow_http)
            .map_err(map_err)?;
    let request_canonical = canonicalise_username(&body.username);
    if request_normalised != consumed.normalised_identity {
        return Err(map_err(CoordinationError::new(
            ErrorCode::ChallengeExpired,
            "identity_url does not match the challenge",
        )));
    }
    if request_canonical != consumed.normalised_username {
        return Err(map_err(CoordinationError::new(
            ErrorCode::ChallengeExpired,
            "username does not match the challenge",
        )));
    }

    // 3. Verify credentials against the identity URL. Use the challenge-bound
    //    values (which now equal the request values) so account lookup is
    //    anchored to the challenge, not the raw request body. The proof
    //    username remains the original (un-canonicalised) form required by
    //    Subsonic ping.
    let normalised = consumed.normalised_identity;
    let canonical_user = consumed.normalised_username;
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
    state
        .verifier
        .verify(&normalised, &proof, state.config.ssrf_policy())
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

    crate::api::devices::broadcast_device_list(&state, account.id).await;

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
#[serde(rename_all = "camelCase")]
pub struct TokenRefreshRequest {
    pub device_id: Uuid,
    pub refresh_token: String,
    pub challenge_id: Option<Uuid>,
    pub identity_url: Option<String>,
    pub username: Option<String>,
    pub auth_mode: Option<String>,
    pub token: Option<String>,
    pub salt: Option<String>,
    pub password: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
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
    let refresh_hash_valid =
        crate::storage::tokens::verify_hash_equals(&provided_hash, &device.refresh_token_hash);
    let refresh_active = crate::auth::refresh_token_active(
        device.refresh_token_last_used_at,
        state.config.refresh_token_max_age,
        chrono::Utc::now(),
    );

    if !refresh_hash_valid || !refresh_active {
        if has_recovery_proof(&body) {
            recover_refresh_token(&state, &body, &device).await?;
        } else {
            let reason = if refresh_hash_valid {
                "refresh token expired"
            } else {
                "invalid refresh token"
            };
            return Err(map_err(CoordinationError::new(
                ErrorCode::AuthenticationFailed,
                reason,
            )));
        }
    }

    // Rotate: issue a new refresh token, update hash + family + last_used.
    Ok(Json(
        issue_rotated_tokens(&state, device.id, device.account_id).await?,
    ))
}

fn has_recovery_proof(body: &TokenRefreshRequest) -> bool {
    body.challenge_id.is_some()
        || body.identity_url.is_some()
        || body.username.is_some()
        || body.auth_mode.is_some()
        || body.token.is_some()
        || body.salt.is_some()
        || body.password.is_some()
}

async fn recover_refresh_token(
    state: &AppState,
    body: &TokenRefreshRequest,
    device: &crate::storage::models::Device,
) -> Result<(), (StatusCode, Json<ApiError>)> {
    let challenge_id = body.challenge_id.ok_or_else(|| {
        map_err(CoordinationError::new(
            ErrorCode::BadMessage,
            "challengeId is required for refresh recovery",
        ))
    })?;
    let identity_url = body.identity_url.as_deref().ok_or_else(|| {
        map_err(CoordinationError::new(
            ErrorCode::BadMessage,
            "identityUrl is required for refresh recovery",
        ))
    })?;
    let username = body.username.as_deref().ok_or_else(|| {
        map_err(CoordinationError::new(
            ErrorCode::BadMessage,
            "username is required for refresh recovery",
        ))
    })?;
    let auth_mode = body.auth_mode.as_deref().ok_or_else(|| {
        map_err(CoordinationError::new(
            ErrorCode::BadMessage,
            "authMode is required for refresh recovery",
        ))
    })?;

    let consumed = state
        .repos
        .challenges
        .consume(challenge_id)
        .await
        .map_err(map_err)?;

    // Verify the request body matches the challenge binding (design §6.2),
    // mirroring post_register. The challenge-bound values anchor account
    // lookup; the request body must agree.
    let request_normalised =
        normalise_identity_url(identity_url, state.config.ssrf.allow_http).map_err(map_err)?;
    let request_canonical = canonicalise_username(username);
    if request_normalised != consumed.normalised_identity {
        return Err(map_err(CoordinationError::new(
            ErrorCode::ChallengeExpired,
            "identity_url does not match the challenge",
        )));
    }
    if request_canonical != consumed.normalised_username {
        return Err(map_err(CoordinationError::new(
            ErrorCode::ChallengeExpired,
            "username does not match the challenge",
        )));
    }

    let normalised = consumed.normalised_identity;
    let canonical_user = consumed.normalised_username;
    let proof = match auth_mode {
        "token" => SubsonicProof::Token {
            username: username.to_string(),
            token: body.token.clone().unwrap_or_default(),
            salt: body.salt.clone().unwrap_or_default(),
        },
        "password" => SubsonicProof::Password {
            username: username.to_string(),
            password: body.password.clone().unwrap_or_default(),
        },
        _ => {
            return Err(map_err(CoordinationError::new(
                ErrorCode::BadMessage,
                "authMode must be 'token' or 'password'",
            )));
        }
    };

    state
        .verifier
        .verify(&normalised, &proof, state.config.ssrf_policy())
        .await
        .map_err(map_err)?;

    let lookup_key = account_lookup_key(&state.config.stable_key, &normalised, &canonical_user);
    let account = state
        .repos
        .accounts
        .find_by_lookup_key(&lookup_key)
        .await
        .map_err(map_err)?
        .ok_or_else(|| CoordinationError::new(ErrorCode::AuthenticationFailed, "account mismatch"))
        .map_err(map_err)?;
    if account.id != device.account_id {
        return Err(map_err(CoordinationError::new(
            ErrorCode::AuthenticationFailed,
            "account mismatch",
        )));
    }
    Ok(())
}

async fn issue_rotated_tokens(
    state: &AppState,
    device_id: Uuid,
    account_id: Uuid,
) -> Result<TokenRefreshResponse, (StatusCode, Json<ApiError>)> {
    let new_refresh = generate_refresh_token();
    let new_hash = hash_refresh_token(&new_refresh);
    state
        .repos
        .devices
        .rotate_refresh_token(device_id, &new_hash, new_uuid(), chrono::Utc::now())
        .await
        .map_err(map_err)?;
    let access_token = sign_access_token(
        &state.config.stable_key,
        device_id,
        account_id,
        state.config.access_token_ttl,
    );
    Ok(TokenRefreshResponse {
        access_token,
        refresh_token: new_refresh,
        expires_in: state.config.access_token_ttl.num_seconds(),
    })
}

/// POST /v1/auth/ws-ticket
///
/// Obtain a one-time WebSocket ticket. Requires a valid access token.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WsTicketRequest {
    #[serde(default)]
    pub device_id: Option<Uuid>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
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
#[serde(rename_all = "camelCase")]
pub struct ChallengeRequest {
    pub identity_url: String,
    pub username: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
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
#[serde(rename_all = "camelCase")]
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
