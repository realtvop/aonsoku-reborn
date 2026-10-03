import type { Draft } from "immer";
import { LanControlMessageType } from "@/types/lanControl";
import type {
  IContextQueue,
  IPlayerContext,
  ISongList,
  QueueSourceId,
} from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import {
  getMaxShuffleStartHistory,
  pushToHistory,
  shuffleWithGapAvoidance,
} from "@/utils/songListFunctions";

export const MAX_QUEUE_SIZE = 500;
export const MAX_USER_QUEUE_IDB_SIZE = 100;

function rotateSongsFromIndex(songs: ISong[], index: number): ISong[] {
  if (songs.length === 0) return [];
  index = Math.max(0, Math.min(index, songs.length - 1));
  return [...songs.slice(index), ...songs.slice(0, index)];
}

export function getSourceQueueSongs(songlist: ISongList): ISong[] {
  if (songlist.sourceQueue?.songs.length > 0) {
    return songlist.sourceQueue.songs;
  }
  if (songlist.originalContextSongs.length > 0) {
    return songlist.originalContextSongs;
  }
  return songlist.contextQueue.songs;
}

export function getSourceQueueIndex(
  songlist: ISongList,
  song: ISong | null,
): number {
  const sourceSongs = getSourceQueueSongs(songlist);
  if (!song) return 0;
  const index = sourceSongs.findIndex(
    (sourceSong) => sourceSong.id === song.id,
  );
  return index >= 0 ? index : 0;
}

function buildLinearQueue(songs: ISong[], index: number): ISong[] {
  if (songs.length === 0) return [];
  index = Math.max(0, Math.min(index, songs.length - 1));
  return songs.slice(index);
}

export function buildContextQueueSongs(
  songs: ISong[],
  index: number,
  loopState: LoopState,
  shuffle: boolean,
  shuffleFn: (
    items: ISong[],
    history: string[],
  ) => ISong[] = shuffleWithGapAvoidance,
): ISong[] {
  if (songs.length === 0) return [];

  const ordered =
    loopState === LoopState.All
      ? rotateSongsFromIndex(songs, index)
      : buildLinearQueue(songs, index);

  if (!shuffle || ordered.length <= 1) return ordered;

  const [currentSong, ...upcoming] = ordered;
  return [currentSong, ...shuffleFn(upcoming, [])];
}

export function rotateContextQueueToNext(state: Draft<ISongList>): void {
  const { songs } = state.contextQueue;
  if (songs.length <= 1) return;
  const [currentSong, ...remaining] = songs;
  state.contextQueue.songs = [...remaining, currentSong];
  state.contextQueue.currentIndex = 0;
}

export function appendPlaybackQueueCycle(state: Draft<ISongList>): void {
  const playbackSongs = state.contextQueue.songs;
  if (playbackSongs.length === 0) return;

  const cycleLength = Math.max(
    state.sourceQueue.songs.length || state.originalContextSongs.length,
    playbackSongs.length,
  );
  const cycle = playbackSongs.slice(0, cycleLength);
  state.contextQueue.songs = [...playbackSongs, ...cycle];
}

export function advancePlaybackQueue(
  state: Draft<ISongList>,
  loopState: LoopState,
): void {
  const { contextQueue } = state;
  if (contextQueue.songs.length <= 1) return;

  const nextIndex = contextQueue.currentIndex + 1;
  if (
    loopState === LoopState.All &&
    nextIndex >= contextQueue.songs.length - 1
  ) {
    appendPlaybackQueueCycle(state);
  }

  contextQueue.currentIndex = Math.min(
    nextIndex,
    contextQueue.songs.length - 1,
  );
}

export function rebuildContextQueueForLoopState(
  state: Draft<ISongList>,
  loopState: LoopState,
  shuffleFn: (
    items: ISong[],
    history: string[],
  ) => ISong[] = shuffleWithGapAvoidance,
): void {
  const currentSong = getCurrentSong(state as ISongList);
  if (!currentSong) return;

  const sourceSongs = getSourceQueueSongs(state as ISongList);
  const currentIndex = sourceSongs.findIndex(
    (song) => song.id === currentSong.id,
  );
  if (currentIndex === -1) return;

  state.contextQueue.songs = buildContextQueueSongs(
    sourceSongs,
    currentIndex,
    loopState,
    state.isShuffleActive,
    shuffleFn,
  );
  state.contextQueue.currentIndex = 0;
  state.sourceQueue.songs = [...sourceSongs];
  state.originalContextSongs = [...sourceSongs];
}

export function getCurrentSong(songlist: ISongList): ISong | null {
  if (songlist.isInUserQueue && songlist.userQueue.songs.length > 0) {
    return songlist.userQueue.songs[0] ?? null;
  }
  return (
    songlist.contextQueue.songs[songlist.contextQueue.currentIndex] ?? null
  );
}

export function getEffectiveQueue(songlist: ISongList): ISong[] {
  const { contextQueue, userQueue } = songlist;
  const played = contextQueue.songs.slice(0, contextQueue.currentIndex + 1);
  const upcoming = contextQueue.songs.slice(contextQueue.currentIndex + 1);
  return [...played, ...userQueue.songs, ...upcoming];
}

