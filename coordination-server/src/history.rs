//! History coordination service (design §8).
//!
//! Bridges the history repository, legacy import algorithm, and the HTTP
//! API. Provides:
//! - legacy import orchestration (first device establishes baseline,
//!   subsequent devices merge via LCS)
//! - incremental sync cursor management
//! - tombstone retention and pruning

use chrono::Utc;
use uuid::Uuid;

use crate::errors::CoordinationError;
use crate::legacy_import::{merge_legacy, LegacyEntry, LegacyImportResult};
use crate::storage::models::{HistoryEntry, HistoryOperation, HistoryOperationKind};

/// Coordination service for history operations.
pub struct HistoryService {
    pub accounts: crate::storage::sqlite::SqliteAccountRepository,
    pub devices: crate::storage::sqlite::SqliteDeviceRepository,
    pub history: crate::storage::sqlite::SqliteHistoryRepository,
}

impl HistoryService {
    pub fn new(
        accounts: crate::storage::sqlite::SqliteAccountRepository,
        devices: crate::storage::sqlite::SqliteDeviceRepository,
        history: crate::storage::sqlite::SqliteHistoryRepository,
    ) -> Self {
        Self {
            accounts,
            devices,
            history,
        }
    }

    /// Perform legacy import for a device (design §8.2).
    ///
    /// If the device has already imported, returns an error. Otherwise merges
    /// the device's legacy list into the current server-side sequence.
    pub async fn legacy_import(
        &self,
        device_id: Uuid,
        account_id: Uuid,
        legacy: Vec<LegacyEntry>,
    ) -> Result<LegacyImportResult, CoordinationError> {
        use crate::storage::repository::{DeviceRepository, HistoryRepository};
        let device = self
            .devices
            .find_by_id(device_id)
            .await?
            .ok_or_else(|| CoordinationError::not_found("device not found"))?;
        if device.legacy_history_imported {
            return Err(CoordinationError::new(
                crate::errors::ErrorCode::BadMessage,
                "device has already performed legacy import",
            ));
        }

        // Get the current server-side history for the account (newest-first
        // song IDs, excluding deleted entries).
        let current = self.history.list_after(account_id, 0, 10_000).await?;
        let server_song_ids: Vec<String> = current
            .iter()
            .rev() // list_after returns ASC by revision; we want newest-first
            .filter(|e| !e.deleted)
            .map(|e| e.song_id.clone())
            .collect();
        let device_song_ids: Vec<String> = legacy.iter().map(|e| e.song_id.clone()).collect();

        let is_first_device = server_song_ids.is_empty();
        let merged = merge_legacy(&server_song_ids, &device_song_ids);

        // Insert the merged sequence as history entries. For the first device,
        // we insert the device's list directly. For subsequent devices, we
        // append only the device's unique items.
        if is_first_device {
            for entry in &legacy {
                self.append_legacy_entry(account_id, entry).await?;
            }
        } else {
            // Append only items that are not already in the server list.
            let existing: std::collections::HashSet<&String> = server_song_ids.iter().collect();
            for entry in &legacy {
                if existing.contains(&entry.song_id) {
                    continue;
                }
                self.append_legacy_entry(account_id, entry).await?;
            }
        }

        // Mark device as having completed legacy import.
        self.devices.mark_legacy_imported(device_id).await?;

        Ok(LegacyImportResult {
            merged_song_ids: merged,
            is_first_device,
            device_id,
        })
    }

    async fn append_legacy_entry(
        &self,
        account_id: Uuid,
        entry: &LegacyEntry,
    ) -> Result<(), CoordinationError> {
        use crate::storage::repository::HistoryRepository;
        let op_id = Uuid::new_v4();
        let event_id = Uuid::new_v4();
        let op = HistoryOperation {
            operation_id: op_id,
            account_id,
            kind: HistoryOperationKind::Add,
            revision: 0,
            created_at: Utc::now(),
        };
        let e = HistoryEntry {
            event_id,
            account_id,
            history_generation: 1,
            revision: 0,
            logical_playback_session_id: Uuid::new_v4(),
            song_id: entry.song_id.clone(),
            song_title: entry.song_title.clone(),
            song_artist: entry.song_artist.clone(),
            song_album: entry.song_album.clone(),
            song_duration: entry.song_duration,
            client_entered_at: Utc::now(),
            server_clock_offset: None,
            server_received_at: Utc::now(),
            deleted: false,
        };
        self.history.append(&op, &e).await?;
        Ok(())
    }

    /// Prune tombstones older than the retention window (design §8.3).
    pub async fn prune_tombstones(
        &self,
        older_than: chrono::DateTime<Utc>,
    ) -> Result<u64, CoordinationError> {
        use crate::storage::repository::HistoryRepository;
        self.history.prune_tombstones(older_than).await
    }
}

#[cfg(test)]
mod tests;
