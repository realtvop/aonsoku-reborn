import { get as idbGet, set as idbSet } from "idb-keyval";
import debounce from "lodash/debounce";
import merge from "lodash/merge";
import omit from "lodash/omit";
import { shallow } from "zustand/shallow";
import type { IPlayerContext, ISongList } from "@/types/playerContext";
import { isNativePreferencesAvailable } from "@/native/preferences/facade";
import {
  createNativeStorage,
  getNativePrefsPlugin,
} from "@/store/native-storage";
import { getRuntime } from "@/utils/capabilities";
import { logger } from "@/utils/logger";
import { decodeStoredPassword, genEncodedPassword } from "@/utils/salt";
import { getMaxShuffleStartHistory } from "@/utils/songListFunctions";
import {
  migrateCustomLyricsBodiesToIdb,
  stripCustomLyricsBodies,
} from "./custom-lyrics-persist";
import {
  MAX_QUEUE_SIZE,
  MAX_USER_QUEUE_IDB_SIZE,
  trimQueueToWindow,
} from "./queue-utils";

const IDB_SONGLIST_KEY = "player_songlist";
const PLAYER_STORE_NAME = "player_store";
const PLAYER_STORE_VERSION = 6;

interface PlayerStoreApi {
  getState: () => IPlayerContext;
  setState: (partial: Partial<IPlayerContext>) => void;
  subscribe: <T>(
    selector: (state: IPlayerContext) => T,
    listener: (selected: T, previous: T) => void,
    options?: { equalityFn?: (a: T, b: T) => boolean },
  ) => () => void;
}

function encodeCustomLyricsPassword(password: unknown) {
  if (typeof password !== "string" || !password) return "";
  if (password.startsWith("enc:")) return password;

  return genEncodedPassword(password);
}

function decodeCustomLyricsPassword(password: unknown) {
  return typeof password === "string" ? decodeStoredPassword(password) : "";
}

// biome-ignore lint/suspicious/noExplicitAny: persisted state shape is versioned
function encodePersistedCustomLyricsPassword(state: any) {
  const lyrics = state?.settings?.lyrics;
  if (!lyrics) return;

  lyrics.customServerPassword = encodeCustomLyricsPassword(
    lyrics.customServerPassword,
  );
}

// biome-ignore lint/suspicious/noExplicitAny: persisted state shape is versioned
function decodePersistedCustomLyricsPassword(state: any) {
  const lyrics = state?.settings?.lyrics;
  if (!lyrics) return;

  lyrics.customServerPassword = decodeCustomLyricsPassword(
    lyrics.customServerPassword,
  );
}

export function createPlayerPersistOptions(getStore: () => PlayerStoreApi) {
  return {
    name: PLAYER_STORE_NAME,
    version: PLAYER_STORE_VERSION,
    storage: createNativeStorage<IPlayerContext>(PLAYER_STORE_NAME),
    migrate: migratePlayerStoreState,
    merge: mergePlayerStoreState,
    partialize: partializePlayerStoreState,
    onRehydrateStorage: () => {
      return (_state: unknown, error: unknown) => {
        if (error) {
          logger.error("Player store rehydration failed", error);
          songlistHydrated.value = true;
          return;
        }

        if (
          getRuntime() === "capacitor-ios" ||
          getRuntime() === "capacitor-android"
        ) {
          songlistHydrated.value = true;
          return;
        }

        loadSonglistFromStorage(getStore)
          .catch((err: unknown) => {
            logger.error("Failed to load songlist from storage", err);
          })
          .finally(() => {
            songlistHydrated.value = true;
          });
      };
    },
  };
}

