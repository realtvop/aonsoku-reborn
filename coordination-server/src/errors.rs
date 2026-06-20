//! Structured error types and error codes for the coordination protocol.
//!
//! Error codes are stable contract values shared with all clients (design
//! §13). Sensitive material (Navidrome `p`, `t`, `s`, tokens, identity URLs)
//! is never embedded in error messages; the [`Debug`] impl for
//! [`CoordinationError`] only renders the code and a generic reason.

use std::fmt;

/// Stable structured error codes (design §13).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u16)]
pub enum ErrorCode {
    AuthenticationFailed = 1,
    DeviceRevoked = 2,
    TargetOffline = 3,
    UnsupportedMedia = 4,
    SnapshotExpired = 5,
    StaleEpoch = 6,
    HandoffConflict = 7,
    SourceChanged = 8,
    SourcePauseTimeout = 9,
    PayloadTooLarge = 10,
    ProtocolIncompatible = 11,
    RateLimited = 12,
    BadMessage = 13,
    NotFound = 14,
    Forbidden = 15,
    Internal = 16,
    ChallengeExpired = 17,
    TicketExpired = 18,
    InvalidIdentity = 19,
    SsrfBlocked = 20,
    VerificationFailed = 21,
    NotReady = 22,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::AuthenticationFailed => "authentication_failed",
            ErrorCode::DeviceRevoked => "device_revoked",
            ErrorCode::TargetOffline => "target_offline",
            ErrorCode::UnsupportedMedia => "unsupported_media",
            ErrorCode::SnapshotExpired => "snapshot_expired",
            ErrorCode::StaleEpoch => "stale_epoch",
            ErrorCode::HandoffConflict => "handoff_conflict",
            ErrorCode::SourceChanged => "source_changed",
            ErrorCode::SourcePauseTimeout => "source_pause_timeout",
            ErrorCode::PayloadTooLarge => "payload_too_large",
            ErrorCode::ProtocolIncompatible => "protocol_incompatible",
            ErrorCode::RateLimited => "rate_limited",
            ErrorCode::BadMessage => "bad_message",
            ErrorCode::NotFound => "not_found",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::Internal => "internal",
            ErrorCode::ChallengeExpired => "challenge_expired",
            ErrorCode::TicketExpired => "ticket_expired",
            ErrorCode::InvalidIdentity => "invalid_identity",
            ErrorCode::SsrfBlocked => "ssrf_blocked",
            ErrorCode::VerificationFailed => "verification_failed",
            ErrorCode::NotReady => "not_ready",
        }
    }

    pub fn http_status(self) -> u16 {
        use ErrorCode::*;
        match self {
            AuthenticationFailed | ChallengeExpired | TicketExpired | VerificationFailed => 401,
            DeviceRevoked | Forbidden => 403,
            NotFound | TargetOffline => 404,
            RateLimited => 429,
            PayloadTooLarge => 413,
            BadMessage | InvalidIdentity | SsrfBlocked | StaleEpoch | ProtocolIncompatible => 400,
            UnsupportedMedia | SnapshotExpired | SourceChanged | SourcePauseTimeout
            | HandoffConflict => 409,
            NotReady => 503,
            Internal => 500,
        }
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Domain-level error carrying a stable code.
#[derive(thiserror::Error, Clone, Debug)]
pub struct CoordinationError {
    pub code: ErrorCode,
    /// Generic, safe-to-log reason. Must never contain secrets.
    reason: String,
}

impl CoordinationError {
    pub fn new(code: ErrorCode, reason: impl Into<String>) -> Self {
        Self {
            code,
            reason: reason.into(),
        }
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn http_status(&self) -> u16 {
        self.code.http_status()
    }
}

impl fmt::Display for CoordinationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.reason)
    }
}

/// Convenience constructors.
impl CoordinationError {
    pub fn bad_message(reason: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadMessage, reason)
    }
    pub fn not_found(reason: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, reason)
    }
    pub fn forbidden(reason: impl Into<String>) -> Self {
        Self::new(ErrorCode::Forbidden, reason)
    }
    pub fn internal(reason: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, reason)
    }
    pub fn authentication_failed() -> Self {
        Self::new(ErrorCode::AuthenticationFailed, "authentication failed")
    }
    pub fn rate_limited() -> Self {
        Self::new(ErrorCode::RateLimited, "rate limited")
    }
    pub fn payload_too_large() -> Self {
        Self::new(ErrorCode::PayloadTooLarge, "payload too large")
    }
    pub fn not_ready() -> Self {
        Self::new(ErrorCode::NotReady, "service not ready")
    }
}

/// Error surfaced over HTTP/JSON. Always uses the stable code and a generic
/// reason; never embeds secrets.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ApiError {
    pub code: &'static str,
    pub reason: String,
}

impl ApiError {
    pub fn from(err: &CoordinationError) -> Self {
        // Convert the runtime code enum back to a static str. We use a match
        // rather than `as_str` because serde wants a borrowed string with a
        // 'static lifetime for the code field.
        let code: &'static str = match err.code {
            ErrorCode::AuthenticationFailed => "authentication_failed",
            ErrorCode::DeviceRevoked => "device_revoked",
            ErrorCode::TargetOffline => "target_offline",
            ErrorCode::UnsupportedMedia => "unsupported_media",
            ErrorCode::SnapshotExpired => "snapshot_expired",
            ErrorCode::StaleEpoch => "stale_epoch",
            ErrorCode::HandoffConflict => "handoff_conflict",
            ErrorCode::SourceChanged => "source_changed",
            ErrorCode::SourcePauseTimeout => "source_pause_timeout",
            ErrorCode::PayloadTooLarge => "payload_too_large",
            ErrorCode::ProtocolIncompatible => "protocol_incompatible",
            ErrorCode::RateLimited => "rate_limited",
            ErrorCode::BadMessage => "bad_message",
            ErrorCode::NotFound => "not_found",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::Internal => "internal",
            ErrorCode::ChallengeExpired => "challenge_expired",
            ErrorCode::TicketExpired => "ticket_expired",
            ErrorCode::InvalidIdentity => "invalid_identity",
            ErrorCode::SsrfBlocked => "ssrf_blocked",
            ErrorCode::VerificationFailed => "verification_failed",
            ErrorCode::NotReady => "not_ready",
        };
        Self {
            code,
            reason: err.reason().to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_stable_strings() {
        assert_eq!(
            ErrorCode::AuthenticationFailed.as_str(),
            "authentication_failed"
        );
        assert_eq!(ErrorCode::StaleEpoch.as_str(), "stale_epoch");
        assert_eq!(ErrorCode::PayloadTooLarge.http_status(), 413);
    }

    #[test]
    fn api_error_never_carries_secret() {
        let err = CoordinationError::new(
            ErrorCode::VerificationFailed,
            "navidrome verification failed",
        );
        let api = ApiError::from(&err);
        assert_eq!(api.code, "verification_failed");
        assert!(!api.reason.contains("password"));
    }
}
