//! Access token and refresh token signing/verification (design §6.3).
//!
//! Access tokens are short-lived (15 min) HMAC-signed tokens carrying the
//! device id and expiry. Refresh tokens are opaque random strings stored
//! only as hashes. WebSocket tickets are one-time, 30-second random strings
//! (issued via [`crate::storage::repository::TicketRepository`]).

use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;

use crate::errors::{CoordinationError, ErrorCode};

type HmacSha256 = Hmac<Sha256>;

/// Signed access token payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessTokenClaims {
    pub device_id: Uuid,
    pub account_id: Uuid,
    pub exp: i64,
}

/// Sign an access token. The token is `base64url(claims).base64url(sig)`.
pub fn sign_access_token(
    stable_key: &str,
    device_id: Uuid,
    account_id: Uuid,
    ttl: Duration,
) -> String {
    let claims = AccessTokenClaims {
        device_id,
        account_id,
        exp: (Utc::now() + ttl).timestamp(),
    };
    let payload = serde_json::to_vec(&claims).expect("serialize claims");
    let mut mac = HmacSha256::new_from_slice(stable_key.as_bytes()).expect("hmac key");
    mac.update(&payload);
    let sig = mac.finalize().into_bytes();
    format!("{}.{}", b64url(&payload), b64url(&sig))
}

/// Verify and decode an access token.
pub fn verify_access_token(
    stable_key: &str,
    token: &str,
) -> Result<AccessTokenClaims, CoordinationError> {
    let mut parts = token.split('.');
    let payload_b = parts.next().ok_or_else(|| {
        CoordinationError::new(ErrorCode::AuthenticationFailed, "malformed token")
    })?;
    let sig_b = parts.next().ok_or_else(|| {
        CoordinationError::new(ErrorCode::AuthenticationFailed, "malformed token")
    })?;
    if parts.next().is_some() {
        return Err(CoordinationError::new(
            ErrorCode::AuthenticationFailed,
            "malformed token",
        ));
    }
    let payload = b64url_decode(payload_b)
        .map_err(|_| CoordinationError::new(ErrorCode::AuthenticationFailed, "malformed token"))?;
    let sig = b64url_decode(sig_b)
        .map_err(|_| CoordinationError::new(ErrorCode::AuthenticationFailed, "malformed token"))?;

    let mut mac = HmacSha256::new_from_slice(stable_key.as_bytes()).expect("hmac key");
    mac.update(&payload);
    mac.verify_slice(&sig).map_err(|_| {
        CoordinationError::new(ErrorCode::AuthenticationFailed, "invalid signature")
    })?;

    let claims: AccessTokenClaims = serde_json::from_slice(&payload)
        .map_err(|_| CoordinationError::new(ErrorCode::AuthenticationFailed, "malformed claims"))?;
    if claims.exp < Utc::now().timestamp() {
        return Err(CoordinationError::new(
            ErrorCode::AuthenticationFailed,
            "token expired",
        ));
    }
    Ok(claims)
}

/// Check that a token's claims match an expected device/account.
pub fn claims_match(claims: &AccessTokenClaims, device_id: Uuid, account_id: Uuid) -> bool {
    claims.device_id == device_id && claims.account_id == account_id
}

/// Compute whether a refresh token's last-used time is still within the
/// maximum inactivity window (design §6.3).
pub fn refresh_token_active(
    last_used: Option<DateTime<Utc>>,
    max_age: Duration,
    now: DateTime<Utc>,
) -> bool {
    match last_used {
        Some(t) => now - t <= max_age,
        None => true,
    }
}

fn b64url(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

fn b64url_decode(s: &str) -> Result<Vec<u8>, ()> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(s)
        .map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_and_verify_roundtrip() {
        let dev = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let tok = sign_access_token("key", dev, acc, Duration::seconds(60));
        let claims = verify_access_token("key", &tok).unwrap();
        assert_eq!(claims.device_id, dev);
        assert_eq!(claims.account_id, acc);
    }

    #[test]
    fn expired_token_rejected() {
        let dev = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let tok = sign_access_token("key", dev, acc, Duration::seconds(-10));
        assert!(verify_access_token("key", &tok).is_err());
    }

    #[test]
    fn wrong_key_rejected() {
        let dev = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let tok = sign_access_token("key", dev, acc, Duration::seconds(60));
        assert!(verify_access_token("other", &tok).is_err());
    }

    #[test]
    fn refresh_token_active_respects_max_age() {
        let now = Utc::now();
        assert!(refresh_token_active(
            Some(now - Duration::days(10)),
            Duration::days(90),
            now
        ));
        assert!(!refresh_token_active(
            Some(now - Duration::days(100)),
            Duration::days(90),
            now
        ));
    }
}
