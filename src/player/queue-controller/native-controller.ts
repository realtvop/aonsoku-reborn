import type { PluginListenerHandle } from "@capacitor/core";
import { getSongStreamUrl } from "@/api/httpClient";
import { getNativeAudioPluginAvailability } from "@/native/audio/facade";
import type {
  NativeAudioEvents,
  NativeAudioPlugin,
  NativeQueueSong,
  NativeQueueSourceId,
} from "@/native/audio/types";
import {
  appendPlaybackQueueCycle,
  buildContextQueueSongs,
  findSongTier,
  getCurrentSong,
  normalizeSourceId,
  rebuildContextQueueForLoopState,
  setLastOnUserQueue,
  setNextOnUserQueue,
} from "@/store/player/queue-utils";
import { usePlayerStore } from "@/store/player/store";
import type { QueueSourceId } from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { Radio } from "@/types/responses/radios";
import type { ISong } from "@/types/responses/song";
import { getRuntime } from "@/utils/capabilities";
import { getSongCoverArtId } from "@/utils/coverArt";
import { logger } from "@/utils/logger";
import {
  getMaxShuffleStartHistory,
  pickRandomStartIndex,
  pushToHistory,
} from "@/utils/songListFunctions";
import type {
  QueueController,
  QueueControllerEvent,
  QueueControllerListener,
  QueueControllerState,
} from "./types";

function loopStateToNative(state: LoopState): "off" | "one" | "all" {
  switch (state) {
    case LoopState.Off:
      return "off";
    case LoopState.All:
      return "all";
    case LoopState.One:
      return "one";
  }
}

function songToNativeQueueSong(song: ISong): NativeQueueSong {
  return {
    id: song.id,
    title: song.title,
    artist: song.artist,
    artistId: song.artistId,
    album: song.album,
    albumId: song.albumId,
    duration: song.duration,
    coverArtId: getSongCoverArtId(song),
    streamUrl: getSongStreamUrl(song.id),
    song: { ...song },
  };
}

function nativeQueueSongToISong(ns: NativeQueueSong): ISong {
  return {
    id: ns.id,
    title: ns.title,
    artist: ns.artist,
    artistId: ns.artistId ?? "",
    album: ns.album,
    albumId: ns.albumId ?? "",
    coverArt: ns.coverArtId ?? "",
    duration: ns.duration,
    parent: "",
    isDir: false,
    track: 0,
    year: 0,
    size: 0,
    contentType: "",
    suffix: "",
    bitRate: 0,
    path: "",
    discNumber: 0,
    created: "",
    type: "music",
    isVideo: false,
    bpm: 0,
    comment: "",
    sortName: "",
    mediaType: "song",
    musicBrainzId: "",
    genres: [],
    replayGain: {},
  } as ISong;
}

function nativeSourceIdToQueueSourceId(
  sourceId: NativeQueueSourceId | null,
): QueueSourceId | null {
  if (!sourceId) return null;
  return { type: sourceId.type, id: sourceId.id } as QueueSourceId;
}

const TERMINAL_PLAYBACK_RESET_DELAY_MS = 1000;

export class NativeQueueController implements QueueController {
  #plugin: NativeAudioPlugin;
  #listeners: Map<
    QueueControllerEvent,
    Set<QueueControllerListener<QueueControllerEvent>>
  > = new Map();
  #nativeListenerHandles: PluginListenerHandle[] = [];
  #disposed = false;
  #nativeDrivenTransition = false;
  #suppressNextQueueStateChanged = false;
  #queueSynced = false;
  #terminalPlaybackResetTimer: ReturnType<typeof setTimeout> | null = null;

  #syncContextQueueToNative(autoplay = true): Promise<void> {
    const { songlist, playerState } = usePlayerStore.getState();
    if (songlist.contextQueue.songs.length === 0) {
      return Promise.resolve();
    }

