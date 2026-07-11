/**
 * Ring-buffered debug logger for the Electron main-process native audio stack.
 *
 * Mirrors the mobile `NativeLogger` (iOS/Android) so the desktop native player
 * debug window can show the same Playback / Info / Logs tabs. Entries are kept
 * per source with a bounded cap so a chatty source cannot evict entries from a
 * quieter one. Node is single-threaded so no serial queue is needed, but all
 * mutation goes through this class to keep the API drop-in compatible with the
 * mobile implementation.
 */

export type NativeDebugLogLevel = "debug" | "info" | "warn" | "error";

export interface NativeDebugLogEntry {
  /** Unix epoch milliseconds. */
  timestamp: number;
  level: NativeDebugLogLevel;
  message: string;
  /** Empty string means "no source". */
  source: string;
}

const MAX_ENTRIES_PER_SOURCE = 200;

const LEVEL_ORDER: readonly NativeDebugLogLevel[] = [
  "debug",
  "info",
  "warn",
  "error",
];

function levelRank(level: NativeDebugLogLevel): number {
  return LEVEL_ORDER.indexOf(level);
}

/**
 * A shared, process-wide logger. Use the module-level `nativeLogger` singleton
 * for the native audio debug surface; tests construct their own instances.
 */
export class NativeDebugLogger {
  readonly #maxEntriesPerSource: number;
  #buckets = new Map<string, NativeDebugLogEntry[]>();
  #entriesSincePrune = 0;

  constructor(options: { maxEntriesPerSource?: number } = {}) {
    this.#maxEntriesPerSource =
      options.maxEntriesPerSource ?? MAX_ENTRIES_PER_SOURCE;
  }

  log(level: NativeDebugLogLevel, message: string, source = ""): void {
    const entry: NativeDebugLogEntry = {
      timestamp: Date.now(),
      level,
      message,
      source,
    };
    const key = source.length === 0 ? "_default" : source;
    let bucket = this.#buckets.get(key);
    if (!bucket) {
      bucket = [];
      this.#buckets.set(key, bucket);
    }
    if (bucket.length >= this.#maxEntriesPerSource) {
      bucket.shift();
    }
    bucket.push(entry);
    this.#entriesSincePrune += 1;
  }

  debug(message: string, source?: string): void {
    this.log("debug", message, source);
  }

  info(message: string, source?: string): void {
    this.log("info", message, source);
  }

  warn(message: string, source?: string): void {
    this.log("warn", message, source);
  }

  error(message: string, source?: string): void {
    this.log("error", message, source);
  }

  /** All entries across sources, oldest first. */
  getEntries(): NativeDebugLogEntry[] {
    const all: NativeDebugLogEntry[] = [];
    for (const bucket of this.#buckets.values()) {
      for (const entry of bucket) all.push(entry);
    }
    all.sort((a, b) =>
      a.timestamp === b.timestamp
        ? levelRank(a.level) - levelRank(b.level)
        : a.timestamp - b.timestamp,
    );
    return all;
  }

  clear(): void {
    this.#buckets.clear();
    this.#entriesSincePrune = 0;
  }

  /** Total entries currently stored across all sources. */
  get size(): number {
    let total = 0;
    for (const bucket of this.#buckets.values()) total += bucket.length;
    return total;
  }
}

/** Process-wide singleton used by the native audio debug IPC. */
export const nativeLogger = new NativeDebugLogger();
