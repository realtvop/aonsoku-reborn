import Foundation
import GRDB

struct SyncStateRepository {
    let db: DatabasePool

    func get(key: String) throws -> SyncStateRecord? {
        try db.read { db in
            try SyncStateRecord.fetchOne(db, key: key)
        }
    }

    func getLastSyncedAt(tier: String) throws -> Int? {
        try db.read { db in
            try SyncStateRecord.fetchOne(db, key: "tier:\(tier)")?.lastSyncedAt
        }
    }

    func recordTierCheckpoint(tier: String) throws {
        try db.write { db in
            let record = SyncStateRecord(
                key: "tier:\(tier)",
                lastSyncedAt: Int(Date().timeIntervalSince1970 * 1000),
                phase: nil,
                checkpointJson: nil
            )
            try record.save(db, onConflict: .replace)
        }
    }

    func recordFullSync() throws {
        try db.write { db in
            let record = SyncStateRecord(
                key: "full-sync",
                lastSyncedAt: Int(Date().timeIntervalSince1970 * 1000),
                phase: nil,
                checkpointJson: nil
            )
            try record.save(db, onConflict: .replace)
        }
    }

    func getFullSyncTimestamp() throws -> Int? {
        try db.read { db in
            try SyncStateRecord.fetchOne(db, key: "full-sync")?.lastSyncedAt
        }
    }

    func upsert(_ record: SyncStateRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try SyncStateRecord.deleteAll(db)
        }
    }
}
