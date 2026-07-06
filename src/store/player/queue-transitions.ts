import type {
  ISongList,
  QueueSourceId,
  QueueTier,
} from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import {
  advancePlaybackQueue,
  appendPlaybackQueueCycle,
  buildContextQueueSongs,
  getCurrentSong,
  hasNextEffectiveSong,
  hasPrevEffectiveSong,
  trimQueueToWindow,
} from "./queue-utils";

export const PREV_SEEK_THRESHOLD = 3;

export interface QueueTransition {
  songlist: ISongList;
  resetProgress: boolean;
  seekToStart: boolean;
  isPlaying: boolean;
  isTransitioning: boolean;
}

function baseTransition(songlist: ISongList): QueueTransition {
  return {
    songlist,
    resetProgress: false,
    seekToStart: false,
    isPlaying: true,
    isTransitioning: false,
  };
}

function withResetProgress(transition: QueueTransition): QueueTransition {
  return { ...transition, resetProgress: true };
}

function withTransitioning(transition: QueueTransition): QueueTransition {
  return { ...transition, isTransitioning: true };
}

function cloneSonglist(sl: ISongList): ISongList {
  return {
    sourceQueue: {
      songs: [...sl.sourceQueue.songs],
      currentIndex: sl.sourceQueue.currentIndex,
      sourceId: sl.sourceQueue.sourceId,
      sourceName: sl.sourceQueue.sourceName,
    },
    contextQueue: {
      songs: [...sl.contextQueue.songs],
      currentIndex: sl.contextQueue.currentIndex,
      sourceId: sl.contextQueue.sourceId,
      sourceName: sl.contextQueue.sourceName,
    },
    userQueue: { songs: [...sl.userQueue.songs] },
    originalContextSongs: [...sl.originalContextSongs],
    originalUserSongs: sl.originalUserSongs
      ? [...sl.originalUserSongs]
      : undefined,
    currentSong: sl.currentSong,
    radioList: [...sl.radioList],
    isShuffleActive: sl.isShuffleActive,
    isInUserQueue: sl.isInUserQueue,
    playedUserQueueHistory: [...sl.playedUserQueueHistory],
    shuffleHistory: [...sl.shuffleHistory],
    shuffleStartHistory: [...sl.shuffleStartHistory],
  };
}

