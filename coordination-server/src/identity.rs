//! Identity URL normalisation and username canonicalisation (design §6.1).
//!
//! The identity URL is the Navidrome URL the coordination server actually
//! verifies credentials against. Media URLs used by each device for playback
//! do not participate in account identification.
//!
//! Normalisation rules (design §6.1):
//! - protocol and host lower-cased
//! - remove default ports and trailing slash
//! - keep non-default ports and non-root paths
//! - reject userinfo, query, fragment
//! - do not attempt URL alias discovery

use url::Url;

use crate::errors::{CoordinationError, ErrorCode};

/// Normalise an identity URL. Returns a stable string suitable for HMAC
/// account lookup key derivation.
pub fn normalise_identity_url(raw: &str, allow_http: bool) -> Result<String, CoordinationError> {
    let parsed = Url::parse(raw).map_err(|_| {
        CoordinationError::new(
            ErrorCode::InvalidIdentity,
            "identity url is not a valid URL",
        )
    })?;

    let scheme = parsed.scheme().to_lowercase();
    if scheme != "https" && !(allow_http && scheme == "http") {
        return Err(CoordinationError::new(
            ErrorCode::InvalidIdentity,
            if allow_http {
                "identity url must be http or https"
            } else {
                "identity url must be https"
            },
        ));
    }

    if !parsed.username().is_empty() {
        return Err(CoordinationError::new(
            ErrorCode::InvalidIdentity,
            "identity url must not contain userinfo",
        ));
    }
    if parsed.query().is_some() {
        return Err(CoordinationError::new(
            ErrorCode::InvalidIdentity,
            "identity url must not contain a query string",
        ));
    }
    if parsed.fragment().is_some() {
        return Err(CoordinationError::new(
            ErrorCode::InvalidIdentity,
            "identity url must not contain a fragment",
        ));
    }

    let host = parsed.host_str().ok_or_else(|| {
        CoordinationError::new(ErrorCode::InvalidIdentity, "identity url must have a host")
    })?;
    let host = host.to_lowercase();

    let port = parsed.port();
    let default_port = if scheme == "https" { 443 } else { 80 };
    let host_port = match port {
        Some(p) if p != default_port => format!("{host}:{p}"),
        _ => host.to_string(),
    };

    let mut path = parsed.path().trim_end_matches('/').to_string();
    if path.is_empty() {
        path = "/".to_string();
    } else if !path.starts_with('/') {
        path = format!("/{path}");
    }

    Ok(format!("{scheme}://{host_port}{path}"))
}

/// Canonicalise a Navidrome username for account lookup (design §6.1):
/// trim, Unicode NFKC normalise, lowercase. This rule targets Navidrome's
/// username semantics and does not promise compatibility with Subsonic
/// servers that distinguish accounts by case alone.
pub fn canonicalise_username(raw: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    raw.trim().nfkc().collect::<String>().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn https_lowercases_and_strips_default_port() {
        let n = normalise_identity_url("HTTPS://Navidrome.Example:443/", false).unwrap();
        assert_eq!(n, "https://navidrome.example/");
    }

    #[test]
    fn keeps_nondefault_port_and_path() {
        let n = normalise_identity_url("https://navidrome.example:8443/music/", false).unwrap();
        assert_eq!(n, "https://navidrome.example:8443/music");
    }

    #[test]
    fn rejects_http_in_strict_mode() {
        let err = normalise_identity_url("http://navidrome.example/", false).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidIdentity);
    }

    #[test]
    fn allows_http_when_permissive() {
        let n = normalise_identity_url("http://navidrome.example/", true).unwrap();
        assert_eq!(n, "http://navidrome.example/");
    }

    #[test]
    fn rejects_userinfo_query_fragment() {
        assert!(normalise_identity_url("https://user:pass@navidrome.example/", false).is_err());
        assert!(normalise_identity_url("https://navidrome.example/?x=1", false).is_err());
        assert!(normalise_identity_url("https://navidrome.example/#frag", false).is_err());
    }

    #[test]
    fn username_canonicalisation() {
        assert_eq!(canonicalise_username("  Alice "), "alice");
        // NFKC: fullwidth 'Ａ' → 'A'
        assert_eq!(canonicalise_username("Ａlice"), "alice");
    }
}
