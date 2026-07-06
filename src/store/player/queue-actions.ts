import type { Draft } from "immer";
import { seekPlaybackTarget } from "@/player/playback/backend-registry";
import { getNativeQueueController } from "@/player/queue-controller";
import { useSleepTimerStore } from "@/store/sleep-timer.store";
import { LanControlMessageType } from "@/types/lanControl";
import type {
  IPlayerActions,
  IPlayerContext,
  ISongList,
  QueueSourceId,
  QueueTier,
} from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { Radio } from "@/types/responses/radios";
import type { ISong } from "@/types/responses/song";
import { areSongListsEqual } from "@/utils/compareSongLists";
import { logger } from "@/utils/logger";
import {
  getMaxShuffleHistory,
  getMaxShuffleStartHistory,
  pickRandomStartIndex,
  pushToHistory,
} from "@/utils/songListFunctions";
import { transitionHandleSongEnded } from "./queue-transitions";
import {
  advancePlaybackQueue,
  appendPlaybackQueueCycle,
  applyShuffleOff,
  applyShuffleOn,
  buildContextQueueSongs,
  emptyContextQueue,
  findSongTier,
  getCurrentSong,
  hasNextEffectiveSong,
  hasPrevEffectiveSong,
  isPlayingOneSong,
  normalizeSourceId,
  sendAddToQueueRemote,
  setLastOnUserQueue,
  setNextOnUserQueue,
  trimQueueToWindow,
} from "./queue-utils";

interface SharedDeps {
  set: (fn: (state: Draft<IPlayerContext>) => void) => void;
  get: () => IPlayerContext;
  isRemoteActive: () => boolean;
  remoteSend: (type: LanControlMessageType, data?: unknown) => boolean;
  clearSonglistState: (state: Draft<ISongList>) => void;
}

const PREV_SEEK_THRESHOLD = 3;
const NEXT_SONG_DEBOUNCE_MS = 100;
const PREV_SONG_DEBOUNCE_MS = 100;

let lastNextSongTime = 0;
let lastPrevSongTime = 0;

function resetUserQueue(state: Draft<ISongList>) {
  state.userQueue = { songs: [] };
  state.isInUserQueue = false;
  state.playedUserQueueHistory = [];
}

function sendSongListRemote(
  remoteSend: (type: LanControlMessageType, data?: unknown) => boolean,
  songlist: ISong[],
  index: number,
  shuffle: boolean,
  sourceId?:
    | QueueSourceId
    | { albumId: string }
    | { playlistId: string }
    | null,
  sourceName?: string,
) {
  if (songlist.length === 0) return;
  const normalized = normalizeSourceId(sourceId);
  if (normalized) {
    if (normalized.type === "album") {
      const messageType = shuffle
        ? LanControlMessageType.PLAY_ALBUM_SHUFFLE
        : LanControlMessageType.PLAY_ALBUM;
      remoteSend(messageType, {
        albumId: normalized.id,
        songIndex: index,
      });
    } else if (normalized.type === "playlist") {
      const messageType = shuffle
        ? LanControlMessageType.PLAY_PLAYLIST_SHUFFLE
        : LanControlMessageType.PLAY_PLAYLIST;
      remoteSend(messageType, {
        playlistId: normalized.id,
        songIndex: index,
      });
    } else {
      remoteSend(LanControlMessageType.CLEAR_QUEUE);
      remoteSend(LanControlMessageType.ADD_TO_QUEUE, {
        songIds: songlist.map((song) => song.id),
      });
      const targetSong = songlist[index];
      if (targetSong) {
        remoteSend(LanControlMessageType.PLAY_SONG, {
          songId: targetSong.id,
        });
      }
      if (shuffle) {
        remoteSend(LanControlMessageType.SET_SHUFFLE, {
          enabled: true,
        });
      }
    }
  } else {
    remoteSend(LanControlMessageType.CLEAR_QUEUE);
    remoteSend(LanControlMessageType.ADD_TO_QUEUE, {
      songIds: songlist.map((song) => song.id),
    });
    const targetSong = songlist[index];
    if (targetSong) {
      remoteSend(LanControlMessageType.PLAY_SONG, {
        songId: targetSong.id,
      });
    }
    if (shuffle) {
      remoteSend(LanControlMessageType.SET_SHUFFLE, {
        enabled: true,
      });
    }
  }
}

