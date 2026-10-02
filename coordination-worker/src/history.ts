import type { HistoryOperationInput } from "./protocol";
import { fail, integer, object, string, uuid } from "./security";
import {
  type Entry,
  type Meta,
  type Operation,
  Store,
  type Tombstone,
} from "./store";

const RETENTION = 30 * 86400_000;
export function operationInput(value: unknown): HistoryOperationInput {
  const op = object(value);
  uuid(op.operationId);
  if (!["add", "delete_one", "clear", "set_limit"].includes(string(op.kind)))
    fail("bad_message", "unknown history operation");
  if (op.eventId !== undefined) uuid(op.eventId);
  if (op.logicalPlaybackSessionId !== undefined)
    uuid(op.logicalPlaybackSessionId);
  if (op.kind === "add") string(op.songId);
  if (op.kind === "delete_one") uuid(op.eventId);
  for (const field of ["songTitle", "songArtist", "songAlbum"]) {
    if (op[field] !== undefined && typeof op[field] !== "string")
      fail("bad_message", "invalid history metadata");
  }
  if (
    op.songDuration !== undefined &&
    (typeof op.songDuration !== "number" ||
      !Number.isFinite(op.songDuration) ||
      op.songDuration < 0)
  )
    fail("bad_message", "invalid duration");
  if (
    op.clientEnteredAt !== undefined &&
    (typeof op.clientEnteredAt !== "string" ||
      !Number.isFinite(Date.parse(op.clientEnteredAt)))
  )
    fail("bad_message", "invalid timestamp");
  if (
    op.serverClockOffset !== undefined &&
    (typeof op.serverClockOffset !== "number" ||
      !Number.isSafeInteger(op.serverClockOffset))
  )
    fail("bad_message", "invalid clock offset");
  if (op.historyLimit !== undefined) integer(op.historyLimit);
  return op as unknown as HistoryOperationInput;
}

function remove(store: Store, meta: Meta, entry: Entry) {
  store.delete(`history:${entry.eventId}`);
  store.set(`tombstone:${entry.eventId}`, {
    eventId: entry.eventId,
    revision: ++meta.historyRevision,
    createdAt: new Date().toISOString(),
    expires: Date.now() + RETENTION,
  } satisfies Tombstone);
}
export function prune(store: Store, meta: Meta) {
  const entries = store
    .list<Entry>("history:")
    .sort((a, b) => b.revision - a.revision);
  for (const entry of entries.slice(meta.historyLimit))
    remove(store, meta, entry);
}
export function applyOperation(store: Store, op: HistoryOperationInput) {
  return store.transaction(() => {
    const prior = store.get<Operation>(`operation:${op.operationId}`);
    if (prior)
      return {
        operationId: op.operationId,
        revision: prior.revision,
        accepted: true,
        error: null,
      };
    const meta = store.get<Meta>("meta");
    if (!meta) fail("not_found", "account not found", 404);
    if (op.kind === "add") {
      const eventId = op.eventId ?? crypto.randomUUID();
      const existing = store.get<Entry>(`history:${eventId}`);
      // A tombstone prevents delayed retries from resurrecting a deleted play.
      if (!existing && !store.get(`tombstone:${eventId}`)) {
        store.set(`history:${eventId}`, {
          eventId,
          revision: ++meta.historyRevision,
          logicalPlaybackSessionId:
            op.logicalPlaybackSessionId ?? crypto.randomUUID(),
          songId: op.songId ?? "",
          songTitle: op.songTitle ?? null,
          songArtist: op.songArtist ?? null,
          songAlbum: op.songAlbum ?? null,
          songDuration: op.songDuration ?? null,
          clientEnteredAt: op.clientEnteredAt ?? new Date().toISOString(),
          serverClockOffset: op.serverClockOffset ?? null,
          serverReceivedAt: new Date().toISOString(),
          deleted: false,
        } satisfies Entry);
      }
    } else if (op.kind === "delete_one") {
      const eventId = op.eventId ?? "";
      const entry = store.get<Entry>(`history:${eventId}`);
      if (entry) remove(store, meta, entry);
      else if (!store.get(`tombstone:${eventId}`)) {
        store.set(`tombstone:${eventId}`, {
          eventId,
          revision: ++meta.historyRevision,
          createdAt: new Date().toISOString(),
          expires: Date.now() + RETENTION,
        });
      }
    } else if (op.kind === "clear") {
      for (const entry of store.list<Entry>("history:"))
        remove(store, meta, entry);
      meta.historyGeneration++;
      meta.historyRevision++;
    } else {
      meta.historyLimit = Math.max(
        1,
        Math.min(1000, op.historyLimit ?? meta.historyLimit),
      );
    }
    prune(store, meta);
    store.set("meta", meta);
    const revision = meta.historyRevision;
    store.set(`operation:${op.operationId}`, {
      revision,
      expires: Date.now() + RETENTION,
    } satisfies Operation);
    return {
      operationId: op.operationId,
      revision,
      accepted: true,
      error: null,
    };
  });
}

// Port of Rust's LCS/shortest-common-supersequence legacy merge (newest first).
export function mergeLegacy(server: string[], device: string[]) {
  if (!server.length) return device;
  if (!device.length) return server;
  const dp = Array.from(
    { length: server.length + 1 },
    () => new Uint16Array(device.length + 1),
  );
  for (let i = 1; i <= server.length; i++) {
    for (let j = 1; j <= device.length; j++) {
      dp[i][j] =
        server[i - 1] === device[j - 1]
          ? dp[i - 1][j - 1] + 1
          : Math.max(dp[i - 1][j], dp[i][j - 1]);
    }
  }
  let i = server.length;
  let j = device.length;
  const lcs: string[] = [];
  while (i && j) {
    if (server[i - 1] === device[j - 1]) {
      lcs.push(server[--i]);
      j--;
    } else if (dp[i - 1][j] >= dp[i][j - 1]) i--;
    else j--;
  }
  lcs.reverse();
  const merged: string[] = [];
  i = 0;
  j = 0;
  for (const anchor of lcs) {
    const pending: string[] = [];
    while (i < server.length && server[i] !== anchor) pending.push(server[i++]);
    while (j < device.length && device[j] !== anchor) merged.push(device[j++]);
    merged.push(...pending, anchor);
    i++;
    j++;
  }
  merged.push(...device.slice(j), ...server.slice(i));
  return merged.filter((id, index) => index === 0 || id !== merged[index - 1]);
}