    this.#nativeDrivenTransition = true;
    return this.#plugin
      .setContextQueue({
        songs: songlist.contextQueue.songs.map(songToNativeQueueSong),
        currentIndex: songlist.contextQueue.currentIndex,
        autoplay,
        repeatMode: loopStateToNative(playerState.loopState),
        sourceId: songlist.contextQueue.sourceId,
        sourceName: songlist.contextQueue.sourceName ?? undefined,
      })
      .catch((err) => {
        logger.error("[NativeQueueController] queue sync failed", err);
        throw err;
      });
  }

  #updateContextQueueOnNative(): void {
    const { songlist } = usePlayerStore.getState();
    if (songlist.contextQueue.songs.length === 0) return;

    this.#plugin
      .updateContextQueue({
        songs: songlist.contextQueue.songs.map(songToNativeQueueSong),
        currentIndex: songlist.contextQueue.currentIndex,
      })
      .catch((err) => {
        logger.error("[NativeQueueController] queue update failed", err);
      });
  }

  constructor() {
    const availability = getNativeAudioPluginAvailability();
    if (!availability.available) {
      throw new Error("NativeQueueController requires native audio plugin");
    }
    this.#plugin = availability.plugin;
    this.#wireNativeEvents();
  }

  setSongList(
    songs: ISong[],
    index?: number | null,
    shuffle?: boolean,
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void {
    this.#queueSynced = true;
    if (!songs || songs.length === 0) return;

    let targetIndex = index;
    if (shuffle && (targetIndex === null || targetIndex === undefined)) {
      const startHistory =
        usePlayerStore.getState().songlist.shuffleStartHistory ?? [];
      targetIndex = pickRandomStartIndex(
        songs.length,
        startHistory,
        (i) => songs[i].id,
      );
    } else if (targetIndex === null || targetIndex === undefined) {
      targetIndex = 0;
    }
    const clampedIndex = Math.max(0, Math.min(targetIndex, songs.length - 1));

    const prevPlayerState = { ...usePlayerStore.getState().playerState };
    const prevPlayerProgress = { ...usePlayerStore.getState().playerProgress };
    const prevSonglist = {
      isShuffleActive: usePlayerStore.getState().songlist.isShuffleActive,
      sourceQueue: { ...usePlayerStore.getState().songlist.sourceQueue },
      contextQueue: { ...usePlayerStore.getState().songlist.contextQueue },
      currentSong: usePlayerStore.getState().songlist.currentSong,
      originalContextSongs: usePlayerStore.getState().songlist
        .originalContextSongs
        ? [...usePlayerStore.getState().songlist.originalContextSongs]
        : [],
      originalUserSongs: usePlayerStore.getState().songlist.originalUserSongs
        ? [...usePlayerStore.getState().songlist.originalUserSongs]
        : undefined,
      userQueue: {
        songs: [...usePlayerStore.getState().songlist.userQueue.songs],
      },
      isInUserQueue: usePlayerStore.getState().songlist.isInUserQueue,
      playedUserQueueHistory: [
        ...usePlayerStore.getState().songlist.playedUserQueueHistory,
      ],
      shuffleHistory: [...usePlayerStore.getState().songlist.shuffleHistory],
      shuffleStartHistory: [
        ...usePlayerStore.getState().songlist.shuffleStartHistory,
      ],
    };

    const rollback = (err: unknown) => {
      logger.error("[NativeQueueController] setSongList failed", err);
      usePlayerStore.setState((state) => {
        state.playerState.isPlaying = prevPlayerState.isPlaying;
        state.playerState.mediaType = prevPlayerState.mediaType;
        state.playerState.currentDuration = prevPlayerState.currentDuration;
        state.playerProgress.progress = prevPlayerProgress.progress;
        state.playerProgress.bufferedProgress =
          prevPlayerProgress.bufferedProgress;
        state.songlist.isShuffleActive = prevSonglist.isShuffleActive;
        state.songlist.sourceQueue = prevSonglist.sourceQueue;
        state.songlist.contextQueue = prevSonglist.contextQueue;
        state.songlist.currentSong = prevSonglist.currentSong;
        state.songlist.originalContextSongs = prevSonglist.originalContextSongs;
        state.songlist.originalUserSongs = prevSonglist.originalUserSongs;
        state.songlist.userQueue = prevSonglist.userQueue;
        state.songlist.isInUserQueue = prevSonglist.isInUserQueue;
        state.songlist.playedUserQueueHistory =
          prevSonglist.playedUserQueueHistory;
        state.songlist.shuffleHistory = prevSonglist.shuffleHistory;
        state.songlist.shuffleStartHistory = prevSonglist.shuffleStartHistory;
      });
    };

    const loopState = usePlayerStore.getState().playerState.loopState;
    const normalizedId = normalizeSourceId(sourceId);

    if (shuffle && songs.length > 1) {
      const startHistory =
        usePlayerStore.getState().songlist.shuffleStartHistory ?? [];
      const startSong = songs[clampedIndex];
      const queueSongs = buildContextQueueSongs(
        songs,
        clampedIndex,
        loopState,
        true,
      );

      const updatedStartHistory = pushToHistory(
        startHistory,
        startSong.id,
        getMaxShuffleStartHistory(songs.length),
      );

      const nativeSongs = queueSongs.map(songToNativeQueueSong);
      const originalNativeSongs = songs.map(songToNativeQueueSong);
      this.#nativeDrivenTransition = true;
      this.#plugin
        .setContextQueue({
          songs: nativeSongs,
          currentIndex: 0,
          autoplay: true,
          repeatMode: loopStateToNative(loopState),
          sourceId: normalizedId,
          sourceName,
        })
        .then(() =>
          this.#plugin.markAsShuffled({ originalSongs: originalNativeSongs }),
        )
        .catch(rollback);

      usePlayerStore.setState((state) => {
        state.playerState.isPlaying = true;
        state.playerState.mediaType = "song";
        state.playerProgress.progress = 0;
        state.playerProgress.bufferedProgress = 0;
        state.songlist.isShuffleActive = true;
        state.songlist.contextQueue.songs = queueSongs;
        state.songlist.contextQueue.currentIndex = 0;
        state.songlist.contextQueue.sourceId = normalizedId;
        state.songlist.contextQueue.sourceName =
          sourceName !== undefined
            ? sourceName || null
            : state.songlist.contextQueue.sourceName;
        state.songlist.currentSong = startSong;
        state.songlist.sourceQueue = {
          songs: [...songs],
          currentIndex: clampedIndex,
          sourceId: normalizedId,
          sourceName: state.songlist.contextQueue.sourceName,
        };
        state.songlist.originalContextSongs = [...songs];
        state.songlist.userQueue = { songs: [] };
        state.songlist.isInUserQueue = false;
        state.songlist.playedUserQueueHistory = [];
        state.songlist.shuffleHistory = [];
        state.songlist.shuffleStartHistory = updatedStartHistory;
        state.playerState.currentDuration = startSong.duration
          ? Math.round(startSong.duration)
          : 0;
      });
    } else {
      const clampedIndex = Math.max(0, Math.min(index, songs.length - 1));

      const { contextQueue } = usePlayerStore.getState().songlist;
      if (
        contextQueue.songs.length === songs.length &&
        contextQueue.currentIndex === clampedIndex &&
        contextQueue.songs.every((s, i) => s.id === songs[i].id)
      ) {
        usePlayerStore.setState((state) => {
          state.playerState.isPlaying = true;
        });
        return;
      }

      const queueSongs = buildContextQueueSongs(
        songs,
        clampedIndex,
        loopState,
        false,
      );
      const nativeSongs = queueSongs.map(songToNativeQueueSong);
      this.#nativeDrivenTransition = true;
      this.#plugin
        .setContextQueue({
          songs: nativeSongs,
          currentIndex: 0,
          autoplay: true,
          repeatMode: loopStateToNative(loopState),
          sourceId: normalizedId,
          sourceName,
        })
        .catch(rollback);

      usePlayerStore.setState((state) => {
        state.playerState.isPlaying = true;
        state.playerState.mediaType = "song";
        state.playerProgress.progress = 0;
        state.playerProgress.bufferedProgress = 0;
        state.songlist.isShuffleActive = false;
        state.songlist.contextQueue.songs = queueSongs;
        state.songlist.contextQueue.currentIndex = 0;
        state.songlist.contextQueue.sourceId = normalizedId;
        state.songlist.contextQueue.sourceName =
          sourceName !== undefined
            ? sourceName || null
            : state.songlist.contextQueue.sourceName;
        state.songlist.currentSong = queueSongs[0] ?? null;
        state.songlist.sourceQueue = {
          songs: [...songs],
          currentIndex: clampedIndex,
          sourceId: normalizedId,
          sourceName: state.songlist.contextQueue.sourceName,
        };
        state.songlist.originalContextSongs = [...songs];
        state.songlist.userQueue = { songs: [] };
        state.songlist.isInUserQueue = false;
        state.songlist.playedUserQueueHistory = [];
        state.playerState.currentDuration = queueSongs[0]?.duration
          ? Math.round(queueSongs[0].duration)
          : 0;
      });
    }
  }

  playFromQueue(contextSongs: ISong[], contextIndex: number): void {
    const prevIsPlaying = usePlayerStore.getState().playerState.isPlaying;
    const prevProgress = usePlayerStore.getState().playerProgress.progress;
    const prevBufferedProgress =
      usePlayerStore.getState().playerProgress.bufferedProgress;
    const prevIndex =
      usePlayerStore.getState().songlist.contextQueue.currentIndex;
    const prevIsInUserQueue = usePlayerStore.getState().songlist.isInUserQueue;
    const prevCurrentSong = usePlayerStore.getState().songlist.currentSong;
    const prevDuration = usePlayerStore.getState().playerState.currentDuration;

    this.#plugin.playAtIndex({ index: contextIndex }).catch((err) => {
      logger.error("[NativeQueueController] playFromQueue failed", err);
      usePlayerStore.setState((state) => {
        state.playerState.isPlaying = prevIsPlaying;
        state.playerProgress.progress = prevProgress;
        state.playerProgress.bufferedProgress = prevBufferedProgress;
        state.songlist.contextQueue.currentIndex = prevIndex;
        state.songlist.isInUserQueue = prevIsInUserQueue;
        state.songlist.currentSong = prevCurrentSong;
        state.playerState.currentDuration = prevDuration;
      });
    });

    usePlayerStore.setState((state) => {
      state.playerState.isPlaying = true;
      state.playerProgress.progress = 0;
      state.playerProgress.bufferedProgress = 0;
      state.songlist.contextQueue.currentIndex = contextIndex;
      if (
        state.playerState.loopState === LoopState.All &&
        contextIndex >= state.songlist.contextQueue.songs.length - 1
      ) {
        appendPlaybackQueueCycle(state.songlist);
      }
      state.songlist.isInUserQueue = false;
      const song = state.songlist.contextQueue.songs[contextIndex] ?? null;
      if (song) {
        state.songlist.currentSong = song;
        state.playerState.currentDuration = song.duration
          ? Math.round(song.duration)
          : 0;
      }
    });

    if (
      usePlayerStore.getState().playerState.loopState === LoopState.All &&
      contextIndex >= contextSongs.length - 1
    ) {
      this.#updateContextQueueOnNative();
    }
  }

  playFromUserQueue(userQueueIndex: number): void {
    const state = usePlayerStore.getState();
    const { userQueue, isInUserQueue } = state.songlist;
    if (userQueueIndex < 0 || userQueueIndex >= userQueue.songs.length) return;

    const songsBefore = userQueue.songs.slice(0, userQueueIndex);
    const songsFromTarget = userQueue.songs.slice(userQueueIndex);

    const prevPlayedHistory = [...state.songlist.playedUserQueueHistory];
    const prevUserSongs = [...state.songlist.userQueue.songs];
    const prevIsInUserQueue = state.songlist.isInUserQueue;
    const prevProgress = state.playerProgress.progress;
    const prevBufferedProgress = state.playerProgress.bufferedProgress;
    const prevIsPlaying = state.playerState.isPlaying;
    const prevCurrentSong = state.songlist.currentSong;
    const prevDuration = state.playerState.currentDuration;

    usePlayerStore.setState((s) => {
      s.songlist.playedUserQueueHistory.push(...songsBefore);
      s.songlist.userQueue.songs = songsFromTarget;
      s.songlist.isInUserQueue = true;
      s.playerProgress.progress = 0;
      s.playerProgress.bufferedProgress = 0;
      s.playerState.isPlaying = true;
      s.songlist.currentSong = songsFromTarget[0] ?? null;
      s.playerState.currentDuration = songsFromTarget[0]?.duration
        ? Math.round(songsFromTarget[0].duration)
        : 0;
    });

    const nativeSongs = songsFromTarget.map(songToNativeQueueSong);
    this.#suppressNextQueueStateChanged = true;
    this.#plugin
      .clearUserQueue()
      .then(() =>
        this.#plugin.addToUserQueue({
          songs: nativeSongs,
          position: "last",
        }),
      )
      .then(() => {
        if (!isInUserQueue) {
          return this.#plugin.skipToNext();
        }
      })
      .catch((err) => {
        this.#suppressNextQueueStateChanged = false;
        logger.error(
          "[NativeQueueController] playFromUserQueue native sync failed",
          err,
        );
        usePlayerStore.setState((s) => {
          s.songlist.playedUserQueueHistory = prevPlayedHistory;
          s.songlist.userQueue.songs = prevUserSongs;
          s.songlist.isInUserQueue = prevIsInUserQueue;
          s.playerProgress.progress = prevProgress;
          s.playerProgress.bufferedProgress = prevBufferedProgress;
          s.playerState.isPlaying = prevIsPlaying;
          s.songlist.currentSong = prevCurrentSong;
          s.playerState.currentDuration = prevDuration;
        });
      });
  }

  playSong(song: ISong, _sourceName?: string): void {
    this.setSongList([song], 0);
  }

  playNext(): void {
    this.#plugin
      .skipToNext()
      .catch((err) =>
        logger.error("[NativeQueueController] playNext failed", err),
      );
  }

  playPrev(): void {
    this.#plugin
      .skipToPrevious()
      .catch((err) =>
        logger.error("[NativeQueueController] playPrev failed", err),
      );
  }

  toggleShuffle(): void {
    const current = usePlayerStore.getState().songlist.isShuffleActive;
    this.setShuffleState(!current);
  }

  setShuffleState(enabled: boolean): void {
    const current = usePlayerStore.getState().songlist.isShuffleActive;
    if (current === enabled) return;

    const prevOriginalContextSongs =
      usePlayerStore.getState().songlist.originalContextSongs;
    const prevOriginalUserSongs =
      usePlayerStore.getState().songlist.originalUserSongs;
    const prevUserSongs = usePlayerStore.getState().songlist.userQueue.songs;

    this.#plugin.setShuffle({ enabled }).catch((err) => {
      logger.error("[NativeQueueController] setShuffleState failed", err);
      usePlayerStore.setState((state) => {
        state.songlist.isShuffleActive = current;
        state.songlist.originalContextSongs = prevOriginalContextSongs;
        state.songlist.originalUserSongs = prevOriginalUserSongs;
        state.songlist.userQueue.songs = prevUserSongs;
      });
    });

    usePlayerStore.setState((state) => {
      if (enabled) {
        const currentSong = getCurrentSong(state.songlist);
        const sourceSongs =
          state.songlist.sourceQueue.songs.length > 0
            ? state.songlist.sourceQueue.songs
            : state.songlist.originalContextSongs.length > 0
              ? state.songlist.originalContextSongs
              : state.songlist.contextQueue.songs;
        const currentIndex = currentSong
          ? sourceSongs.findIndex((song) => song.id === currentSong.id)
          : 0;
        state.songlist.contextQueue.songs = buildContextQueueSongs(
          sourceSongs,
          currentIndex >= 0 ? currentIndex : 0,
          state.playerState.loopState,
          true,
        );
        state.songlist.contextQueue.currentIndex = 0;
        state.songlist.sourceQueue.songs = [...sourceSongs];
        state.songlist.originalContextSongs = [...sourceSongs];
        if (state.songlist.userQueue.songs.length > 0) {
          state.songlist.originalUserSongs = [
            ...state.songlist.userQueue.songs,
          ];
        }
      } else {
        if (state.songlist.originalUserSongs?.length) {
          state.songlist.userQueue.songs = [
            ...state.songlist.originalUserSongs,
          ];
        }
        state.songlist.originalUserSongs = undefined;
        rebuildContextQueueForLoopState(
          state.songlist,
          state.playerState.loopState,
        );
      }
      state.songlist.isShuffleActive = enabled;
    });
    this.#updateContextQueueOnNative();
  }

  setLoopState(state: LoopState): void {
    const current = usePlayerStore.getState().playerState.loopState;
    this.#plugin
      .setRepeatMode({ mode: loopStateToNative(state) })
      .catch((err) => {
        logger.error("[NativeQueueController] setLoopState failed", err);
        usePlayerStore.setState((s) => {
          s.playerState.loopState = current;
        });
      });

    usePlayerStore.setState((s) => {
      s.playerState.loopState = state;
      rebuildContextQueueForLoopState(s.songlist, state);
    });
    this.#updateContextQueueOnNative();
  }

  toggleLoop(): void {
    const current = usePlayerStore.getState().playerState.loopState;
    const next = ((current + 1) % 3) as LoopState;
    this.setLoopState(next);
  }

  play(): void {
    const currentIsPlaying = usePlayerStore.getState().playerState.isPlaying;
    this.#plugin.play().catch((err) => {
      logger.error("[NativeQueueController] play failed", err);
      usePlayerStore.setState((s) => {
        s.playerState.isPlaying = currentIsPlaying;
      });
    });
    usePlayerStore.setState((s) => {
      s.playerState.isPlaying = true;
    });
  }

  pause(): void {
    const currentIsPlaying = usePlayerStore.getState().playerState.isPlaying;
    this.#plugin.pause().catch((err) => {
      logger.error("[NativeQueueController] pause failed", err);
      usePlayerStore.setState((state) => {
        state.playerState.isPlaying = currentIsPlaying;
      });
    });
    usePlayerStore.setState((state) => {
      state.playerState.isPlaying = false;
    });
  }

  togglePlayPause(): void {
    const isPlaying = usePlayerStore.getState().playerState.isPlaying;
    if (isPlaying) {
      this.pause();
    } else {
      this.play();
    }
  }

  seek(seconds: number): void {
    const prevProgress = usePlayerStore.getState().playerProgress.progress;
    this.#plugin.seek({ position: Math.max(0, seconds) }).catch((err) => {
      logger.error("[NativeQueueController] seek failed", err);
      usePlayerStore.setState((state) => {
        state.playerProgress.progress = prevProgress;
      });
    });

    usePlayerStore.setState((state) => {
      state.playerProgress.progress = seconds;
      state.playerProgress.seekCount =
        (state.playerProgress.seekCount ?? 0) + 1;
    });
  }

  async prepareHandoffPlayback(
    progressSeconds: number,
    options: { autoplay: boolean },
  ): Promise<void> {
    await this.#syncContextQueueToNative(options.autoplay);
    await this.#plugin.seek({ position: Math.max(0, progressSeconds) });
  }

  setVolume(volume: number): void {
    const runtime = getRuntime();
    if (runtime !== "capacitor-android" && runtime !== "electron") return;

    const clamped = Math.max(0, Math.min(100, Math.round(volume)));
    if (runtime === "electron") {
      // Desktop bridge maps this compatibility method to player volume, not
      // OS output volume.
      usePlayerStore.setState((state) => {
        state.playerState.volume = clamped;
      });
    }
    this.#plugin.setSystemVolume({ value: clamped / 100 }).catch(() => {
      /* ignore */
    });
  }

  setPlayRadio(_list: Radio[], _index: number): void {
    logger.info(
      "[NativeQueueController] setPlayRadio: delegating to legacy path",
    );
  }

  addToQueueNext(songs: ISong[]): void {
    const prevUserQueue = [
      ...usePlayerStore.getState().songlist.userQueue.songs,
    ];
    const nativeSongs = songs.map(songToNativeQueueSong);
    this.#plugin
      .addToUserQueue({ songs: nativeSongs, position: "next" })
      .catch((err) => {
        logger.error("[NativeQueueController] addToQueueNext failed", err);
        usePlayerStore.setState((state) => {
          state.songlist.userQueue.songs = prevUserQueue;
        });
      });

    const { isInUserQueue } = usePlayerStore.getState().songlist;
    usePlayerStore.setState((state) => {
      if (isInUserQueue) {
        const queue = state.songlist.userQueue.songs;
        const insertAt = Math.min(1, queue.length);
        queue.splice(insertAt, 0, ...songs);
      } else {
        state.songlist.userQueue.songs = setNextOnUserQueue(
          state.songlist.userQueue.songs,
          songs,
        );
      }
    });
  }

  addToQueueLast(songs: ISong[]): void {
    const prevUserQueue = [
      ...usePlayerStore.getState().songlist.userQueue.songs,
    ];
    const nativeSongs = songs.map(songToNativeQueueSong);
    this.#plugin
      .addToUserQueue({ songs: nativeSongs, position: "last" })
      .catch((err) => {
        logger.error("[NativeQueueController] addToQueueLast failed", err);
        usePlayerStore.setState((state) => {
          state.songlist.userQueue.songs = prevUserQueue;
        });
      });

    usePlayerStore.setState((state) => {
      state.songlist.userQueue.songs = setLastOnUserQueue(
        state.songlist.userQueue.songs,
        songs,
      );
    });
  }

  removeFromQueue(id: string, tier?: "context" | "user"): void {
    const state = usePlayerStore.getState();
    const detectedTier = tier ?? findSongTier(state.songlist, id);

    if (detectedTier === "user") {
      const index = state.songlist.userQueue.songs.findIndex(
        (s) => s.id === id,
      );
      if (index === -1) return;

      const prevUserSongs = [...state.songlist.userQueue.songs];
      const prevIsInUserQueue = state.songlist.isInUserQueue;

      this.#plugin.removeFromUserQueue({ indices: [index] }).catch((err) => {
        logger.error("[NativeQueueController] removeFromQueue failed", err);
        usePlayerStore.setState((s) => {
          s.songlist.userQueue.songs = prevUserSongs;
          s.songlist.isInUserQueue = prevIsInUserQueue;
        });
      });

      usePlayerStore.setState((s) => {
        s.songlist.userQueue.songs.splice(index, 1);
        if (
          s.songlist.isInUserQueue &&
          index === 0 &&
          s.songlist.userQueue.songs.length === 0
        ) {
          s.songlist.isInUserQueue = false;
        }
      });
      return;
    }

    if (detectedTier === "context") {
      const { contextQueue, isInUserQueue } = state.songlist;
      const removedIndex = contextQueue.songs.findIndex((s) => s.id === id);
      if (removedIndex === -1) return;

      const newSongs = [...contextQueue.songs];
      newSongs.splice(removedIndex, 1);

      if (newSongs.length === 0) return;

      let newIndex: number;
      if (isInUserQueue) {
        newIndex =
          contextQueue.currentIndex -
          (removedIndex <= contextQueue.currentIndex ? 1 : 0);
      } else if (removedIndex < contextQueue.currentIndex) {
        newIndex = contextQueue.currentIndex - 1;
      } else if (removedIndex === contextQueue.currentIndex) {
        newIndex = Math.min(contextQueue.currentIndex, newSongs.length - 1);
      } else {
        newIndex = contextQueue.currentIndex;
      }
      newIndex = Math.max(newIndex, 0);

      const prevSongs = [...contextQueue.songs];
      const prevIndex = contextQueue.currentIndex;
      const prevOriginalSongs = [...state.songlist.originalContextSongs];
      const prevProgress = state.playerProgress.progress;
      const prevBufferedProgress = state.playerProgress.bufferedProgress;

      usePlayerStore.setState((s) => {
        s.songlist.contextQueue.songs = newSongs;
        s.songlist.contextQueue.currentIndex = newIndex;
        s.songlist.originalContextSongs =
          s.songlist.originalContextSongs.filter((s) => s.id !== id);
        if (removedIndex === contextQueue.currentIndex && !isInUserQueue) {
          s.playerProgress.progress = 0;
          s.playerProgress.bufferedProgress = 0;
        }
      });

      const nativeSongs = newSongs.map(songToNativeQueueSong);
      this.#plugin
        .updateContextQueue({
          songs: nativeSongs,
          currentIndex: newIndex,
        })
        .catch((err) => {
          logger.error(
            "[NativeQueueController] removeFromQueue context failed",
            err,
          );
          usePlayerStore.setState((s) => {
            s.songlist.contextQueue.songs = prevSongs;
            s.songlist.contextQueue.currentIndex = prevIndex;
            s.songlist.originalContextSongs = prevOriginalSongs;
            s.playerProgress.progress = prevProgress;
            s.playerProgress.bufferedProgress = prevBufferedProgress;
          });
        });
    }
  }

  reorderQueue(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex) return;

    const state = usePlayerStore.getState();
    const { contextQueue, userQueue } = state.songlist;
    const contextPlayedCount = contextQueue.currentIndex + 1;

    const fromInUser =
      fromIndex >= contextPlayedCount &&
      fromIndex < contextPlayedCount + userQueue.songs.length;
    const toInUser =
      toIndex >= contextPlayedCount &&
      toIndex < contextPlayedCount + userQueue.songs.length;
    const fromInUpcoming =
      fromIndex >= contextPlayedCount + userQueue.songs.length;
    const toInUpcoming = toIndex >= contextPlayedCount + userQueue.songs.length;

    if (fromInUser && toInUser) {
      const localFrom = fromIndex - contextPlayedCount;
      const localTo = toIndex - contextPlayedCount;
      const newUserSongs = [...userQueue.songs];
      const [moved] = newUserSongs.splice(localFrom, 1);
      newUserSongs.splice(localTo, 0, moved);

      const prevUserSongs = [...userQueue.songs];

      usePlayerStore.setState((s) => {
        s.songlist.userQueue.songs = newUserSongs;
      });

      const nativeSongs = newUserSongs.map(songToNativeQueueSong);
      this.#plugin
        .clearUserQueue()
        .then(() => {
          if (nativeSongs.length > 0) {
            return this.#plugin.addToUserQueue({
              songs: nativeSongs,
              position: "last",
            });
          }
        })
        .catch((err) => {
          logger.error("[NativeQueueController] reorderQueue failed", err);
          usePlayerStore.setState((s) => {
            s.songlist.userQueue.songs = prevUserSongs;
          });
        });
      return;
    }

    if (fromInUpcoming && toInUpcoming) {
      const actualFrom = fromIndex - userQueue.songs.length;
      const actualTo = toIndex - userQueue.songs.length;
      const newContextSongs = [...contextQueue.songs];
      const [moved] = newContextSongs.splice(actualFrom, 1);
      newContextSongs.splice(actualTo, 0, moved);

      const prevContextSongs = [...contextQueue.songs];

      usePlayerStore.setState((s) => {
        s.songlist.contextQueue.songs = newContextSongs;
      });

      this.#plugin
        .reorderContextQueue({ fromIndex: actualFrom, toIndex: actualTo })
        .catch((err) => {
          logger.error(
            "[NativeQueueController] reorderQueue context failed",
            err,
          );
          usePlayerStore.setState((s) => {
            s.songlist.contextQueue.songs = prevContextSongs;
          });
        });
    }
  }

  clearUserQueue(): void {
    const state = usePlayerStore.getState();
    const prevUserSongs = [...state.songlist.userQueue.songs];
    const prevHistory = [...state.songlist.playedUserQueueHistory];
    const prevIsInUserQueue = state.songlist.isInUserQueue;

    this.#plugin.clearUserQueue().catch((err) => {
      logger.error("[NativeQueueController] clearUserQueue failed", err);
      usePlayerStore.setState((s) => {
        s.songlist.userQueue.songs = prevUserSongs;
        s.songlist.playedUserQueueHistory = prevHistory;
        s.songlist.isInUserQueue = prevIsInUserQueue;
      });
    });

    usePlayerStore.setState((state) => {
      state.songlist.userQueue.songs = [];
      state.songlist.playedUserQueueHistory = [];
      if (state.songlist.isInUserQueue) {
        state.songlist.isInUserQueue = false;
      }
    });
  }

  clearPlayerState(): void {
    this.#queueSynced = false;
    this.#plugin
      .clear()
      .catch((err) =>
        logger.error("[NativeQueueController] clear failed", err),
      );
  }

  handleSongEnded(): void {
    // Native handles this internally
  }

  hasNextSong(): boolean {
    return true;
  }

  hasPrevSong(): boolean {
    return true;
  }

  consumeNativeDrivenTransition(): boolean {
    const val = this.#nativeDrivenTransition;
    this.#nativeDrivenTransition = false;
    return val;
  }

  getState(): QueueControllerState {
    const store = usePlayerStore.getState();
    const { songlist, playerState, playerProgress } = store;
    return {
      currentSong: getCurrentSong(songlist),
      contextQueue: {
        songs: songlist.contextQueue.songs,
        currentIndex: songlist.contextQueue.currentIndex,
        sourceId: songlist.contextQueue.sourceId,
        sourceName: songlist.contextQueue.sourceName,
      },
      userQueue: songlist.userQueue.songs,
      isInUserQueue: songlist.isInUserQueue,
      isShuffleActive: songlist.isShuffleActive,
      loopState: playerState.loopState,
      isPlaying: playerState.isPlaying,
      progress: playerProgress.progress,
      duration: playerState.currentDuration,
      mediaType: playerState.mediaType,
    };
  }

  subscribe<T extends QueueControllerEvent>(
    event: T,
    listener: QueueControllerListener<T>,
  ): () => void {
    if (!this.#listeners.has(event)) {
      this.#listeners.set(event, new Set());
    }
    const set = this.#listeners.get(event)!;
    set.add(listener as QueueControllerListener<QueueControllerEvent>);
    return () => {
      set.delete(listener as QueueControllerListener<QueueControllerEvent>);
    };
  }

  dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#clearTerminalPlaybackResetTimer();
    for (const handle of this.#nativeListenerHandles) {
      handle.remove();
    }
    this.#nativeListenerHandles = [];
    this.#listeners.clear();
  }

  async syncFromNative(): Promise<void> {
    try {
      const nativeState = await this.#plugin.getFullState();
      if (nativeState.currentSongId) {
        this.#queueSynced = true;
      }

      const isRestoredColdStart =
        usePlayerStore.getState().songlist.contextQueue.songs.length === 0 &&
        (nativeState.isRestored || nativeState.contextQueue.songs.length > 0);

      usePlayerStore.setState((s) => {
        s.playerState.isPlaying = nativeState.isPlaying;
        s.playerProgress.progress = nativeState.currentTime;
        s.playerProgress.bufferedProgress = nativeState.currentTime;
        s.playerState.currentDuration = nativeState.duration;

        s.songlist.contextQueue.currentIndex =
          nativeState.contextQueue.currentIndex;
        s.songlist.isInUserQueue = nativeState.isInUserQueue;
        s.songlist.isShuffleActive = nativeState.isShuffleActive;

        if (nativeState.contextQueue.sourceId) {
          s.songlist.contextQueue.sourceId = nativeSourceIdToQueueSourceId(
            nativeState.contextQueue.sourceId,
          );
        }
        if (nativeState.contextQueue.sourceName !== null) {
          s.songlist.contextQueue.sourceName =
            nativeState.contextQueue.sourceName;
        }

        if (isRestoredColdStart) {
          s.playerState.mediaType = "song";
          s.songlist.contextQueue.songs = nativeState.contextQueue.songs.map(
            nativeQueueSongToISong,
          );
          s.songlist.userQueue.songs = nativeState.userQueue.map(
            nativeQueueSongToISong,
          );
          s.songlist.originalContextSongs =
            nativeState.originalContextSongs.map(nativeQueueSongToISong);
          s.songlist.originalUserSongs = nativeState.originalUserSongs.map(
            nativeQueueSongToISong,
          );
          s.songlist.playedUserQueueHistory =
            nativeState.playedUserQueueHistory.map(nativeQueueSongToISong);
          s.songlist.shuffleHistory = nativeState.shuffleHistory;
          s.songlist.shuffleStartHistory = nativeState.shuffleStartHistory;
        } else {
          const nativeContextIds = nativeState.contextQueue.songs.map(
            (ns) => ns.id,
          );
          if (nativeContextIds.length > 0) {
            const songMap = new Map(
              s.songlist.contextQueue.songs.map((song) => [song.id, song]),
            );
            const reordered = nativeContextIds
              .map((id) => songMap.get(id))
              .filter((song): song is ISong => song != null);
            if (reordered.length === s.songlist.contextQueue.songs.length) {
              s.songlist.contextQueue.songs = reordered;
            }
          }

          const nativeUserQueueIds = nativeState.userQueue.map((ns) => ns.id);
          if (nativeUserQueueIds.length > 0) {
            const userSongMap = new Map(
              s.songlist.userQueue.songs.map((song) => [song.id, song]),
            );
            const reorderedUser = nativeUserQueueIds
              .map((id) => userSongMap.get(id))
              .filter((song): song is ISong => song != null);
            if (reorderedUser.length === s.songlist.userQueue.songs.length) {
              s.songlist.userQueue.songs = reorderedUser;
            } else {
              s.songlist.userQueue.songs = s.songlist.userQueue.songs.filter(
                (song) => new Set(nativeUserQueueIds).has(song.id),
              );
            }
          } else {
            s.songlist.userQueue.songs = [];
          }
        }

        if (nativeState.currentSongId) {
          let song = s.songlist.userQueue.songs.find(
            (song) => song.id === nativeState.currentSongId,
          );
          if (!song) {
            song = s.songlist.contextQueue.songs.find(
              (song) => song.id === nativeState.currentSongId,
            );
          }
          if (song) {
            s.songlist.currentSong = song;
          }
        }

        switch (nativeState.loopState) {
          case "off":
            s.playerState.loopState = LoopState.Off;
            break;
          case "one":
            s.playerState.loopState = LoopState.One;
            break;
          case "all":
            s.playerState.loopState = LoopState.All;
            break;
        }

        if (nativeState.isShuffleActive && !isRestoredColdStart) {
          const nativeOriginalIds = nativeState.originalContextSongs.map(
            (ns) => ns.id,
          );
          if (nativeOriginalIds.length > 0) {
            const origMap = new Map(
              s.songlist.originalContextSongs.map((song) => [song.id, song]),
            );
            const synced = nativeOriginalIds
              .map((id) => origMap.get(id))
              .filter((song): song is ISong => song != null);
            if (synced.length === nativeOriginalIds.length) {
              s.songlist.originalContextSongs = synced;
            }
          }

          const nativeOriginalUserIds = nativeState.originalUserSongs.map(
            (ns) => ns.id,
          );
          if (nativeOriginalUserIds.length > 0) {
            const origUserMap = new Map(
              (s.songlist.originalUserSongs ?? []).map((song) => [
                song.id,
                song,
              ]),
            );
            const syncedUser = nativeOriginalUserIds
              .map((id) => origUserMap.get(id))
              .filter((song): song is ISong => song != null);
            if (syncedUser.length === nativeOriginalUserIds.length) {
              s.songlist.originalUserSongs = syncedUser;
            }
          } else {
            s.songlist.originalUserSongs = undefined;
          }
        } else if (!nativeState.isShuffleActive && !isRestoredColdStart) {
          s.songlist.originalContextSongs = [];
          s.songlist.originalUserSongs = undefined;
          s.songlist.shuffleHistory = [];
        }
      });

      if (isRestoredColdStart) {
        this.#nativeDrivenTransition = true;
        this.#resolveFullSongs();
      }
    } catch (err) {
      logger.error("[NativeQueueController] syncFromNative failed", err);
    }
  }

  async #resolveFullSongs(): Promise<void> {
    try {
      const state = usePlayerStore.getState().songlist;
      const allIds = new Set<string>();
      for (const song of state.contextQueue.songs) allIds.add(song.id);
      for (const song of state.userQueue.songs) allIds.add(song.id);

      if (allIds.size === 0) return;

      const result = await this.#plugin.resolveSongs({
        ids: [...allIds],
      });

      const resolvedMap = new Map<string, ISong>();
      for (const raw of result.songs) {
        const song = raw as unknown as ISong;
        if (song.id) resolvedMap.set(song.id, song);
      }

      const unresolvedIds = [...allIds].filter((id) => !resolvedMap.has(id));
      if (unresolvedIds.length > 0) {
        try {
          const { songs } = await import("@/service/songs");
          const fetchedSongs = await Promise.all(
            unresolvedIds.map((id) => songs.getSong(id).catch(() => null)),
          );
          for (const song of fetchedSongs) {
            if (song && song.id) {
              resolvedMap.set(song.id, song);
            }
          }
        } catch (fetchErr) {
          logger.warn(
            "[NativeQueueController] resolveFullSongs online fallback failed",
            fetchErr,
          );
        }
      }

      if (resolvedMap.size === 0) return;

      usePlayerStore.setState((s) => {
        s.songlist.contextQueue.songs = s.songlist.contextQueue.songs.map(
          (song) => resolvedMap.get(song.id) ?? song,
        );
        s.songlist.userQueue.songs = s.songlist.userQueue.songs.map(
          (song) => resolvedMap.get(song.id) ?? song,
        );
        s.songlist.originalContextSongs = s.songlist.originalContextSongs.map(
          (song) => resolvedMap.get(song.id) ?? song,
        );
        if (s.songlist.originalUserSongs) {
          s.songlist.originalUserSongs = s.songlist.originalUserSongs.map(
            (song) => resolvedMap.get(song.id) ?? song,
          );
        }
        s.songlist.playedUserQueueHistory =
          s.songlist.playedUserQueueHistory.map(
            (song) => resolvedMap.get(song.id) ?? song,
          );
        if (s.songlist.currentSong) {
          s.songlist.currentSong =
            resolvedMap.get(s.songlist.currentSong.id) ??
            s.songlist.currentSong;
        }
      });
    } catch (err) {
      logger.error("[NativeQueueController] resolveFullSongs failed", err);
    }
  }

  #wireNativeEvents() {
    this.#addNativeListener("queueStateChanged", (event) => {
      this.#clearTerminalPlaybackResetTimer();

      if (this.#suppressNextQueueStateChanged) {
        this.#suppressNextQueueStateChanged = false;
        return;
      }

      logger.info(
        `[NativeQueueController] queueStateChanged: index=${event.currentIndex} song=${event.songId} isInUserQueue=${event.isInUserQueue} reason=${event.reason}`,
      );

      this.#nativeDrivenTransition = true;
      usePlayerStore.setState((state) => {
        state.songlist.contextQueue.currentIndex = event.currentIndex;
        state.playerProgress.progress = 0;
        state.playerProgress.bufferedProgress = 0;
        state.playerState.isPlaying = true;

        const wasInUserQueue = state.songlist.isInUserQueue;
        state.songlist.isInUserQueue = event.isInUserQueue;

        if (event.reason === "next" || event.reason === "ended") {
          if (wasInUserQueue && state.songlist.userQueue.songs.length > 0) {
            const consumed = state.songlist.userQueue.songs.shift()!;
            state.songlist.playedUserQueueHistory.push(consumed);
          }
        } else if (event.reason === "previous") {
          if (event.isInUserQueue && !wasInUserQueue) {
            const restored = state.songlist.playedUserQueueHistory.pop();
            if (restored) {
              state.songlist.userQueue.songs.unshift(restored);
            }
          } else if (
            event.isInUserQueue &&
            wasInUserQueue &&
            state.songlist.playedUserQueueHistory.length > 0
          ) {
            const restored = state.songlist.playedUserQueueHistory.pop();
            if (restored) {
              state.songlist.userQueue.songs.unshift(restored);
            }
          }
        }

        let song = state.songlist.userQueue.songs.find(
          (s) => s.id === event.songId,
        );
        if (!song) {
          song = state.songlist.contextQueue.songs.find(
            (s) => s.id === event.songId,
          );
        }

        if (song) {
          state.songlist.currentSong = song;
          state.playerState.currentDuration = song.duration
            ? Math.round(song.duration)
            : 0;
        }
      });
    });

    this.#addNativeListener("playbackStateChanged", (event) => {
      if (event.state === "playing") {
        this.#clearTerminalPlaybackResetTimer();
        usePlayerStore.setState((s) => {
          s.playerState.isPlaying = true;
          s.playerState.isBuffering = false;
        });
      } else if (event.state === "loading") {
        this.#clearTerminalPlaybackResetTimer();
        usePlayerStore.setState((s) => {
          s.playerState.isBuffering = true;
        });
      } else if (
        event.state === "paused" ||
        event.state === "stopped" ||
        event.state === "ended" ||
        event.state === "idle" ||
        event.state === "failed"
      ) {
        usePlayerStore.setState((s) => {
          s.playerState.isPlaying = false;
        });
        if (event.state === "ended" || event.state === "stopped") {
          this.#scheduleTerminalPlaybackReset();
        }
      }
    });

    this.#addNativeListener("queueContentsChanged", (event) => {
      logger.info(
        `[NativeQueueController] queueContentsChanged: reason=${event.reason}`,
      );
      if (event.reason === "shuffle" || event.reason === "unshuffle") {
        this.syncFromNative();
      }
    });

    this.#addNativeListener("bufferingChanged", (event) => {
      usePlayerStore.setState((s) => {
        s.playerState.isBuffering = event.isBuffering;
      });
    });
  }

  #addNativeListener<TEvent extends keyof NativeAudioEvents>(
    event: TEvent,
    listener: (payload: NativeAudioEvents[TEvent]) => void,
  ) {
    this.#plugin
      .addListener(event, listener)
      .then((handle) => {
        if (this.#disposed) {
          handle.remove();
        } else {
          this.#nativeListenerHandles.push(handle);
        }
      })
      .catch((err) =>
        logger.error(
          `[NativeQueueController] addListener(${event}) failed`,
          err,
        ),
      );
  }

  #clearTerminalPlaybackResetTimer() {
    if (!this.#terminalPlaybackResetTimer) return;
    clearTimeout(this.#terminalPlaybackResetTimer);
    this.#terminalPlaybackResetTimer = null;
  }

  #scheduleTerminalPlaybackReset() {
    this.#clearTerminalPlaybackResetTimer();
    this.#terminalPlaybackResetTimer = setTimeout(() => {
      this.#terminalPlaybackResetTimer = null;

      if (this.#disposed) return;
      if (this.#nativeDrivenTransition) {
        this.#nativeDrivenTransition = false;
        return;
      }

      logger.info(
        "[NativeQueueController] terminal playback reached end, seeking back to zero",
      );

      this.#plugin
        .seek({ position: 0 })
        .catch((err) =>
          logger.error(
            "[NativeQueueController] terminal reset seek failed",
            err,
          ),
        );

      usePlayerStore.setState((state) => {
        state.playerProgress.progress = 0;
        state.playerProgress.bufferedProgress = 0;
        state.playerState.isBuffering = false;
      });
    }, TERMINAL_PLAYBACK_RESET_DELAY_MS);
  }
}