export function getEffectiveIndex(songlist: ISongList): number {
  if (songlist.isInUserQueue && songlist.userQueue.songs.length > 0) {
    return songlist.contextQueue.currentIndex + 1;
  }
  return songlist.contextQueue.currentIndex;
}

export function hasNextEffectiveSong(
  songlist: ISongList,
  loopState: LoopState,
): boolean {
  const { isInUserQueue, userQueue, contextQueue } = songlist;
  if (isInUserQueue) {
    const remainingUserSongs = userQueue.songs.length - 1;
    const remainingContextSongs =
      contextQueue.songs.length - contextQueue.currentIndex - 1;
    return (
      remainingUserSongs > 0 ||
      remainingContextSongs > 0 ||
      loopState === LoopState.All
    );
  }
  const remainingContextSongs =
    contextQueue.songs.length - contextQueue.currentIndex - 1;
  return (
    userQueue.songs.length > 0 ||
    remainingContextSongs > 0 ||
    loopState === LoopState.All
  );
}

export function hasPrevEffectiveSong(songlist: ISongList): boolean {
  if (songlist.playedUserQueueHistory.length > 0) return true;
  if (songlist.isInUserQueue) return true;
  return songlist.contextQueue.currentIndex > 0;
}

export function isPlayingOneSong(songlist: ISongList): boolean {
  const total =
    songlist.contextQueue.songs.length + songlist.userQueue.songs.length;
  return total <= 1;
}

export function findSongTier(
  songlist: ISongList,
  id: string,
): "context" | "user" | null {
  if (songlist.userQueue.songs.some((s) => s.id === id)) return "user";
  if (songlist.playedUserQueueHistory.some((s) => s.id === id)) return "user";
  if (songlist.contextQueue.songs.some((s) => s.id === id)) return "context";
  return null;
}

export function dedupAgainstExisting(
  incoming: ISong[],
  existing: ISong[],
): ISong[] {
  const existingIds = new Set(existing.map((s) => s.id));
  const seen = new Set<string>();
  return incoming.filter((s) => {
    if (existingIds.has(s.id) || seen.has(s.id)) return false;
    seen.add(s.id);
    return true;
  });
}

export function applyShuffleOn(
  state: Draft<ISongList>,
  loopState: LoopState = LoopState.Off,
): void {
  const { contextQueue } = state;
  if (contextQueue.songs.length + state.userQueue.songs.length <= 1) return;

  const currentSong = getCurrentSong(state as ISongList);
  if (!currentSong) return;
  if (currentSong?.id) {
    state.shuffleStartHistory = pushToHistory(
      state.shuffleStartHistory,
      currentSong.id,
      getMaxShuffleStartHistory(state.contextQueue.songs.length),
    );
  }

  const sourceSongs = getSourceQueueSongs(state as ISongList);
  const sourceIndex = getSourceQueueIndex(state as ISongList, currentSong);
  contextQueue.songs = buildContextQueueSongs(
    sourceSongs,
    sourceIndex,
    loopState,
    true,
  );
  contextQueue.currentIndex = 0;
  state.sourceQueue.songs = [...sourceSongs];
  state.originalContextSongs = [...sourceSongs];

  if (state.userQueue.songs.length > 0) {
    state.originalUserSongs = [...state.userQueue.songs];
    state.userQueue.songs = shuffleWithGapAvoidance(
      [...state.userQueue.songs],
      state.shuffleHistory,
    );
  }

  state.isShuffleActive = true;
}

export function applyShuffleOff(
  state: Draft<ISongList>,
  loopState: LoopState = LoopState.Off,
): void {
  const currentSongId = getCurrentSong(state as ISongList)?.id;
  const original = getSourceQueueSongs(state as ISongList);

  if (original.length > 0) {
    const newIdx = currentSongId
      ? original.findIndex((s) => s.id === currentSongId)
      : 0;
    state.contextQueue.songs = buildContextQueueSongs(
      original,
      newIdx >= 0 ? newIdx : 0,
      loopState,
      false,
    );
    state.contextQueue.currentIndex = 0;
  }

  if (state.originalUserSongs && state.originalUserSongs.length > 0) {
    state.userQueue.songs = [...state.originalUserSongs];
  }
  state.originalUserSongs = undefined;
  state.sourceQueue.songs = [...original];
  state.originalContextSongs = [...original];
  state.playedUserQueueHistory = [];

  state.isShuffleActive = false;
  state.shuffleHistory = [];
}

export function clearSonglistState(state: Draft<ISongList>): void {
  state.sourceQueue = emptyContextQueue();
  state.contextQueue = emptyContextQueue();
  state.userQueue = { songs: [] };
  state.originalContextSongs = [];
  state.originalUserSongs = undefined;
  state.currentSong = null;
  state.radioList = [];
  state.isShuffleActive = false;
  state.isInUserQueue = false;
  state.playedUserQueueHistory = [];
  state.shuffleHistory = [];
  state.shuffleStartHistory = [];
}

