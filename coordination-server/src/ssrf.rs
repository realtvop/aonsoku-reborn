//! SSRF protection for outbound Navidrome identity verification requests
//! (design §6.4).
//!
//! Public mode rejects loopback, private, link-local, multicast and reserved
//! addresses, requires HTTPS, and pins the resolved IP after DNS lookup.
//! Self-hosted administrators may opt into HTTP and private addresses via
//! [`crate::config::DeploymentMode::SelfHosted`].

use std::net::{IpAddr, ToSocketAddrs};

use crate::config::SsrfPolicy;
use crate::errors::{CoordinationError, ErrorCode};

/// Decide whether a resolved IP is acceptable under the given policy.
pub fn is_address_allowed(policy: &SsrfPolicy, ip: IpAddr) -> Result<(), CoordinationError> {
    if policy.allow_private_network {
        return Ok(());
    }
    match ip {
        IpAddr::V4(v4) => {
            if v4.is_loopback() {
                return Err(blocked("loopback address"));
            }
            if v4.is_private() {
                return Err(blocked("private address"));
            }
            if v4.is_link_local() {
                return Err(blocked("link-local address"));
            }
            if v4.is_multicast() {
                return Err(blocked("multicast address"));
            }
            if v4.is_unspecified() {
                return Err(blocked("unspecified address"));
            }
            // 0.0.0.0/8, 100.64.0.0/10 (CGNAT), 169.254.0.0/16, 192.0.0.0/24,
            // 240.0.0.0/4 (reserved).
            if v4.is_broadcast() {
                return Err(blocked("broadcast address"));
            }
            let octets = v4.octets();
            if octets[0] == 0 {
                return Err(blocked("this-network address"));
            }
            if octets[0] == 100 && (octets[1] & 0xc0) == 64 {
                return Err(blocked("CGNAT address"));
            }
            if octets[0] == 192 && octets[1] == 0 && octets[2] == 0 {
                return Err(blocked("IETF protocol address"));
            }
            if octets[0] >= 240 {
                return Err(blocked("reserved address"));
            }
        }
        IpAddr::V6(v6) => {
            if v6.is_loopback() {
                return Err(blocked("IPv6 loopback"));
            }
            if v6.is_multicast() {
                return Err(blocked("IPv6 multicast"));
            }
            if v6.is_unspecified() {
                return Err(blocked("IPv6 unspecified"));
            }
            // ULA fc00::/7
            let segs = v6.segments();
            if (segs[0] & 0xfe00) == 0xfc00 {
                return Err(blocked("unique local address"));
            }
            // Link-local fe80::/10
            if (segs[0] & 0xffc0) == 0xfe80 {
                return Err(blocked("IPv6 link-local"));
            }
        }
    }
    Ok(())
}

fn blocked(reason: &'static str) -> CoordinationError {
    CoordinationError::new(ErrorCode::SsrfBlocked, reason)
}

/// Resolve `host:port` and return the first IP that satisfies the SSRF
/// policy (design §6.4). DNS is resolved via the standard library
/// `ToSocketAddrs`; each candidate IP is checked with [`is_address_allowed`].
/// Addresses that fail the policy are skipped; if every resolved address is
/// blocked, an `SsrfBlocked` error is returned.
///
/// The caller must use the returned IP for the actual connection (IP pinning)
/// so that DNS rebinding between resolution and connection cannot redirect
/// the request to a blocked address.
pub fn resolve_and_pin(
    policy: &SsrfPolicy,
    host: &str,
    port: u16,
) -> Result<IpAddr, CoordinationError> {
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|_| CoordinationError::new(ErrorCode::SsrfBlocked, "dns resolution failed"))?;
    for ip in addrs.map(|sa| sa.ip()) {
        if is_address_allowed(policy, ip).is_ok() {
            return Ok(ip);
        }
    }
    Err(CoordinationError::new(
        ErrorCode::SsrfBlocked,
        "all resolved addresses blocked by policy",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn strict() -> SsrfPolicy {
        SsrfPolicy::strict()
    }
    fn loose() -> SsrfPolicy {
        SsrfPolicy::permissive()
    }

    #[test]
    fn strict_rejects_loopback() {
        let p = strict();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))).is_err());
    }

    #[test]
    fn strict_rejects_private() {
        let p = strict();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))).is_err());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))).is_err());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1))).is_err());
    }

    #[test]
    fn strict_rejects_link_local_and_cgnat() {
        let p = strict();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(169, 254, 1, 1))).is_err());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))).is_err());
    }

    #[test]
    fn strict_allows_public() {
        let p = strict();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).is_ok());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1))).is_ok());
    }

    #[test]
    fn strict_rejects_ipv6_ula_and_loopback() {
        let p = strict();
        assert!(is_address_allowed(&p, "::1".parse().unwrap()).is_err());
        assert!(is_address_allowed(&p, "fc00::1".parse().unwrap()).is_err());
        assert!(is_address_allowed(&p, "fe80::1".parse().unwrap()).is_err());
    }

    #[test]
    fn permissive_allows_all() {
        let p = loose();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))).is_ok());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))).is_ok());
    }

    #[test]
    fn strict_rejects_zero_and_reserved() {
        let p = strict();
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(0, 0, 0, 1))).is_err());
        assert!(is_address_allowed(&p, IpAddr::V4(Ipv4Addr::new(240, 0, 0, 1))).is_err());
        let _ = Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0);
    }

    #[test]
    fn resolve_and_pin_rejects_loopback_under_strict() {
        // localhost resolves to 127.0.0.1 (and possibly ::1), both blocked.
        let p = strict();
        let res = resolve_and_pin(&p, "localhost", 443);
        assert!(res.is_err(), "strict policy must reject localhost");
        let err = res.unwrap_err();
        assert_eq!(err.code, ErrorCode::SsrfBlocked);
    }

    #[test]
    fn resolve_and_pin_allows_loopback_under_permissive() {
        let p = loose();
        let res = resolve_and_pin(&p, "localhost", 443);
        assert!(res.is_ok(), "permissive policy must allow localhost");
        let ip = res.unwrap();
        assert!(ip.is_loopback());
    }

    #[test]
    fn resolve_and_pin_fails_on_unresolvable_host() {
        // .invalid is a reserved TLD (RFC 2606) that must not resolve.
        let p = loose();
        let res = resolve_and_pin(&p, "coordination-ssrf-probe.invalid", 443);
        assert!(res.is_err());
        assert_eq!(res.unwrap_err().code, ErrorCode::SsrfBlocked);
    }
}
