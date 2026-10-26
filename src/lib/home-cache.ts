export const HOME_RANDOM_CACHE_MAX_AGE = 24 * 60 * 60 * 1000;

export interface HomeCacheEntry<T> {
  version: 2;
  savedAt: number;
  value: T;
}

/** Keep the random selection's age separate from ordinary query refreshes. */
export async function loadCachedHomeData<T>({
  read,
  write,
  local,
  fresh,
  publish,
  hasContent,
  online,
  keepRandom = false,
  localFirst = false,
  force = false,
  memory,
  signal,
  now = Date.now,
}: {
  read: () => Promise<HomeCacheEntry<T> | T | undefined>;
  write: (entry: HomeCacheEntry<T>) => Promise<unknown>;
  local: () => Promise<T>;
  fresh: () => Promise<T>;
  publish: (value: T) => void;
  hasContent: (value: T) => boolean;
  online: boolean;
  keepRandom?: boolean;
  localFirst?: boolean;
  force?: boolean;
  memory?: T;
  signal: AbortSignal;
  now?: () => number;
}): Promise<T> {
  const stored = await read().catch(() => undefined);
  signal.throwIfAborted();
  let entry: HomeCacheEntry<T> | undefined;
  let adopted = false;
  if (stored !== undefined) {
    if (
      typeof stored === "object" &&
      stored !== null &&
      "version" in stored &&
      stored.version === 2 &&
      "savedAt" in stored &&
      typeof stored.savedAt === "number" &&
      "value" in stored
    ) {
      entry = stored as HomeCacheEntry<T>;
    } else {
      entry = { version: 2, savedAt: now(), value: stored as T };
      adopted = true;
    }
  }
  if (entry === undefined) {
    const seed = memory ?? (await local().catch(() => undefined));
    if (seed !== undefined && hasContent(seed)) {
      entry = { version: 2, savedAt: now(), value: seed };
      adopted = true;
    }
  }
  signal.throwIfAborted();
  if (entry !== undefined) {
    publish(entry.value);
    // Persist local seeds and migrate untimed snapshots even when offline.
    if (adopted) await write(entry).catch(() => undefined);
  }
  signal.throwIfAborted();
  if (
    keepRandom &&
    !force &&
    entry &&
    hasContent(entry.value) &&
    now() - entry.savedAt < HOME_RANDOM_CACHE_MAX_AGE
  ) {
    return entry.value;
  }
  if (localFirst) {
    const value = await local().catch(() => undefined);
    signal.throwIfAborted();
    if (value !== undefined && hasContent(value)) {
      publish(value);
      await write({ version: 2, savedAt: now(), value }).catch(() => undefined);
      return value;
    }
  }
  if (!online) return entry?.value ?? local();
  try {
    const value = await fresh();
    signal.throwIfAborted();
    publish(value);
    await write({ version: 2, savedAt: now(), value }).catch(() => undefined);
    return value;
  } catch (error) {
    signal.throwIfAborted();
    if (entry !== undefined) return entry.value;
    throw error;
  }
}