export function initSonglistState(): ISongList {
  return {
    sourceQueue: emptyContextQueue(),
    contextQueue: emptyContextQueue(),
    userQueue: { songs: [] },
    originalContextSongs: [],
    currentSong: null,
    radioList: [],
    isShuffleActive: false,
    isInUserQueue: false,
    playedUserQueueHistory: [],
    shuffleHistory: [],
    shuffleStartHistory: [],
  };
}

export function setNextOnUserQueue(
  existingUser: ISong[],
  incoming: ISong[],
): ISong[] {
  return [...incoming, ...existingUser];
}

export function setLastOnUserQueue(
  existingUser: ISong[],
  incoming: ISong[],
): ISong[] {
  return [...existingUser, ...incoming];
}

export function emptyContextQueue(
  overrides?: Partial<IContextQueue>,
): IContextQueue {
  return {
    songs: [],
    currentIndex: 0,
    sourceId: null,
    sourceName: null,
    ...overrides,
  };
}

export function resetPlaybackState(state: Draft<IPlayerContext>): void {
  state.playerState.isPlaying = false;
  state.playerState.isBuffering = false;
  state.playerProgress.progress = 0;
  state.playerProgress.bufferedProgress = 0;
  state.playerState.currentDuration = 0;
  state.songlist.isShuffleActive = false;
  state.songlist.shuffleHistory = [];
  state.songlist.shuffleStartHistory = [];
  state.playerState.loopState = LoopState.Off;
  state.playerState.hasPrev = false;
  state.playerState.hasNext = false;
}

export function applyStarToAllLists(
  state: Draft<ISongList>,
  id: string,
  newStarred: string | undefined,
): void {
  const allLists = [
    state.sourceQueue.songs,
    state.contextQueue.songs,
    state.userQueue.songs,
    state.playedUserQueueHistory,
    state.originalContextSongs,
    state.originalUserSongs,
  ];
  for (const list of allLists) {
    if (!list) continue;
    const song = list.find((s) => s.id === id);
    if (song) {
      song.starred = newStarred;
    }
  }
  if (state.currentSong?.id === id) {
    state.currentSong = { ...state.currentSong, starred: newStarred };
  }
}

export function hasAnySongs(songlist: ISongList): boolean {
  return (
    songlist.contextQueue.songs.length > 0 ||
    songlist.userQueue.songs.length > 0
  );
}

export function normalizeSourceId(
  sourceId?:
    | QueueSourceId
    | { albumId: string }
    | { playlistId: string }
    | null,
): QueueSourceId {
  if (!sourceId) return null;
  if ("type" in sourceId) {
    if (
      sourceId.type === "album" ||
      sourceId.type === "playlist" ||
      sourceId.type === "radio" ||
      sourceId.type === "artist" ||
      sourceId.type === "genre"
    ) {
      return sourceId;
    }
    return null;
  }
  if ("albumId" in sourceId) return { type: "album", id: sourceId.albumId };
  if ("playlistId" in sourceId)
    return { type: "playlist", id: sourceId.playlistId };
  return null;
}

export function sendAddToQueueRemote(
  remoteSend: (type: LanControlMessageType, data?: unknown) => boolean,
  list: ISong[],
  position: "next" | "last",
): void {
  remoteSend(LanControlMessageType.ADD_TO_QUEUE, {
    songIds: list.map((song) => song.id),
    position,
  });
}

export function reshuffleContextForWrap(
  state: Draft<ISongList>,
  lastPlayedSongId: string | undefined,
): void {
  if (!state.isShuffleActive || state.contextQueue.songs.length <= 1) return;

  const upcoming = state.contextQueue.songs.slice(1);
  const reshuffled = shuffleWithGapAvoidance(upcoming, state.shuffleHistory);

  if (lastPlayedSongId) {
    const lastIdx = reshuffled.findIndex((s) => s.id === lastPlayedSongId);
    if (lastIdx !== -1) {
      const [lastSong] = reshuffled.splice(lastIdx, 1);
      reshuffled.push(lastSong);
    }
  }

  state.contextQueue.songs = [state.contextQueue.songs[0], ...reshuffled];
}

export function trimQueueToWindow(
  songs: ISong[],
  currentIndex: number,
): { songs: ISong[]; currentIndex: number } {
  if (songs.length === 0) {
    return { songs, currentIndex: 0 };
  }
  if (songs.length <= MAX_QUEUE_SIZE) {
    return { songs, currentIndex };
  }

  currentIndex = Math.max(0, Math.min(currentIndex, songs.length - 1));
  const halfWindow = Math.floor(MAX_QUEUE_SIZE / 2);
  let start = Math.max(0, currentIndex - halfWindow);
  const end = Math.min(songs.length, start + MAX_QUEUE_SIZE);
  start = Math.max(0, end - MAX_QUEUE_SIZE);

  return {
    songs: songs.slice(start, end),
    currentIndex: currentIndex - start,
  };
}