export function createQueueActions(shared: SharedDeps) {
  const { set, get, isRemoteActive, remoteSend, clearSonglistState } = shared;

  return {
    setSongList: (
      songlist: ISong[],
      index?: number | null,
      shuffle = false,
      sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
      sourceName?: string,
    ) => {
      if (!songlist || songlist.length === 0) return;

      let targetIndex = index;
      if (shuffle && (targetIndex === null || targetIndex === undefined)) {
        const startHistory = get().songlist.shuffleStartHistory ?? [];
        targetIndex = pickRandomStartIndex(
          songlist.length,
          startHistory,
          (i) => songlist[i].id,
        );
      } else if (targetIndex === null || targetIndex === undefined) {
        targetIndex = 0;
      }
      targetIndex = Math.max(0, Math.min(targetIndex, songlist.length - 1));

      if (isRemoteActive()) {
        sendSongListRemote(
          remoteSend,
          songlist,
          targetIndex,
          shuffle,
          sourceId,
          sourceName,
        );
        set((state) => {
          state.playerState.isPlaying = true;
        });
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.setSongList(
          songlist,
          targetIndex,
          shuffle,
          sourceId,
          sourceName,
        );
        return;
      }

      const normalizedId = normalizeSourceId(sourceId);
      const { contextQueue, sourceQueue } = get().songlist;
      const sourceSongs =
        sourceQueue.songs.length > 0 ? sourceQueue.songs : contextQueue.songs;
      const listsAreEqual = areSongListsEqual(sourceSongs, songlist);
      const currentSong = getCurrentSong(get().songlist);
      const sameIndex = currentSong?.id === songlist[targetIndex]?.id;
      const sameSourceId =
        JSON.stringify(contextQueue.sourceId) === JSON.stringify(normalizedId);

      if (listsAreEqual && sameIndex && !shuffle) {
        set((state) => {
          state.playerState.isPlaying = true;
        });
        return;
      }

      if (listsAreEqual && !sameIndex && !shuffle && sameSourceId) {
        const queueSongs = buildContextQueueSongs(
          songlist,
          targetIndex,
          get().playerState.loopState,
          false,
        );
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.songlist.contextQueue.songs = queueSongs;
          state.songlist.contextQueue.currentIndex = 0;
          state.songlist.sourceQueue.currentIndex = targetIndex;
          resetUserQueue(state.songlist);
          if (sourceName !== undefined) {
            state.songlist.contextQueue.sourceName = sourceName || null;
            state.songlist.sourceQueue.sourceName = sourceName || null;
          }
        });
        return;
      }

      if (shuffle) {
        const startHistory = get().songlist.shuffleStartHistory ?? [];
        const startSong = songlist[targetIndex];
        const queueSongs = buildContextQueueSongs(
          songlist,
          targetIndex,
          get().playerState.loopState,
          true,
        );
        const updatedStartHistory = pushToHistory(
          startHistory,
          startSong.id,
          getMaxShuffleStartHistory(songlist.length),
        );

        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.songlist.contextQueue = {
            ...emptyContextQueue(),
            songs: queueSongs,
            currentIndex: 0,
            sourceId: normalizedId,
            sourceName:
              sourceName !== undefined
                ? sourceName || null
                : state.songlist.contextQueue.sourceName,
          };
          state.songlist.sourceQueue = {
            ...emptyContextQueue(),
            songs: [...songlist],
            currentIndex: targetIndex,
            sourceId: normalizedId,
            sourceName: state.songlist.contextQueue.sourceName,
          };
          resetUserQueue(state.songlist);
          state.songlist.originalContextSongs = [...songlist];
          state.songlist.radioList = [];
          state.songlist.shuffleHistory = [];
          state.songlist.isShuffleActive = true;
          state.songlist.shuffleStartHistory = updatedStartHistory;
          state.playerState.mediaType = "song";
          state.playerState.isPlaying = true;
        });
      } else {
        const queueSongs = buildContextQueueSongs(
          songlist,
          targetIndex,
          get().playerState.loopState,
          false,
        );
        const trimmed = trimQueueToWindow(queueSongs, 0);
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.songlist.contextQueue = {
            ...emptyContextQueue(),
            songs: trimmed.songs,
            currentIndex: 0,
            sourceId: normalizedId,
            sourceName:
              sourceName !== undefined
                ? sourceName || null
                : state.songlist.contextQueue.sourceName,
          };
          state.songlist.sourceQueue = {
            ...emptyContextQueue(),
            songs: [...songlist],
            currentIndex: targetIndex,
            sourceId: normalizedId,
            sourceName: state.songlist.contextQueue.sourceName,
          };
          resetUserQueue(state.songlist);
          state.songlist.originalContextSongs = [...songlist];
          state.songlist.radioList = [];
          state.songlist.shuffleHistory = [];
          state.songlist.isShuffleActive = false;
          state.playerState.mediaType = "song";
          state.playerState.isPlaying = true;
        });
      }
    },

    playFromQueue: (contextSongs: ISong[], contextIndex: number) => {
      if (!contextSongs || contextSongs.length === 0) return;
      contextIndex = Math.max(
        0,
        Math.min(contextIndex, contextSongs.length - 1),
      );

      if (isRemoteActive()) {
        const song = contextSongs[contextIndex];
        if (song) {
          remoteSend(LanControlMessageType.PLAY_AT_INDEX, {
            songIds: contextSongs.map((s) => s.id),
            index: contextIndex,
          });
        }
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.playFromQueue(contextSongs, contextIndex);
        return;
      }

      const { contextQueue } = get().songlist;
      const listsAreEqual = areSongListsEqual(contextQueue.songs, contextSongs);

      if (listsAreEqual) {
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.songlist.contextQueue.currentIndex = contextIndex;
          if (
            state.playerState.loopState === LoopState.All &&
            contextIndex >= state.songlist.contextQueue.songs.length - 1
          ) {
            appendPlaybackQueueCycle(state.songlist);
          }
          state.songlist.isInUserQueue = false;
        });
        return;
      }

      set((state) => {
        const trimmed = trimQueueToWindow(contextSongs, contextIndex);
        state.playerProgress.progress = 0;
        state.songlist.contextQueue = {
          ...emptyContextQueue(),
          songs: trimmed.songs,
          currentIndex: trimmed.currentIndex,
          sourceId: state.songlist.contextQueue.sourceId,
          sourceName: state.songlist.contextQueue.sourceName,
        };
        if (
          state.playerState.loopState === LoopState.All &&
          state.songlist.contextQueue.currentIndex >=
            state.songlist.contextQueue.songs.length - 1
        ) {
          appendPlaybackQueueCycle(state.songlist);
        }
        resetUserQueue(state.songlist);
        state.songlist.originalContextSongs = [];
        state.songlist.isShuffleActive = false;
        state.songlist.shuffleHistory = [];
        state.playerState.mediaType = "song";
        state.playerState.isPlaying = true;
        state.songlist.radioList = [];
      });
    },

    playFromUserQueue: (userQueueIndex: number) => {
      if (isRemoteActive()) {
        const { userQueue, contextQueue } = get().songlist;
        const song = userQueue.songs[userQueueIndex];
        if (song) {
          const allIds = [
            ...contextQueue.songs.map((s) => s.id),
            ...userQueue.songs.map((s) => s.id),
          ];
          const targetIndex = contextQueue.songs.length + userQueueIndex;
          remoteSend(LanControlMessageType.PLAY_AT_INDEX, {
            songIds: allIds,
            index: targetIndex,
          });
        }
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.playFromUserQueue(userQueueIndex);
        return;
      }

      const { userQueue } = get().songlist;
      if (userQueueIndex < 0 || userQueueIndex >= userQueue.songs.length)
        return;

      set((state) => {
        const songsBefore = state.songlist.userQueue.songs.splice(
          0,
          userQueueIndex,
        );
        state.songlist.playedUserQueueHistory.push(...songsBefore);
        state.songlist.isInUserQueue = true;
        state.playerProgress.progress = 0;
        state.playerState.isPlaying = true;
      });
    },

    playSong: (song: ISong, sourceName?: string) => {
      if (remoteSend(LanControlMessageType.PLAY_SONG, { songId: song.id })) {
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.playSong(song, sourceName);
        return;
      }

      const { isPlaying } = get().playerState;
      const songIsAlreadyPlaying = get().actions.checkActiveSong(song.id);
      if (songIsAlreadyPlaying && !isPlaying) {
        set((state) => {
          state.playerState.isPlaying = true;
        });
      } else {
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.mediaType = "song";
          state.songlist.contextQueue = {
            ...emptyContextQueue(),
            songs: [song],
            currentIndex: 0,
            sourceName:
              sourceName !== undefined
                ? sourceName || null
                : song.album || null,
          };
          state.songlist.sourceQueue = {
            ...emptyContextQueue(),
            songs: [song],
            currentIndex: 0,
            sourceName: state.songlist.contextQueue.sourceName,
          };
          resetUserQueue(state.songlist);
          state.songlist.originalContextSongs = [song];
          state.songlist.isShuffleActive = false;
          state.songlist.shuffleHistory = [];
          state.playerState.isPlaying = true;
          state.songlist.radioList = [];
        });
      }
    },

    setNextOnQueue: (
      list: ISong[],
      sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    ) => {
      if (isRemoteActive()) {
        if (list.length === 0) return;
        sendAddToQueueRemote(remoteSend, sourceId, list);
        return;
      }
      if (!list || list.length === 0) return;

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.addToQueueNext(list, sourceId);
        return;
      }

      set((state) => {
        state.songlist.userQueue.songs = setNextOnUserQueue(
          state.songlist.userQueue.songs,
          list,
        );
      });
    },

    setLastOnQueue: (
      list: ISong[],
      sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    ) => {
      if (isRemoteActive()) {
        if (list.length === 0) return;
        sendAddToQueueRemote(remoteSend, sourceId, list);
        return;
      }
      if (!list || list.length === 0) return;

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.addToQueueLast(list, sourceId);
        return;
      }

      set((state) => {
        state.songlist.userQueue.songs = setLastOnUserQueue(
          state.songlist.userQueue.songs,
          list,
        );
      });
    },

    removeSongFromQueue: (id: string, tier?: QueueTier) => {
      if (isRemoteActive()) return;

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.removeFromQueue(id, tier);
        return;
      }

      const detectedTier = tier ?? findSongTier(get().songlist, id);
      if (!detectedTier) return;

      if (detectedTier === "user") {
        const { userQueue, isInUserQueue } = get().songlist;
        const removedIndex = userQueue.songs.findIndex((s) => s.id === id);
        if (removedIndex === -1) return;

        const newUserSongs = [...userQueue.songs];
        newUserSongs.splice(removedIndex, 1);

        set((state) => {
          state.songlist.userQueue.songs = newUserSongs;
          if (
            isInUserQueue &&
            removedIndex === 0 &&
            newUserSongs.length === 0
          ) {
            state.songlist.isInUserQueue = false;
          }
        });
        return;
      }

      const { contextQueue, isInUserQueue } = get().songlist;
      const removedIndex = contextQueue.songs.findIndex((s) => s.id === id);
      if (removedIndex === -1) return;

      const newSongs = [...contextQueue.songs];
      newSongs.splice(removedIndex, 1);

      if (newSongs.length === 0) {
        get().actions.clearPlayerState();
        return;
      }

      const shouldResetProgress =
        removedIndex === contextQueue.currentIndex && !isInUserQueue;

      set((state) => {
        let newIndex: number;
        if (isInUserQueue) {
          newIndex =
            contextQueue.currentIndex -
            (removedIndex <= contextQueue.currentIndex ? 1 : 0);
        } else {
          if (removedIndex < contextQueue.currentIndex) {
            newIndex = contextQueue.currentIndex - 1;
          } else if (removedIndex === contextQueue.currentIndex) {
            newIndex = Math.min(contextQueue.currentIndex, newSongs.length - 1);
          } else {
            newIndex = contextQueue.currentIndex;
          }
        }
        newIndex = Math.max(newIndex, 0);

        state.songlist.contextQueue.songs = newSongs;
        state.songlist.contextQueue.currentIndex = newIndex;
        state.songlist.originalContextSongs =
          state.songlist.originalContextSongs.filter((s) => s.id !== id);
        if (shouldResetProgress) {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
        }
      });
    },

    clearUserQueue: () => {
      if (isRemoteActive()) {
        remoteSend(LanControlMessageType.CLEAR_QUEUE);
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.clearUserQueue();
        return;
      }

      set((state) => {
        state.songlist.userQueue.songs = [];
        state.songlist.playedUserQueueHistory = [];
        if (state.songlist.isInUserQueue) {
          state.songlist.isInUserQueue = false;
        }
      });
    },

    reorderQueue: (fromIndex: number, toIndex: number) => {
      if (isRemoteActive()) return;

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.reorderQueue(fromIndex, toIndex);
        return;
      }

      if (fromIndex === toIndex) return;

      const { contextQueue, userQueue } = get().songlist;
      const contextPlayedCount = contextQueue.currentIndex + 1;

      const fromInUser =
        fromIndex >= contextPlayedCount &&
        fromIndex < contextPlayedCount + userQueue.songs.length;
      const toInUser =
        toIndex >= contextPlayedCount &&
        toIndex < contextPlayedCount + userQueue.songs.length;

      const fromInUpcoming =
        fromIndex >= contextPlayedCount + userQueue.songs.length;
      const toInUpcoming =
        toIndex >= contextPlayedCount + userQueue.songs.length;

      if (fromInUser && toInUser) {
        const localFrom = fromIndex - contextPlayedCount;
        const localTo = toIndex - contextPlayedCount;
        const newUserSongs = [...userQueue.songs];
        const moved = newUserSongs.splice(localFrom, 1)[0];
        newUserSongs.splice(localTo, 0, moved);
        set((state) => {
          state.songlist.userQueue.songs = newUserSongs;
        });
        return;
      }

      if (fromInUpcoming && toInUpcoming) {
        const localFrom = fromIndex - userQueue.songs.length;
        const localTo = toIndex - userQueue.songs.length;
        const newContextSongs = [...contextQueue.songs];
        const moved = newContextSongs.splice(localFrom, 1)[0];
        newContextSongs.splice(localTo, 0, moved);
        set((state) => {
          state.songlist.contextQueue.songs = newContextSongs;
        });
        return;
      }
    },

    toggleShuffle: () => {
      if (isRemoteActive()) {
        remoteSend(LanControlMessageType.TOGGLE_SHUFFLE);
        return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.toggleShuffle();
        return;
      }

      const { isShuffleActive } = get().songlist;
      if (isShuffleActive) {
        set((state) => {
          applyShuffleOff(state.songlist, state.playerState.loopState);
        });
      } else {
        set((state) => {
          applyShuffleOn(state.songlist, state.playerState.loopState);
        });
      }
    },

    playNextSong: () => {
      if (isRemoteActive()) {
        if (remoteSend(LanControlMessageType.NEXT)) return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.playNext();
        return;
      }

      const now = Date.now();
      if (now - lastNextSongTime < NEXT_SONG_DEBOUNCE_MS) return;
      lastNextSongTime = now;

      const { loopState } = get().playerState;
      const songlist = get().songlist;

      if (!hasNextEffectiveSong(songlist, loopState)) {
        logger.info(`[playNextSong] no next song | loopState=${loopState}`);
        return;
      }

      const { isInUserQueue, userQueue, contextQueue } = songlist;
      const currentSongId = getCurrentSong(songlist)?.id;
      logger.info(
        `[playNextSong] loopState=${loopState} | currentIndex=${contextQueue.currentIndex} | hasUserQueue=${!!userQueue.songs.length} | isInUserQueue=${isInUserQueue} | currentSongId=${currentSongId}`,
      );

      if (isInUserQueue) {
        const consumed = userQueue.songs[0];
        set((state) => {
          state.songlist.userQueue.songs.splice(0, 1);
          state.songlist.playedUserQueueHistory.push(consumed);
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;

          if (state.songlist.userQueue.songs.length > 0) {
            state.playerState.isPlaying = true;
          } else {
            state.songlist.isInUserQueue = false;
            advancePlaybackQueue(state.songlist, loopState);
            state.playerState.isPlaying = true;
          }
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
        return;
      }

      if (userQueue.songs.length > 0) {
        set((state) => {
          state.songlist.isInUserQueue = true;
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
        return;
      }

      if (contextQueue.songs.length > 1 || loopState === LoopState.All) {
        logger.info(
          `[playNextSong:advance] songId=${contextQueue.songs[1]?.id}`,
        );
        set((state) => {
          advancePlaybackQueue(state.songlist, loopState);
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
        return;
      }
    },

    playPrevSong: () => {
      if (isRemoteActive()) {
        if (remoteSend(LanControlMessageType.PREVIOUS)) return;
      }

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.playPrev();
        return;
      }

      const currentSong = getCurrentSong(get().songlist);
      const progress = get().playerProgress.progress;
      const hasPrev = hasPrevEffectiveSong(get().songlist);
      const willSeekToStart = !!(
        currentSong &&
        (progress > PREV_SEEK_THRESHOLD || !hasPrev)
      );
      logger.info(
        `[playPrevSong] progress=${progress} | willSeekToStart=${willSeekToStart} | hasPrev=${hasPrev} | songId=${currentSong?.id}`,
      );

      if (willSeekToStart) {
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
        });
        lastPrevSongTime = Date.now();
        const audioRef = get().playerState.audioPlayerRef;
        if (audioRef) {
          seekPlaybackTarget(audioRef, 0);
        }
        return;
      }

      const now = Date.now();
      if (now - lastPrevSongTime < PREV_SONG_DEBOUNCE_MS) return;
      lastPrevSongTime = now;

      if (!hasPrev) return;

      const { isInUserQueue, playedUserQueueHistory, contextQueue } =
        get().songlist;

      if (playedUserQueueHistory.length > 0) {
        const wasInUserQueue = isInUserQueue;
        set((state) => {
          const history = state.songlist.playedUserQueueHistory;
          const restored = history.pop()!;
          state.songlist.userQueue.songs.unshift(restored);
          state.songlist.isInUserQueue = true;
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;

          if (!wasInUserQueue) {
            state.songlist.contextQueue.currentIndex = Math.max(
              0,
              state.songlist.contextQueue.currentIndex - 1,
            );
          }

          state.playerState.isPlaying = true;
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
        return;
      }

      if (isInUserQueue) {
        set((state) => {
          state.songlist.isInUserQueue = false;
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
        return;
      }

      if (contextQueue.currentIndex > 0) {
        set((state) => {
          state.songlist.contextQueue.currentIndex -= 1;
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.playerState.isTransitioning = true;
          const nextSong = getCurrentSong(state.songlist as ISongList);
          state.songlist.currentSong = nextSong;
          state.playerState.currentDuration = nextSong?.duration
            ? Math.round(nextSong.duration)
            : 0;
        });
      }
    },

    hasNextSong: () => {
      return hasNextEffectiveSong(get().songlist, get().playerState.loopState);
    },

    hasPrevSong: () => {
      return hasPrevEffectiveSong(get().songlist);
    },

    isPlayingOneSong: () => {
      return isPlayingOneSong(get().songlist);
    },

    setPlayRadio: (list: Radio[], index: number) => {
      if (isRemoteActive()) return;
      if (!list || list.length === 0) return;
      index = Math.max(0, Math.min(index, list.length - 1));

      const { mediaType } = get().playerState;
      const { radioList, contextQueue } = get().songlist;

      if (
        mediaType === "radio" &&
        radioList.length > 0 &&
        list[index]?.id === radioList[contextQueue.currentIndex]?.id
      ) {
        set((state) => {
          state.playerState.isPlaying = true;
        });
        return;
      }

      get().actions.clearPlayerState();
      set((state) => {
        state.playerState.mediaType = "radio";
        state.songlist.radioList = list;
        state.songlist.contextQueue.currentIndex = index;
        state.playerState.isPlaying = true;
      });
    },

    handleSongEnded: () => {
      if (isRemoteActive()) return;

      const sleepTimer = useSleepTimerStore.getState();
      if (sleepTimer.isActive && sleepTimer.mode === "end-of-track") {
        logger.info("[handleSongEnded → sleepTimer end-of-track] pausing");
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = false;
          state.playerState.isTransitioning = false;
        });
        sleepTimer.cancelTimer();
        return;
      }

      const { loopState } = get().playerState;
      const songlist = get().songlist;
      const transition = transitionHandleSongEnded(songlist, loopState);

      const currentSongId = getCurrentSong(songlist)?.id;
      logger.info(
        `[handleSongEnded] loopState=${loopState} | action=${transition.action} | currentSongId=${currentSongId} | isRemote=${isRemoteActive()}`,
      );

      if (transition.action === "playNext") {
        logger.info(
          `[handleSongEnded → playNextSong] | songId=${currentSongId}`,
        );
        get().actions.playNextSong();
      } else if (transition.action === "seekToStart") {
        logger.info(
          `[handleSongEnded → loopOneRestart] | seekToStart=true | isPlaying=true | songId=${currentSongId}`,
        );
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = true;
          state.playerState.seekToStart = true;
        });
      } else {
        logger.info(
          `[handleSongEnded → stop] | isPlaying=false | isTransitioning=false | songId=${currentSongId}`,
        );
        set((state) => {
          state.playerProgress.progress = 0;
          state.playerProgress.bufferedProgress = 0;
          state.playerState.isPlaying = false;
          state.playerState.isTransitioning = false;
        });
      }
    },

    clearPlayerState: () => {
      if (isRemoteActive()) return;

      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.clearPlayerState();
        return;
      }

      set((state) => {
        clearSonglistState(state.songlist);
        state.playerState.mediaType = "song";
        state.playerState.isPlaying = false;
        state.playerState.isTransitioning = false;
        state.playerState.loopState = LoopState.Off;
        state.playerState.mainDrawerState = false;
        state.playerState.queueState = false;
        state.playerState.lyricsState = false;
        state.playerState.currentDuration = 0;
        state.playerState.audioPlayerRef = null;
        state.playerState.radioPlayerRef = null;
        state.playerState.isBuffering = false;
        state.settings.colors.currentSongColor = null;
      });
    },

    checkActiveSong: (id: string) => {
      const currentSong = getCurrentSong(get().songlist);
      return currentSong ? id === currentSong.id : false;
    },

    setCurrentSong: () => {
      if (isRemoteActive()) return;
      const song = getCurrentSong(get().songlist);
      const currentSongId = get().songlist.currentSong?.id;
      if (song?.id === currentSongId && song?.id !== undefined) return;
      set((state) => {
        state.songlist.currentSong = song;
        state.playerState.currentDuration = song?.duration
          ? Math.round(song.duration)
          : 0;
        if (state.songlist.isShuffleActive && song?.id) {
          state.songlist.shuffleHistory = pushToHistory(
            state.songlist.shuffleHistory,
            song.id,
            getMaxShuffleHistory(state.songlist.contextQueue.songs.length),
          );
        }
      });
    },

    checkIsSongStarred: () => {
      const song = getCurrentSong(get().songlist);
      const { mediaType } = get().playerState;

      if (mediaType === "song" && song) {
        const isStarred = typeof song.starred === "string";
        set((state) => {
          state.playerState.isSongStarred = isStarred;
        });
      } else {
        set((state) => {
          state.playerState.isSongStarred = false;
        });
      }
    },

    updateQueueChecks: () => {
      const songlist = get().songlist;
      const { loopState } = get().playerState;
      const hasPrev = hasPrevEffectiveSong(songlist);
      const hasNext = hasNextEffectiveSong(songlist, loopState);

      set((state) => {
        state.playerState.hasPrev = hasPrev;
        state.playerState.hasNext = hasNext;
      });
    },
  } satisfies IPlayerActions;
}
