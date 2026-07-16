import type { NativeFullState } from "@/native/audio";
import type { PlaybackSnapshot } from "./types";

export interface NativeFullStateSnapshotOptions {
  volume: number | null;
  sampledAt?: number;
}

export function buildPlaybackSnapshotFromNativeFullState(
  sessionId: string,
  state: NativeFullState,
  options: NativeFullStateSnapshotOptions,
): PlaybackSnapshot | null {
  const currentSongId =
    state.currentSongId ??
    state.contextQueue.songs[state.contextQueue.currentIndex]?.id ??
    null;

  if (!currentSongId) return null;

  const currentSong =
    state.contextQueue.songs.find((song) => song.id === currentSongId) ??
    state.userQueue.find((song) => song.id === currentSongId) ??
    state.playedUserQueueHistory.find((song) => song.id === currentSongId) ??
    null;
  const duration =
    state.duration > 0 ? state.duration : (currentSong?.duration ?? 0);

  return {
    sessionId,
    logicalPlaybackSessionId: sessionId,
    mediaKind: "song",
    songId: currentSongId,
    progressSeconds: Math.max(0, state.currentTime),
    durationSeconds: Math.max(0, duration),
    isPlaying: state.isPlaying,
    sampledAt: options.sampledAt ?? Date.now() / 1000,
    contextQueue: state.contextQueue.songs.map((song) => song.id),
    contextIndex:
      state.contextQueue.songs.length > 0
        ? state.contextQueue.currentIndex
        : null,
    sourceId: encodeNativeSourceId(state.contextQueue.sourceId),
    sourceName: state.contextQueue.sourceName,
    userQueue: state.userQueue.map((song) => song.id),
    inUserQueue: state.isInUserQueue,
    restorePrevious: state.playedUserQueueHistory.map((song) => song.id),
    shuffle: state.isShuffleActive,
    repeat: state.loopState,
    volume:
      typeof options.volume === "number"
        ? Math.max(0, Math.min(1, options.volume / 100))
        : null,
    accumulatedPlaySeconds: 0,
    historyWritten: false,
    nowPlayingSent: false,
    scrobbleSent: false,
  };
}

function encodeNativeSourceId(
  sourceId: NativeFullState["contextQueue"]["sourceId"],
): string | null {
  if (!sourceId) return null;
  return `${sourceId.type}:${sourceId.id}`;
}
