//! Axum extractors for access-token authentication.
//!
//! The [`Authenticated`] extractor reads the `Authorization: Bearer <token>`
//! header, verifies the HMAC signature, and returns the claims.

use axum::{extract::FromRequestParts, http::request::Parts};
use serde::Serialize;

use crate::auth::{verify_access_token, AccessTokenClaims};
use crate::errors::{ApiError, CoordinationError};
use crate::server::AppState;

/// Extracts and verifies a Bearer access token from the `Authorization` header.
pub struct Authenticated(pub AccessTokenClaims);

impl FromRequestParts<AppState> for Authenticated
where
    AppState: Send + Sync,
{
    type Rejection = (axum::http::StatusCode, axum::Json<ApiError>);

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or_else(|| {
                let e = CoordinationError::authentication_failed();
                (
                    axum::http::StatusCode::from_u16(e.http_status()).unwrap(),
                    axum::Json(ApiError::from(&e)),
                )
            })?;
        let claims = verify_access_token(&state.config.stable_key, token).map_err(|e| {
            (
                axum::http::StatusCode::from_u16(e.http_status()).unwrap(),
                axum::Json(ApiError::from(&e)),
            )
        })?;
        Ok(Authenticated(claims))
    }
}

#[derive(Debug, Serialize)]
pub struct Empty {}