async function loadSonglistFromStorage(getStore: () => PlayerStoreApi) {
  let value: ISongList | undefined;

  if (isNativePreferencesAvailable()) {
    const { AonsokuNativePreferences } = await import(
      "@aonsoku/capacitor-native/preferences"
    );
    const result = await AonsokuNativePreferences.getQueueState();
    if (result.state) {
      try {
        value = JSON.parse(result.state) as ISongList;
      } catch {
        // corrupted state, ignore
      }
    }
  } else {
    value = (await idbGet<ISongList>(IDB_SONGLIST_KEY)) ?? undefined;
  }

  if (!value) return;

  const store = getStore();
  const current = store.getState().songlist;
  if (!value.contextQueue || value.contextQueue.songs.length === 0) {
    const migrated = migrateLegacySonglist(value);
    if (migrated) {
      store.setState({ songlist: migrated });
    }
    return;
  }
  if (
    current.contextQueue.songs.length === 0 &&
    current.userQueue.songs.length === 0
  ) {
    const migrated = migrateSonglistFromIdb(value);
    store.setState({ songlist: migrated });
  }
}

// biome-ignore lint/suspicious/noExplicitAny: zustand persist migrate API
export function migratePlayerStoreState(persistedState: any, version: number) {
  if (version === 1) {
    // biome-ignore lint/suspicious/noExplicitAny: legacy state shape
    const old = persistedState as any;
    if (old.songlist) {
      const oldSl = old.songlist;
      old.songlist = {
        contextQueue: {
          songs: oldSl.originalList || oldSl.currentList || [],
          currentIndex: oldSl.currentSongIndex || 0,
          sourceId: null,
          sourceName: oldSl.queueSource || null,
        },
        sourceQueue: {
          songs: oldSl.originalList || oldSl.currentList || [],
          currentIndex: oldSl.currentSongIndex || 0,
          sourceId: null,
          sourceName: oldSl.queueSource || null,
        },
        userQueue: { songs: [] },
        originalContextSongs: oldSl.originalList || oldSl.currentList || [],
        currentSong: oldSl.currentSong || null,
        radioList: oldSl.radioList || [],
        isShuffleActive: oldSl.isShuffleActive || false,
        isInUserQueue: false,
        playedUserQueueHistory: [],
        shuffleHistory: [],
      };
      delete old.songlist.shuffledList;
      delete old.songlist.currentList;
      delete old.songlist.originalList;
      delete old.songlist.originalSongIndex;
      delete old.songlist.currentSongIndex;
      delete old.songlist.queueSource;
    }
    if (old.playerState) {
      delete old.playerState.isShuffleActive;
    }
  }
  if (version <= 2) {
    // biome-ignore lint/suspicious/noExplicitAny: migrate userQueuePosition to isInUserQueue
    const old = persistedState as any;
    if (old.songlist) {
      if (old.songlist.userQueuePosition !== undefined) {
        old.songlist.isInUserQueue = old.songlist.userQueuePosition > 0;
        old.songlist.playedUserQueueHistory = [];
        delete old.songlist.userQueuePosition;
      }
    }
  }
  if (version <= 3) {
    // biome-ignore lint/suspicious/noExplicitAny: migrate sourceId from { albumId } | { playlistId } to QueueSourceId
    const old = persistedState as any;
    if (old.songlist?.contextQueue?.sourceId) {
      const srcId = old.songlist.contextQueue.sourceId;
      if (srcId && "albumId" in srcId) {
        old.songlist.contextQueue.sourceId = {
          type: "album",
          id: srcId.albumId,
        };
      } else if (srcId && "playlistId" in srcId) {
        old.songlist.contextQueue.sourceId = {
          type: "playlist",
          id: srcId.playlistId,
        };
      } else if (srcId && !("type" in srcId)) {
        old.songlist.contextQueue.sourceId = null;
      }
    }
  }
  if (version <= 4) {
    encodePersistedCustomLyricsPassword(persistedState);
  }
  if (version <= 5) {
    migrateCustomLyricsBodiesToIdb(persistedState);
  }
  return persistedState;
}

export function mergePlayerStoreState(
  persistedState: unknown,
  currentState: IPlayerContext,
) {
  decodePersistedCustomLyricsPassword(persistedState);

  return merge(currentState, persistedState);
}