export function transitionNextSong(
  songlist: ISongList,
  loopState: LoopState,
): QueueTransition | null {
  if (!hasNextEffectiveSong(songlist, loopState)) return null;

  const next = cloneSonglist(songlist);

  if (songlist.isInUserQueue) {
    return transitionConsumeUserQueue(next, songlist, loopState);
  }

  if (songlist.userQueue.songs.length > 0) {
    return transitionEnterUserQueue(next);
  }

  if (songlist.contextQueue.songs.length > 1 || loopState === LoopState.All) {
    advancePlaybackQueue(next, loopState);
    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  return null;
}

function transitionConsumeUserQueue(
  next: ISongList,
  original: ISongList,
  loopState: LoopState,
): QueueTransition {
  const consumed = original.userQueue.songs[0];
  next.playedUserQueueHistory = [...original.playedUserQueueHistory, consumed];
  next.userQueue.songs = original.userQueue.songs.slice(1);

  if (next.userQueue.songs.length > 0) {
    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  next.isInUserQueue = false;
  if (next.contextQueue.songs.length > 1 || loopState === LoopState.All) {
    advancePlaybackQueue(next, loopState);
    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  next.currentSong = getCurrentSong(next);
  return withTransitioning(withResetProgress(baseTransition(next)));
}

function transitionEnterUserQueue(next: ISongList): QueueTransition {
  next.isInUserQueue = true;
  next.currentSong = getCurrentSong(next);
  return withTransitioning(withResetProgress(baseTransition(next)));
}

export function transitionPrevSong(
  songlist: ISongList,
  currentProgress: number,
  loopState: LoopState,
): QueueTransition | null {
  const currentSong = getCurrentSong(songlist);

  if (currentSong && currentProgress > PREV_SEEK_THRESHOLD) {
    return { ...baseTransition(cloneSonglist(songlist)), seekToStart: true };
  }

  if (!hasPrevEffectiveSong(songlist)) {
    if (currentSong) {
      return { ...baseTransition(cloneSonglist(songlist)), seekToStart: true };
    }
    return null;
  }

  const next = cloneSonglist(songlist);

  if (songlist.playedUserQueueHistory.length > 0) {
    const restored = next.playedUserQueueHistory.pop()!;
    next.userQueue.songs = [restored, ...next.userQueue.songs];
    next.isInUserQueue = true;

    if (!songlist.isInUserQueue) {
      next.contextQueue.currentIndex = Math.max(
        0,
        next.contextQueue.currentIndex - 1,
      );
    }

    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  if (songlist.isInUserQueue) {
    next.isInUserQueue = false;
    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  if (songlist.contextQueue.currentIndex > 0) {
    next.contextQueue.currentIndex = songlist.contextQueue.currentIndex - 1;
    next.currentSong = getCurrentSong(next);
    return withTransitioning(withResetProgress(baseTransition(next)));
  }

  return null;
}

export function transitionRemoveFromContextQueue(
  songlist: ISongList,
  songId: string,
): QueueTransition | null {
  const { contextQueue, isInUserQueue } = songlist;
  const removedIndex = contextQueue.songs.findIndex((s) => s.id === songId);
  if (removedIndex === -1) return null;

  const newSongs = [...contextQueue.songs];
  newSongs.splice(removedIndex, 1);

  if (newSongs.length === 0) {
    return null;
  }

  const next = cloneSonglist(songlist);
  next.contextQueue.songs = newSongs;
  next.originalContextSongs = next.originalContextSongs.filter(
    (s) => s.id !== songId,
  );

  if (isInUserQueue) {
    next.contextQueue.currentIndex =
      contextQueue.currentIndex -
      (removedIndex <= contextQueue.currentIndex ? 1 : 0);
  } else {
    if (removedIndex < contextQueue.currentIndex) {
      next.contextQueue.currentIndex = contextQueue.currentIndex - 1;
    } else if (removedIndex === contextQueue.currentIndex) {
      next.contextQueue.currentIndex = Math.min(
        contextQueue.currentIndex,
        newSongs.length - 1,
      );
    }
  }
  next.contextQueue.currentIndex = Math.max(next.contextQueue.currentIndex, 0);

  const shouldResetProgress =
    removedIndex === contextQueue.currentIndex && !isInUserQueue;

  const result = baseTransition(next);
  if (shouldResetProgress) {
    result.resetProgress = true;
  }

  return result;
}

export function transitionRemoveFromUserQueue(
  songlist: ISongList,
  songId: string,
): QueueTransition | null {
  const { userQueue, isInUserQueue } = songlist;
  const removedIndex = userQueue.songs.findIndex((s) => s.id === songId);
  if (removedIndex === -1) return null;

  const newUserSongs = [...userQueue.songs];
  newUserSongs.splice(removedIndex, 1);

  const next = cloneSonglist(songlist);
  next.userQueue.songs = newUserSongs;

  if (isInUserQueue && removedIndex === 0 && newUserSongs.length === 0) {
    next.isInUserQueue = false;
  }

  return baseTransition(next);
}

export function transitionReorderQueue(
  songlist: ISongList,
  fromIndex: number,
  toIndex: number,
): QueueTransition | null {
  if (fromIndex === toIndex) return null;

  const { contextQueue, userQueue } = songlist;
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

  const next = cloneSonglist(songlist);

  if (fromInUser && toInUser) {
    const localFrom = fromIndex - contextPlayedCount;
    const localTo = toIndex - contextPlayedCount;
    const moved = next.userQueue.songs.splice(localFrom, 1)[0];
    next.userQueue.songs.splice(localTo, 0, moved);
    return baseTransition(next);
  }

  if (fromInUpcoming && toInUpcoming) {
    const localFrom = fromIndex - userQueue.songs.length;
    const localTo = toIndex - userQueue.songs.length;
    const moved = next.contextQueue.songs.splice(localFrom, 1)[0];
    next.contextQueue.songs.splice(localTo, 0, moved);
    return baseTransition(next);
  }

  return null;
}

export function transitionEnterUserQueueMode(
  songlist: ISongList,
  userQueueIndex: number,
): QueueTransition | null {
  const { userQueue } = songlist;
  if (userQueueIndex < 0 || userQueueIndex >= userQueue.songs.length)
    return null;

  const next = cloneSonglist(songlist);
  const songsBefore = next.userQueue.songs.splice(0, userQueueIndex);
  next.playedUserQueueHistory = [
    ...next.playedUserQueueHistory,
    ...songsBefore,
  ];
  next.isInUserQueue = true;
  next.currentSong = getCurrentSong(next);

  return withResetProgress(baseTransition(next));
}

export function transitionClearUserQueue(songlist: ISongList): QueueTransition {
  const next = cloneSonglist(songlist);
  next.userQueue.songs = [];
  next.playedUserQueueHistory = [];
  if (next.isInUserQueue) {
    next.isInUserQueue = false;
  }
  next.currentSong = getCurrentSong(next);
  return baseTransition(next);
}

export function transitionHandleSongEnded(
  songlist: ISongList,
  loopState: LoopState,
): { action: "playNext" } | { action: "seekToStart" } | { action: "stop" } {
  const userQueueRemaining = songlist.isInUserQueue
    ? songlist.userQueue.songs.length - 1
    : songlist.userQueue.songs.length;

  const hasNext =
    loopState === LoopState.One
      ? userQueueRemaining > 0
      : hasNextEffectiveSong(songlist, loopState);

  if (hasNext) {
    if (
      loopState === LoopState.All &&
      !songlist.isInUserQueue &&
      userQueueRemaining === 0 &&
      songlist.contextQueue.songs.length <= 1
    ) {
      return { action: "seekToStart" };
    }
    return { action: "playNext" };
  }
  if (loopState === LoopState.One) {
    return { action: "seekToStart" };
  }
  return { action: "stop" };
}

export function transitionSetSongList(
  songlist: ISongList,
  newSongs: ISong[],
  index: number,
  sourceId: QueueSourceId,
  sourceName: string | null,
  shuffle: boolean,
  existingStartHistory: string[],
  shuffleFn: (items: ISong[], history: string[]) => ISong[],
  _pickStartIndex: (
    length: number,
    history: string[],
    idFn: (i: number) => string,
  ) => number,
): QueueTransition {
  index = Math.max(0, Math.min(index, newSongs.length - 1));
  const next = cloneSonglist(songlist);

  if (shuffle) {
    const startSong = newSongs[index];
    const shuffledRemaining = buildContextQueueSongs(
      newSongs,
      index,
      LoopState.Off,
      true,
      shuffleFn,
    );
    const updatedStartHistory = [
      ...existingStartHistory.slice(-99),
      startSong.id,
    ];
    next.contextQueue = {
      songs: shuffledRemaining,
      currentIndex: 0,
      sourceId,
      sourceName,
    };
    next.sourceQueue = {
      songs: [...newSongs],
      currentIndex: index,
      sourceId,
      sourceName,
    };
    next.userQueue = { songs: [] };
    next.originalContextSongs = [...newSongs];
    next.radioList = [];
    next.shuffleHistory = [];
    next.isShuffleActive = true;
    next.shuffleStartHistory = updatedStartHistory;
    next.isInUserQueue = false;
    next.playedUserQueueHistory = [];
    next.currentSong = getCurrentSong(next);
  } else {
    const queueSongs = buildContextQueueSongs(
      newSongs,
      index,
      LoopState.Off,
      false,
    );
    const trimmed = trimQueueToWindow(queueSongs, 0);
    next.contextQueue = {
      songs: trimmed.songs,
      currentIndex: 0,
      sourceId,
      sourceName,
    };
    next.sourceQueue = {
      songs: [...newSongs],
      currentIndex: index,
      sourceId,
      sourceName,
    };
    next.userQueue = { songs: [] };
    next.originalContextSongs = [...newSongs];
    next.radioList = [];
    next.shuffleHistory = [];
    next.isShuffleActive = false;
    next.isInUserQueue = false;
    next.playedUserQueueHistory = [];
    next.currentSong = getCurrentSong(next);
  }

  return withResetProgress(baseTransition(next));
}

export function transitionPlayFromQueue(
  songlist: ISongList,
  contextSongs: ISong[],
  contextIndex: number,
  sameList: boolean,
  loopState: LoopState = LoopState.Off,
): QueueTransition | null {
  if (!contextSongs || contextSongs.length === 0) return null;
  contextIndex = Math.max(0, Math.min(contextIndex, contextSongs.length - 1));

  const next = cloneSonglist(songlist);

  if (sameList) {
    next.contextQueue.currentIndex = contextIndex;
    if (
      loopState === LoopState.All &&
      contextIndex >= next.contextQueue.songs.length - 1
    ) {
      appendPlaybackQueueCycle(next);
    }
    next.isInUserQueue = false;
    next.currentSong = getCurrentSong(next);
    return withResetProgress(baseTransition(next));
  }

  const trimmed = trimQueueToWindow(contextSongs, contextIndex);
  next.contextQueue = {
    songs: trimmed.songs,
    currentIndex: trimmed.currentIndex,
    sourceId: next.contextQueue.sourceId,
    sourceName: next.contextQueue.sourceName,
  };
  if (
    loopState === LoopState.All &&
    next.contextQueue.currentIndex >= next.contextQueue.songs.length - 1
  ) {
    appendPlaybackQueueCycle(next);
  }
  next.sourceQueue = {
    songs: [...contextSongs],
    currentIndex: contextIndex,
    sourceId: next.contextQueue.sourceId,
    sourceName: next.contextQueue.sourceName,
  };
  next.userQueue = { songs: [] };
  next.originalContextSongs = [];
  next.isShuffleActive = false;
  next.shuffleHistory = [];
  next.isInUserQueue = false;
  next.playedUserQueueHistory = [];
  next.currentSong = getCurrentSong(next);

  return withResetProgress(baseTransition(next));
}

export function transitionPlaySong(
  songlist: ISongList,
  song: ISong,
  sourceName: string | null,
): QueueTransition {
  const next = cloneSonglist(songlist);
  next.contextQueue = {
    songs: [song],
    currentIndex: 0,
    sourceId: null,
    sourceName: sourceName ?? song.album ?? null,
  };
  next.sourceQueue = {
    songs: [song],
    currentIndex: 0,
    sourceId: null,
    sourceName: sourceName ?? song.album ?? null,
  };
  next.userQueue = { songs: [] };
  next.originalContextSongs = [song];
  next.isShuffleActive = false;
  next.shuffleHistory = [];
  next.isInUserQueue = false;
  next.playedUserQueueHistory = [];
  next.radioList = [];
  next.currentSong = getCurrentSong(next);

  return withResetProgress(baseTransition(next));
}

export function transitionRemoveSongFromQueue(
  songlist: ISongList,
  songId: string,
  tier: QueueTier,
): QueueTransition | null {
  if (tier === "user") {
    return transitionRemoveFromUserQueue(songlist, songId);
  }
  return transitionRemoveFromContextQueue(songlist, songId);
}

export function transitionUpdatePrevNextFlags(
  songlist: ISongList,
  loopState: LoopState,
): { hasPrev: boolean; hasNext: boolean } {
  return {
    hasPrev: hasPrevEffectiveSong(songlist),
    hasNext: hasNextEffectiveSong(songlist, loopState),
  };
}
