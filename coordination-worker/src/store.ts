import type {
  DeviceDto,
  HistoryEntryDto,
  HistoryTombstoneDto,
  PlaybackSnapshot,
} from "../../src/coordination/types";

export interface Device extends DeviceDto {
  refreshHash: string;
  refreshUsedAt: number;
}
export interface Meta {
  accountId: string;
  historyLimit: number;
  historyGeneration: number;
  historyRevision: number;
}
export interface Session {
  id: string;
  deviceId: string;
  generation: number;
  snapshotRevision: number;
  snapshot: PlaybackSnapshot;
  confirmedAt: number;
  offlineAt: number | null;
  transferredTo: string | null;
}
export interface Handoff {
  id: string;
  source: string;
  target: string;
  sessionId: string;
  generation: number;
  snapshotRevision: number;
  deadline: number;
  phase: "candidate" | "relinquish";
}
export interface Timed {
  expires: number;
}
export interface Operation extends Timed {
  revision: number;
}
export interface Tombstone extends HistoryTombstoneDto {
  expires: number;
}
export type Entry = HistoryEntryDto;

// Per-record SQLite rows avoid rewriting an account's entire history for a snapshot.
// All compound transitions run in transactionSync; no network awaits inside a transaction.
export class Store {
  constructor(readonly storage: DurableObjectStorage) {
    storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    );
  }
  get<T>(key: string): T | undefined {
    const row = this.storage.sql
      .exec<{ value: string }>("SELECT value FROM records WHERE key = ?", key)
      .toArray()[0];
    return row ? (JSON.parse(row.value) as T) : undefined;
  }
  set(key: string, value: unknown) {
    this.storage.sql.exec(
      "INSERT INTO records (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      key,
      JSON.stringify(value),
    );
  }
  delete(key: string) {
    this.storage.sql.exec("DELETE FROM records WHERE key = ?", key);
  }
  list<T>(prefix: string): T[] {
    return this.storage.sql
      .exec<{ value: string }>(
        "SELECT value FROM records WHERE key >= ? AND key < ?",
        prefix,
        `${prefix}\uffff`,
      )
      .toArray()
      .map((row) => JSON.parse(row.value) as T);
  }
  entries<T>(prefix: string): { key: string; value: T }[] {
    return this.storage.sql
      .exec<{ key: string; value: string }>(
        "SELECT key, value FROM records WHERE key >= ? AND key < ?",
        prefix,
        `${prefix}\uffff`,
      )
      .toArray()
      .map((row) => ({ key: row.key, value: JSON.parse(row.value) as T }));
  }
  transaction<T>(callback: () => T): T {
    return this.storage.transactionSync(callback);
  }
  clear() {
    this.storage.sql.exec("DELETE FROM records");
  }
}