export function partializePlayerStoreState(state: IPlayerContext) {
  const omitKeys = [
    "songlist",
    "actions",
    "playerState.isPlaying",
    "playerState.isBuffering",
    "playerState.audioPlayerRef",
    "playerState.radioPlayerRef",
    "playerState.mainDrawerState",
    "playerState.queueState",
    "playerState.lyricsState",
    "playerState.fullscreenPlayerOpen",
    "playerState.fullscreenPlayerTab",
    "playerState.desktopFullscreenPanelView",
    "playerState.pipWindowOpen",
    "playerState.hasPrev",
    "playerState.hasNext",
    "playerProgress.bufferedProgress",
    "playerProgress.seekCount",
    "remoteControl",
  ];

  if (
    getRuntime() === "capacitor-ios" ||
    getRuntime() === "capacitor-android"
  ) {
    omitKeys.push("playerProgress.progress");
  }

  const appStore = omit(state, omitKeys);

  const { sanitized, evictedKeys } = stripCustomLyricsBodies(
    state.settings.lyrics.selectedCustomLyrics,
  );
  if (evictedKeys.length > 0) {
    import("@/service/lyrics")
      .then(({ deleteCustomLyricsBodies }) =>
        deleteCustomLyricsBodies(evictedKeys),
      )
      .catch(() => {});
  }

  return merge({}, appStore, {
    settings: {
      lyrics: {
        customServerPassword: encodeCustomLyricsPassword(
          state.settings.lyrics.customServerPassword,
        ),
        selectedCustomLyrics: sanitized,
      },
    },
  });
}

// biome-ignore lint/suspicious/noExplicitAny: legacy state shape migration
export function migrateLegacySonglist(value: any): ISongList | null {
  if (!value) return null;
  if (value.contextQueue && value.contextQueue.songs) return null;

  const songs = value.originalList || value.currentList || [];
  if (songs.length === 0) return null;

  return {
    sourceQueue: {
      songs,
      currentIndex: value.currentSongIndex || 0,
      sourceId: null,
      sourceName: value.queueSource || null,
    },
    contextQueue: {
      songs,
      currentIndex: value.currentSongIndex || 0,
      sourceId: null,
      sourceName: value.queueSource || null,
    },
    userQueue: { songs: [] },
    originalContextSongs: [...songs],
    currentSong: value.currentSong || null,
    radioList: value.radioList || [],
    isShuffleActive: false,
    isInUserQueue: false,
    playedUserQueueHistory: [],
    shuffleHistory: [],
    shuffleStartHistory: [],
  };
}

// biome-ignore lint/suspicious/noExplicitAny: IDB data may come from older schema versions
export function migrateSonglistFromIdb(value: any): ISongList {
  const isInUserQueue =
    value.isInUserQueue ??
    (value.userQueuePosition != null ? value.userQueuePosition > 0 : false);
  const userQueue =
    value.userQueue &&
    typeof value.userQueue === "object" &&
    Array.isArray(value.userQueue.songs)
      ? { songs: value.userQueue.songs }
      : { songs: [] };

  if (
    value.userQueuePosition != null &&
    value.userQueuePosition > 0 &&
    Array.isArray(userQueue.songs) &&
    userQueue.songs.length > 0
  ) {
    // The old model had all songs in the array with a position pointer.
    // We can't reconstruct consumed songs, so the remaining array stays queued.
  }

  const result: ISongList = {
    ...value,
    sourceQueue: value.sourceQueue ?? {
      songs: value.originalContextSongs ?? value.contextQueue?.songs ?? [],
      currentIndex: value.contextQueue?.currentIndex ?? 0,
      sourceId: value.contextQueue?.sourceId ?? null,
      sourceName: value.contextQueue?.sourceName ?? null,
    },
    contextQueue: value.contextQueue ?? {
      songs: [],
      currentIndex: 0,
      sourceId: null,
      sourceName: null,
    },
    userQueue,
    originalContextSongs: value.originalContextSongs ?? [],
    currentSong: value.currentSong ?? null,
    radioList: value.radioList ?? [],
    isShuffleActive: value.isShuffleActive ?? false,
    isInUserQueue,
    playedUserQueueHistory: value.playedUserQueueHistory ?? [],
    shuffleHistory: value.shuffleHistory ?? [],
    shuffleStartHistory: value.shuffleStartHistory ?? [],
  };

  for (const queue of [result.contextQueue, result.sourceQueue]) {
    if (!queue.sourceId) continue;
    const srcId = queue.sourceId as Record<string, unknown>;
    if ("albumId" in srcId) {
      queue.sourceId = {
        type: "album",
        id: String(srcId.albumId),
      };
    } else if ("playlistId" in srcId) {
      queue.sourceId = {
        type: "playlist",
        id: String(srcId.playlistId),
      };
    }
  }

  delete result.userQueuePosition;

  return result;
}

