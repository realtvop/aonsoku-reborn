//! Token utilities: hashing, generation, and timing helpers (design §6.3).
//!
//! We hash refresh tokens before storage, never store raw tokens, and use
//! constant-time comparison to avoid timing leaks.

use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use rand::{distributions::Alphanumeric, Rng};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;

/// Hash a refresh token for storage. The hash is one-way; raw tokens are only
/// ever returned to the client at issuance/rotation time.
pub fn hash_refresh_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

/// Constant-time equality of two hex-encoded hashes.
pub fn verify_hash_equals(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.as_bytes().ct_eq(b.as_bytes()).into()
}

/// Generate a cryptographically-random refresh token (URL-safe).
pub fn generate_refresh_token() -> String {
    let mut rng = rand::thread_rng();
    (0..48).map(|_| rng.sample(Alphanumeric) as char).collect()
}

/// Generate a short single-use WebSocket ticket (design §6.3).
pub fn generate_ws_ticket() -> String {
    let mut rng = rand::thread_rng();
    (0..36).map(|_| rng.sample(Alphanumeric) as char).collect()
}

/// HMAC-SHA256 over a message using the deployment stable key.
pub fn hmac_stable(stable_key: &str, message: &str) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(stable_key.as_bytes()).expect("hmac key");
    mac.update(message.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

/// Derive the account lookup key (design §6.1): HMAC over
/// "normalised_identity||normalised_username".
pub fn account_lookup_key(
    stable_key: &str,
    normalised_identity: &str,
    normalised_username: &str,
) -> String {
    let msg = format!("{normalised_identity}||{normalised_username}");
    hex::encode(hmac_stable(stable_key, &msg))
}

/// Check whether a refresh token is still valid given its last-used time
/// and the configured max age (design §6.3).
pub fn refresh_token_still_valid(
    last_used: Option<DateTime<Utc>>,
    max_age: chrono::Duration,
    now: DateTime<Utc>,
) -> bool {
    match last_used {
        Some(t) => now - t <= max_age,
        None => true,
    }
}

/// Convenience: new UUIDv4.
pub fn new_uuid() -> Uuid {
    Uuid::new_v4()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_stable_and_distinct() {
        let a = hash_refresh_token("abc");
        let b = hash_refresh_token("abc");
        let c = hash_refresh_token("xyz");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert!(verify_hash_equals(&a, &b));
        assert!(!verify_hash_equals(&a, &c));
        assert!(!verify_hash_equals(&a, "short"));
    }

    #[test]
    fn lookup_key_is_stable() {
        let k1 = account_lookup_key("stable", "https://navidrome.example", "alice");
        let k2 = account_lookup_key("stable", "https://navidrome.example", "alice");
        assert_eq!(k1, k2);
        let k3 = account_lookup_key("stable", "https://navidrome.example", "bob");
        assert_ne!(k1, k3);
    }

    #[test]
    fn refresh_token_validity_respects_max_age() {
        let now = Utc::now();
        assert!(refresh_token_still_valid(
            Some(now - chrono::Duration::days(10)),
            chrono::Duration::days(90),
            now
        ));
        assert!(!refresh_token_still_valid(
            Some(now - chrono::Duration::days(100)),
            chrono::Duration::days(90),
            now
        ));
        assert!(refresh_token_still_valid(
            None,
            chrono::Duration::days(90),
            now
        ));
    }
}
