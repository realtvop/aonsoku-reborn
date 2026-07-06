//! Legacy history import (design §8.2).
//!
//! Existing client history is a bare list of `ISong` arrays with no real
//! timestamps, event IDs, or playback session IDs. Each device may perform a
//! legacy import only once:
//!
//! 1. The first connected device establishes the initial server-side
//!    sequence in its existing order.
//! 2. Subsequent devices match their old sequence against the server's
//!    sequence by longest common subsequence (LCS) on song ID.
//! 3. Matched items are treated as shared history; unmatched items are
//!    merged into a shortest common supersequence.
//! 4. Within a branch, device creation time and device ID are the stable
//!    tie-breaker.
//! 5. After merging, the account-level history limit is applied, and the
//!    device is marked as having completed its legacy import.
//!
//! The algorithm merges most shared history between devices but cannot
//! perfectly distinguish repeated plays of the same song in old lists. This
//! limitation only affects pre-upgrade data; new events use stable IDs.

use uuid::Uuid;

/// A single legacy entry: just a song ID with minimal display metadata.
#[derive(Debug, Clone)]
pub struct LegacyEntry {
    pub song_id: String,
    pub song_title: Option<String>,
    pub song_artist: Option<String>,
    pub song_album: Option<String>,
    pub song_duration: Option<f64>,
}

/// Merge a device's legacy list into the server's current sequence using LCS
/// on song ID, producing a merged supersequence.
///
/// The `server` list is ordered newest-first (matching the client's existing
/// representation). The result is also newest-first.
pub fn merge_legacy(server: &[String], device: &[String]) -> Vec<String> {
    if server.is_empty() {
        return device.to_vec();
    }
    if device.is_empty() {
        return server.to_vec();
    }
    // Compute LCS of the two sequences (both newest-first).
    let lcs = lcs(server, device);
    if lcs.is_empty() {
        // No common subsequence: concatenate device (newer) then server,
        // deduplicating consecutive song IDs.
        let mut merged = device.to_vec();
        merged.extend_from_slice(server);
        return dedup_consecutive(merged);
    }
    // Merge: walk both sequences, emitting common items in lockstep and
    // unmatched items in their relative order. Since both are newest-first,
    // the device's unmatched items that appear before a common item are
    // treated as newer than that common item.
    supersequence(server, device, &lcs)
}

/// Compute the longest common subsequence of two string slices.
fn lcs(a: &[String], b: &[String]) -> Vec<String> {
    let m = a.len();
    let n = b.len();
    let mut dp = vec![vec![0usize; n + 1]; m + 1];
    for i in 1..=m {
        for j in 1..=n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = dp[i - 1][j].max(dp[i][j - 1]);
            }
        }
    }
    // Backtrack to collect the LCS.
    let mut result = Vec::with_capacity(dp[m][n]);
    let (mut i, mut j) = (m, n);
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            result.push(a[i - 1].clone());
            i -= 1;
            j -= 1;
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    result.reverse();
    result
}

/// Merge two sequences using the given LCS as common anchors. Unmatched
/// items from each side are emitted in their relative order. Items from
/// `device` that appear before a common anchor are emitted before it (treated
/// as newer), items from `server` before a common anchor are emitted before
/// it too. To produce a deterministic supersequence, device-side unmatched
/// items take precedence over server-side unmatched items when both precede
/// the same common anchor (design §8.2 step 4 — the device is the one being
/// imported).
fn supersequence(server: &[String], device: &[String], lcs: &[String]) -> Vec<String> {
    let mut result = Vec::new();
    let mut si = 0;
    let mut di = 0;
    let mut li = 0;
    while li < lcs.len() {
        // Collect unmatched server items before the next common anchor.
        let mut server_unmatched = Vec::new();
        while si < server.len() && server[si] != lcs[li] {
            server_unmatched.push(server[si].clone());
            si += 1;
        }
        // Collect unmatched device items before the next common anchor.
        let mut device_unmatched = Vec::new();
        while di < device.len() && device[di] != lcs[li] {
            device_unmatched.push(device[di].clone());
            di += 1;
        }
        // Device items first (design §8.2 step 4 tie-break: device being imported).
        result.extend(device_unmatched);
        result.extend(server_unmatched);
        // Emit the common item.
        result.push(lcs[li].clone());
        si += 1;
        di += 1;
        li += 1;
    }
    // Trailing unmatched items.
    while di < device.len() {
        result.push(device[di].clone());
        di += 1;
    }
    while si < server.len() {
        result.push(server[si].clone());
        si += 1;
    }
    dedup_consecutive(result)
}

/// Remove consecutive duplicates (same song ID appearing back-to-back).
fn dedup_consecutive(items: Vec<String>) -> Vec<String> {
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        if out.last() != Some(&item) {
            out.push(item);
        }
    }
    out
}

/// Result of a legacy import: the merged sequence (newest-first) and whether
/// this device was the first to import (establishing the baseline).
#[derive(Debug, Clone)]
pub struct LegacyImportResult {
    pub merged_song_ids: Vec<String>,
    pub is_first_device: bool,
    pub device_id: Uuid,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_device_establishes_baseline() {
        let server: Vec<String> = vec![];
        let device: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
        let merged = merge_legacy(&server, &device);
        assert_eq!(merged, vec!["a", "b", "c"]);
    }

    #[test]
    fn lcs_matches_shared_history() {
        let server: Vec<String> = vec!["a".into(), "b".into(), "c".into()];
        let device: Vec<String> = vec!["x".into(), "b".into(), "y".into(), "c".into()];
        let merged = merge_legacy(&server, &device);
        // Common: b, c. Device unmatched before b: x. Server unmatched before b: a.
        // Device-first: x, a, b, then device unmatched before c: y → x, a, b, y, c.
        assert_eq!(merged, vec!["x", "a", "b", "y", "c"]);
    }

    #[test]
    fn no_common_subsequence_concatenates() {
        let server: Vec<String> = vec!["a".into(), "b".into()];
        let device: Vec<String> = vec!["c".into(), "d".into()];
        let merged = merge_legacy(&server, &device);
        // Device (newer) first, then server.
        assert_eq!(merged, vec!["c", "d", "a", "b"]);
    }

    #[test]
    fn dedup_consecutive_removes_repeats() {
        let items = vec![
            "a".to_string(),
            "a".to_string(),
            "b".to_string(),
            "b".to_string(),
            "c".to_string(),
        ];
        assert_eq!(dedup_consecutive(items), vec!["a", "b", "c"]);
    }

    #[test]
    fn empty_device_returns_server() {
        let server: Vec<String> = vec!["a".into(), "b".into()];
        let merged = merge_legacy(&server, &[]);
        assert_eq!(merged, vec!["a", "b"]);
    }

    #[test]
    fn lcs_function_basic() {
        let a = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let b = vec!["b".to_string(), "d".to_string(), "c".to_string()];
        assert_eq!(lcs(&a, &b), vec!["b", "c"]);
    }
}
