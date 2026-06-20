//! Tests for the history coordination service.

use crate::history::HistoryService;
use crate::legacy_import::LegacyEntry;
use crate::storage::open_pool;
use crate::storage::repository::{AccountRepository, DeviceRepository, HistoryRepository};
use crate::storage::sqlite::{
    SqliteAccountRepository, SqliteDeviceRepository, SqliteHistoryRepository,
};

async fn setup() -> (
    tempfile::TempDir,
    SqliteAccountRepository,
    SqliteDeviceRepository,
    SqliteHistoryRepository,
    uuid::Uuid,
    uuid::Uuid,
) {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite://{}/test.db", dir.path().display());
    let pool = open_pool(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let acc = SqliteAccountRepository::new(pool.clone())
        .upsert_by_lookup_key("k", 100)
        .await
        .unwrap();
    let dev = SqliteDeviceRepository::new(pool.clone())
        .create(acc.id, "P", "web", None, 0, "h", uuid::Uuid::new_v4())
        .await
        .unwrap();
    (
        dir,
        SqliteAccountRepository::new(pool.clone()),
        SqliteDeviceRepository::new(pool.clone()),
        SqliteHistoryRepository::new(pool),
        acc.id,
        dev.id,
    )
}

fn entry(song_id: &str) -> LegacyEntry {
    LegacyEntry {
        song_id: song_id.into(),
        song_title: Some("t".into()),
        song_artist: Some("a".into()),
        song_album: None,
        song_duration: Some(180.0),
    }
}

#[tokio::test]
async fn first_device_import_establishes_baseline() {
    let (_dir, acc_repo, dev_repo, hist_repo, acc, dev) = setup().await;
    let svc = HistoryService::new(acc_repo, dev_repo, hist_repo.clone());
    let result = svc
        .legacy_import(dev, acc, vec![entry("a"), entry("b"), entry("c")])
        .await
        .unwrap();
    assert!(result.is_first_device);
    assert_eq!(result.merged_song_ids, vec!["a", "b", "c"]);
    // Verify entries were inserted.
    let entries = hist_repo.list_after(acc, 0, 100).await.unwrap();
    assert_eq!(entries.len(), 3);
}

#[tokio::test]
async fn second_device_merges_via_lcs() {
    let (_dir, acc_repo, dev_repo, hist_repo, acc, dev1) = setup().await;
    let svc = HistoryService::new(acc_repo.clone(), dev_repo.clone(), hist_repo.clone());
    // First device imports [a, b, c].
    svc.legacy_import(dev1, acc, vec![entry("a"), entry("b"), entry("c")])
        .await
        .unwrap();
    // Second device has [x, b, y, c] — should merge to include x and y.
    let dev2 = dev_repo
        .create(acc, "P2", "web", None, 0, "h2", uuid::Uuid::new_v4())
        .await
        .unwrap();
    let result = svc
        .legacy_import(
            dev2.id,
            acc,
            vec![entry("x"), entry("b"), entry("y"), entry("c")],
        )
        .await
        .unwrap();
    assert!(!result.is_first_device);
    // Merged sequence includes the unmatched items x and y.
    assert!(result.merged_song_ids.contains(&"x".to_string()));
    assert!(result.merged_song_ids.contains(&"y".to_string()));
}

#[tokio::test]
async fn duplicate_legacy_import_rejected() {
    let (_dir, acc_repo, dev_repo, hist_repo, acc, dev) = setup().await;
    let svc = HistoryService::new(acc_repo, dev_repo, hist_repo);
    svc.legacy_import(dev, acc, vec![entry("a")]).await.unwrap();
    let err = svc
        .legacy_import(dev, acc, vec![entry("b")])
        .await
        .unwrap_err();
    assert_eq!(err.code, crate::errors::ErrorCode::BadMessage);
}
