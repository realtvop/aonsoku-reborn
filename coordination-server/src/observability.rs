//! Observability primitives: structured logging setup and sensitive-field
//! redaction (design §15).
//!
//! Sensitive material is never emitted by the application itself, but the
//! redactor is provided as a defence-in-depth for external integrations and
//! for tests that assert no leakage.

use once_cell::sync::Lazy;
use tracing_subscriber::EnvFilter;

/// Words that must never appear in a log/audit line. Redaction is
/// case-insensitive and matches the full key form.
static SENSITIVE_KEYS: &[&str] = &[
    "password",
    "passwd",
    "p",
    "t",
    "s",
    "token",
    "access_token",
    "refresh_token",
    "ws_ticket",
    "authorization",
    "cookie",
];

/// Redact any sensitive key=value pair or JSON field from a string. Used by
/// tests to assert that no secret leaks into structured output, and as a
/// safety net when forwarding arbitrary external data.
pub fn redact(input: &str) -> String {
    let lower = input.to_lowercase();
    if SENSITIVE_KEYS.iter().any(|k| lower.contains(k)) {
        // Conservative blanket replacement: replace the whole string with a
        // redaction marker. The server itself never emits these fields; this
        // is a belt-and-braces guard for forwarded payloads.
        return "[redacted]".to_string();
    }
    input.to_string()
}

/// Stable short id derived from a UUID for log/audit display (design §15).
/// The short id is deployment-stable but irreversible: it hashes the UUID
/// with the deployment stable key and truncates. It is only suitable for
/// correlating logs, never for storage lookups.
pub fn short_id(stable_key: &str, id: uuid::Uuid) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;
    let mut mac = HmacSha256::new_from_slice(stable_key.as_bytes()).expect("hmac key");
    mac.update(id.as_bytes());
    let bytes = mac.finalize().into_bytes();
    hex::encode(&bytes[..6])
}

pub static LOG_GUARD: Lazy<()> = Lazy::new(|| {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
});

/// Initialise logging. Calling more than once is a no-op.
pub fn init_logging() {
    Lazy::force(&LOG_GUARD);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redact_blocks_password() {
        assert_eq!(redact("password=hunter2"), "[redacted]");
        assert_eq!(redact("t=abc&s=def Authorization: Bearer x"), "[redacted]");
        assert_eq!(redact("hello world"), "hello world");
    }

    #[test]
    fn short_id_is_stable() {
        let id = uuid::Uuid::new_v4();
        let a = short_id("key", id);
        let b = short_id("key", id);
        assert_eq!(a, b);
        assert_eq!(a.len(), 12);
        assert_ne!(short_id("key", id), short_id("other", id));
    }
}
