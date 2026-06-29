//! Navidrome credential verification (design §6.2).
//!
//! The server issues a 60-second one-time challenge, then verifies the
//! client's current Subsonic credentials by calling the identity URL's
//! `/rest/ping.view` with `u/t/s` (token mode) or `u/p` (password mode).
//! Verification requests are SSRF-guarded (design §6.4): the resolved IP is
//! checked against the policy and pinned for the connection, redirects are
//! followed manually with per-hop re-validation, and timeouts/body size are
//! enforced. Credential parameters are never logged.

use std::net::SocketAddr;

use reqwest::Client;
use serde::Deserialize;

use crate::config::SsrfPolicy;
use crate::errors::{CoordinationError, ErrorCode};
use crate::ssrf::resolve_and_pin;

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
/// SSRF protection (design §6.4): for every hop (initial request and each
/// redirect), the host is resolved, each candidate IP is checked with
/// [`crate::ssrf::is_address_allowed`], and the first policy-compliant IP is
/// pinned for the connection via `ClientBuilder::resolve` so DNS rebinding
/// cannot redirect the request to a blocked address mid-connection. The
/// scheme is re-checked at every hop. Redirects are followed manually (the
/// reqwest built-in redirect policy does not expose intermediate IPs for
/// validation). Timeouts and body size limits are enforced. Credential
/// parameters are never logged.
pub async fn verify_credentials(
    normalised_identity: &str,
    proof: &SubsonicProof,
    policy: &SsrfPolicy,
) -> Result<(), CoordinationError> {
    // Build the initial ping URL with query parameters.
    let mut url = url::Url::parse(normalised_identity).map_err(|_| {
        CoordinationError::new(ErrorCode::InvalidIdentity, "identity url is not a valid URL")
    })?;
    url.set_path(&format!("{}/rest/ping.view", url.path().trim_end_matches('/')));
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
    {
        let mut q = url.query_pairs_mut();
        for (k, v) in &query {
            q.append_pair(k, v);
        }
    }

    tracing::debug!(target: "coordination::verify", "verifying credentials against identity URL (params redacted)");

    let mut hops = 0u32;
    loop {
        // Per-hop scheme check (design §6.4 — re-check after each redirect).
        let scheme = url.scheme();
        if scheme != "https" && !(policy.allow_http && scheme == "http") {
            return Err(CoordinationError::new(
                ErrorCode::SsrfBlocked,
                "identity url scheme not allowed",
            ));
        }
        let host = url.host_str().ok_or_else(|| {
            CoordinationError::new(ErrorCode::SsrfBlocked, "identity url has no host")
        })?;
        let port = url
            .port_or_known_default()
            .unwrap_or(if scheme == "https" { 443 } else { 80 });

        // Resolve and pin the IP through the SSRF policy.
        let pinned_ip = resolve_and_pin(policy, host, port)?;

        // Build a client that pins the resolved IP for this host, so DNS
        // rebinding between resolution and connection cannot bypass the
        // policy. A fresh client is built per hop because the pin is
        // host-specific.
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .resolve(host, SocketAddr::new(pinned_ip, 0))
            .connect_timeout(policy.connect_timeout)
            .timeout(policy.total_timeout)
            .build()
            .map_err(|e| CoordinationError::internal(e.to_string()))?;

        let resp = client
            .get(url.as_str())
            .header("user-agent", "aonsoku-coordination/0.1")
            .send()
            .await
            .map_err(|e| map_reqwest_error(&e))?;

        if resp.status().is_redirection() {
            hops += 1;
            if hops > policy.max_redirects {
                return Err(CoordinationError::new(
                    ErrorCode::SsrfBlocked,
                    "too many redirects",
                ));
            }
            let location = resp
                .headers()
                .get("location")
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| {
                    CoordinationError::new(ErrorCode::SsrfBlocked, "redirect without location")
                })?;
            url = url.join(location).map_err(|_| {
                CoordinationError::new(ErrorCode::SsrfBlocked, "invalid redirect location")
            })?;
            // Re-enter the loop to re-validate scheme, host, and IP for the
            // redirect target.
            continue;
        }

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
        return Err(CoordinationError::new(
            ErrorCode::VerificationFailed,
            reason,
        ));
    }
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

    #[tokio::test]
    async fn verify_blocks_loopback_under_strict_policy() {
        // Strict SSRF policy must reject localhost before any connection is
        // attempted (design §6.4). The error must be SsrfBlocked, not a
        // verification failure or unreachable error.
        let policy = SsrfPolicy::strict();
        let proof = SubsonicProof::Token {
            username: "u".into(),
            token: "t".into(),
            salt: "s".into(),
        };
        let res = verify_credentials("https://localhost", &proof, &policy).await;
        assert!(res.is_err(), "strict policy must block localhost");
        assert_eq!(res.unwrap_err().code, ErrorCode::SsrfBlocked);
    }

    #[tokio::test]
    async fn verify_blocks_http_scheme_under_strict_policy() {
        // Strict policy only allows https; http must be rejected at the
        // per-hop scheme check before resolution.
        let policy = SsrfPolicy::strict();
        let proof = SubsonicProof::Token {
            username: "u".into(),
            token: "t".into(),
            salt: "s".into(),
        };
        let res = verify_credentials("http://navidrome.example", &proof, &policy).await;
        assert!(res.is_err());
        assert_eq!(res.unwrap_err().code, ErrorCode::SsrfBlocked);
    }
}