export function trimSonglistForIdb(songlist: ISongList): ISongList {
  const { contextQueue, sourceQueue, userQueue, ...rest } = songlist;
  const trimmed = trimQueueToWindow(
    contextQueue.songs,
    contextQueue.currentIndex,
  );

  return {
    ...rest,
    contextQueue: {
      ...contextQueue,
      songs: trimmed.songs,
      currentIndex: trimmed.currentIndex,
    },
    sourceQueue,
    userQueue: {
      songs: userQueue.songs.slice(0, MAX_USER_QUEUE_IDB_SIZE),
    },
    originalContextSongs:
      sourceQueue.songs.length === 0 &&
      rest.originalContextSongs.length <= MAX_QUEUE_SIZE
        ? rest.originalContextSongs
        : [],
    playedUserQueueHistory: rest.playedUserQueueHistory.slice(
      -MAX_USER_QUEUE_IDB_SIZE,
    ),
    originalUserSongs: rest.originalUserSongs?.slice(-MAX_USER_QUEUE_IDB_SIZE),
    shuffleStartHistory:
      rest.shuffleStartHistory?.slice(
        -getMaxShuffleStartHistory(contextQueue.songs.length),
      ) ?? [],
  };
}

const songlistHydrated = { value: false };
let idbFlushed = false;
let persistenceRegistered = false;

function writeSonglistToStorage(songlist: ISongList) {
  const trimmed = trimSonglistForIdb(songlist);
  if (isNativePreferencesAvailable()) {
    getNativePrefsPlugin()
      ?.setQueueState({ state: JSON.stringify(trimmed) })
      .catch((error: unknown) => {
        logger.error("Failed to write songlist to native storage", error);
      });
  } else {
    idbSet(IDB_SONGLIST_KEY, trimmed).catch((error: unknown) => {
      logger.error("Failed to write songlist to IndexedDB", error);
    });
  }
}

const debouncedSonglistWrite = debounce((songlist: ISongList) => {
  writeSonglistToStorage(songlist);
}, 300);

function flushSonglistWrite(store: PlayerStoreApi) {
  if (idbFlushed) return;
  idbFlushed = true;
  debouncedSonglistWrite.cancel();
  const songlist = store.getState().songlist;
  writeSonglistToStorage(songlist);
}

export function registerPlayerPersistence(
  store: PlayerStoreApi,
  addCleanup: (callback: () => void) => void,
) {
  if (persistenceRegistered) return;
  persistenceRegistered = true;

  if (
    getRuntime() !== "capacitor-ios" &&
    getRuntime() !== "capacitor-android"
  ) {
    store.subscribe(
      (state) => [state.songlist],
      ([songlist]) => {
        if (!songlistHydrated.value) return;
        idbFlushed = false;
        debouncedSonglistWrite(songlist);
      },
      {
        equalityFn: shallow,
      },
    );

    registerIdbEventListeners(store, addCleanup);
  }
}

function registerIdbEventListeners(
  store: PlayerStoreApi,
  addCleanup: (callback: () => void) => void,
) {
  if (typeof document === "undefined" || typeof window === "undefined") return;

  const handleVisibilityChange = () => {
    if (document.hidden && songlistHydrated.value) {
      flushSonglistWrite(store);
    }
  };
  const handleBeforeUnload = () => {
    if (songlistHydrated.value) flushSonglistWrite(store);
  };
  document.addEventListener("visibilitychange", handleVisibilityChange);
  window.addEventListener("beforeunload", handleBeforeUnload);

  addCleanup(() => {
    document.removeEventListener("visibilitychange", handleVisibilityChange);
    window.removeEventListener("beforeunload", handleBeforeUnload);
  });
}
