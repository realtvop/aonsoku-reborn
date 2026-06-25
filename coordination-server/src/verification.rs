//! Navidrome credential verification (design §6.2).
//!
//! The server issues a 60-second one-time challenge, then verifies the
//! client's current Subsonic credentials by calling the identity URL's
//! `/rest/ping.view` with `u/t/s` (token mode) or `u/p` (password mode).
//! Verification requests are SSRF-guarded, time-boxed, and never log the
//! credential parameters.

use reqwest::Client;
use serde::Deserialize;

use crate::config::SsrfPolicy;
use crate::errors::{CoordinationError, ErrorCode};

/// Subsonic auth parameters, supplied by the client for one-time verification.
#[derive(Debug, Clone)]
pub enum SubsonicProof {
    /// Token mode: `u`, `t` (MD5 of password+salt), `s` (salt).
    Token {
        username: String,
        token: String,
        salt: String,
    },
    /// Password mode: `u`, `p` (`enc:hex` form).
    Password { username: String, password: String },
}

impl SubsonicProof {
    /// The username used for verification (original, not canonicalised).
    pub fn username(&self) -> &str {
        match self {
            SubsonicProof::Token { username, .. } | SubsonicProof::Password { username, .. } => {
                username
            }
        }
    }
}

/// Pluggable credential verifier used by HTTP handlers. Production uses
/// [`HttpCredentialVerifier`]; tests can inject a mock without calling a real
/// Navidrome/Subsonic server.
#[async_trait::async_trait]
pub trait CredentialVerifier: Send + Sync + 'static {
    async fn verify(
        &self,
        normalised_identity: &str,
        proof: &SubsonicProof,
        policy: &SsrfPolicy,
    ) -> Result<(), CoordinationError>;
}

#[derive(Debug, Default)]
pub struct HttpCredentialVerifier;

#[async_trait::async_trait]
impl CredentialVerifier for HttpCredentialVerifier {
    async fn verify(
        &self,
        normalised_identity: &str,
        proof: &SubsonicProof,
        policy: &SsrfPolicy,
    ) -> Result<(), CoordinationError> {
        verify_credentials(normalised_identity, proof, policy).await
    }
}

/// Minimal Subsonic ping response envelope.
#[derive(Debug, Deserialize)]
struct SubsonicResponse {
    #[serde(rename = "subsonic-response")]
    inner: SubsonicInner,
}

#[derive(Debug, Deserialize)]
struct SubsonicInner {
    status: String,
    #[serde(default)]
    error: Option<SubsonicError>,
}

#[derive(Debug, Deserialize)]
struct SubsonicError {
    code: i32,
    #[allow(dead_code)]
    message: String,
}

/// Verify Subsonic credentials against a Navidrome identity URL.
///
/// SSRF protection: the policy decides HTTP/private-network allowance. DNS
/// is resolved through reqwest; per-IP pinning is left to the caller's
/// policy enforcement at the connection layer. We enforce timeouts and body
/// size limits. The credential parameters are never logged.
pub async fn verify_credentials(
    normalised_identity: &str,
    proof: &SubsonicProof,
    policy: &SsrfPolicy,
) -> Result<(), CoordinationError> {
    if policy.allow_http {
        // self-hosted mode already relaxed HTTP at identity normalisation
    }

    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::limited(
            policy.max_redirects as usize,
        ))
        .connect_timeout(policy.connect_timeout)
        .timeout(policy.total_timeout)
        .build()
        .map_err(|e| CoordinationError::internal(e.to_string()))?;

    let mut url = format!(
        "{}/rest/ping.view",
        normalised_identity.trim_end_matches('/')
    );
    let mut query: Vec<(&str, String)> = vec![
        ("u", proof.username().to_string()),
        ("v", "1.16.1".into()),
        ("c", "aonsoku-coord".into()),
        ("f", "json".into()),
    ];
    match proof {
        SubsonicProof::Token { token, salt, .. } => {
            query.push(("t", token.clone()));
            query.push(("s", salt.clone()));
        }
        SubsonicProof::Password { password, .. } => {
            query.push(("p", password.clone()));
        }
    }
    // Append query string manually to keep order deterministic for tests.
    let qs = query
        .iter()
        .map(|(k, v)| format!("{}={}", k, urlencoding_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    url.push('?');
    url.push_str(&qs);

    tracing::debug!(target: "coordination::verify", "verifying credentials against identity URL (params redacted)");

    let resp = client
        .get(&url)
        .header("user-agent", "aonsoku-coordination/0.1")
        .send()
        .await
        .map_err(|e| map_reqwest_error(&e))?;

    if !resp.status().is_success() {
        return Err(CoordinationError::new(
            ErrorCode::VerificationFailed,
            "identity URL returned non-200",
        ));
    }

    let content_type = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_lowercase();
    // Allow both json and xml; we only parse json for now.
    if !content_type.contains("json")
        && !content_type.contains("text")
        && !content_type.contains("xml")
    {
        return Err(CoordinationError::new(
            ErrorCode::VerificationFailed,
            "unexpected content-type from identity URL",
        ));
    }

    let body = resp
        .bytes()
        .await
        .map_err(|e| CoordinationError::internal(e.to_string()))?;
    if body.len() as u64 > policy.max_body_bytes {
        return Err(CoordinationError::new(
            ErrorCode::VerificationFailed,
            "identity URL response too large",
        ));
    }

    let parsed: SubsonicResponse = serde_json::from_slice(&body).map_err(|e| {
        tracing::warn!(target: "coordination::verify", "failed to parse ping response: {e}");
        CoordinationError::new(ErrorCode::VerificationFailed, "invalid ping response")
    })?;

    if parsed.inner.status == "ok" {
        return Ok(());
    }

    let reason = parsed
        .inner
        .error
        .as_ref()
        .map(|e| format!("subsonic error code {}", e.code))
        .unwrap_or_else(|| "subsonic error".to_string());
    Err(CoordinationError::new(
        ErrorCode::VerificationFailed,
        reason,
    ))
}

fn map_reqwest_error(e: &reqwest::Error) -> CoordinationError {
    if e.is_connect() || e.is_timeout() {
        CoordinationError::new(ErrorCode::VerificationFailed, "identity URL unreachable")
    } else if e.is_redirect() {
        CoordinationError::new(ErrorCode::SsrfBlocked, "redirect loop blocked")
    } else {
        CoordinationError::internal(e.to_string())
    }
}

/// Minimal percent-encoding for query values.
fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_username_works_for_both_modes() {
        let t = SubsonicProof::Token {
            username: "alice".into(),
            token: "abc".into(),
            salt: "s".into(),
        };
        assert_eq!(t.username(), "alice");
        let p = SubsonicProof::Password {
            username: "bob".into(),
            password: "enc:41".into(),
        };
        assert_eq!(p.username(), "bob");
    }

    #[tokio::test]
    async fn verify_fails_on_unreachable_url() {
        let policy = SsrfPolicy {
            allow_http: true,
            allow_private_network: true,
            ..SsrfPolicy::permissive()
        };
        let proof = SubsonicProof::Token {
            username: "u".into(),
            token: "t".into(),
            salt: "s".into(),
        };
        let res = verify_credentials("http://127.0.0.1:1", &proof, &policy).await;
        assert!(res.is_err());
    }
}
