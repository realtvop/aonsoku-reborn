import { usePlayerStore } from "@/store/player.store";
import { LoopState } from "@/types/playerContext";
import {
  canUseSystemVolumeControl,
  getCurrentSystemVolume,
} from "@/utils/system-volume";

const CHANNEL_NAME = "aonsoku-mini-player";

type SyncMessage =
  | { type: "state-update"; payload: MiniPlayerState }
  | { type: "control"; action: ControlAction; value?: number }
  | { type: "request-state" };

export type ControlAction =
  | "togglePlayPause"
  | "playNextSong"
  | "playPrevSong"
  | "toggleShuffle"
  | "toggleLoop"
  | "seek"
  | "setVolume"
  | "starCurrentSong";

export interface MiniPlayerState {
  isPlaying: boolean;
  isTransitioning: boolean;
  isBuffering: boolean;
  shuffleActive: boolean;
  loopState: LoopState;
  hasPrev: boolean;
  hasNext: boolean;
  isSongStarred: boolean;
  currentSong: {
    id: string;
    title: string;
    artist: string;
    artists?: { id: string; name: string }[];
    coverArt: string;
    albumId: string;
  } | null;
  progress: number;
  duration: number;
  volume: number;
  mediaType: "song" | "radio";
  currentSongColor: string | null;
  currentLine: string | null;
}

let channel: BroadcastChannel | null = null;
let unsubscribeStore: (() => void) | null = null;
let lastCurrentLine: string | null = null;

export function setCurrentLine(line: string | null) {
  lastCurrentLine = line;
}

function getStateFromStore(): MiniPlayerState {
  const state = usePlayerStore.getState();
  const song = state.songlist.currentSong;

  return {
    isPlaying: state.playerState.isPlaying,
    isTransitioning: state.playerState.isTransitioning,
    isBuffering: state.playerState.isBuffering,
    shuffleActive: state.songlist.isShuffleActive,
    loopState: state.playerState.loopState,
    hasPrev: Boolean(song),
    hasNext: state.playerState.hasNext,
    isSongStarred: state.playerState.isSongStarred,
    currentSong: song
      ? {
          id: song.id,
          title: song.title,
          artist: song.artist,
          artists: song.artists?.map((a) => ({ id: a.id, name: a.name })),
          coverArt: song.coverArt,
          albumId: song.albumId,
        }
      : null,
    progress: state.playerProgress.progress,
    duration: state.playerState.currentDuration ?? 0,
    volume: canUseSystemVolumeControl()
      ? getCurrentSystemVolume()
      : state.playerState.volume,
    mediaType: state.playerState.mediaType,
    currentSongColor: state.settings.colors.currentSongColor,
    currentLine: lastCurrentLine,
  };
}

export function broadcastState(state?: MiniPlayerState) {
  if (!channel) return;
  channel.postMessage({
    type: "state-update",
    payload: state ?? getStateFromStore(),
  });
}

export function initMiniPlayerSync() {
  if (channel) return;

  channel = new BroadcastChannel(CHANNEL_NAME);

  // Use a listener that correctly gets the mapped state
  unsubscribeStore = usePlayerStore.subscribe(() => {
    broadcastState();
  });

  broadcastState();
}

export function destroyMiniPlayerSync() {
  if (unsubscribeStore) {
    unsubscribeStore();
    unsubscribeStore = null;
  }
  if (channel) {
    channel.close();
    channel = null;
  }
}

export function listenMiniPlayerUpdates(
  callback: (state: MiniPlayerState) => void,
): () => void {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }

  const handler = (event: MessageEvent) => {
    const data = event.data as SyncMessage;
    if (data.type === "state-update") {
      callback(data.payload);
    }
  };

  channel.addEventListener("message", handler);
  return () => {
    channel?.removeEventListener("message", handler);
  };
}

export function sendControlAction(action: ControlAction, value?: number) {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }
  channel.postMessage({ type: "control", action, value });
}

export function requestState() {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }
  channel.postMessage({ type: "request-state" });
}

export function listenControlActions(
  callback: (action: ControlAction, value?: number) => void,
  onStateRequest?: () => void,
): () => void {
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL_NAME);
  }

  const handler = (event: MessageEvent) => {
    const data = event.data as SyncMessage;
    if (data.type === "control") {
      callback(data.action, data.value);
    } else if (data.type === "request-state" && onStateRequest) {
      onStateRequest();
    }
  };

  channel.addEventListener("message", handler);
  return () => {
    channel?.removeEventListener("message", handler);
  };
}

export function handleControlAction(action: ControlAction, value?: number) {
  const { actions } = usePlayerStore.getState();
  const audioRef = usePlayerStore.getState().playerState.audioPlayerRef;

  switch (action) {
    case "togglePlayPause":
      actions.togglePlayPause();
      break;
    case "playNextSong":
      actions.playNextSong();
      break;
    case "playPrevSong":
      actions.playPrevSong();
      break;
    case "toggleShuffle":
      actions.toggleShuffle();
      break;
    case "toggleLoop":
      actions.toggleLoop();
      break;
    case "seek":
      if (value !== undefined) {
        actions.setProgress(value);
        if (audioRef) {
          audioRef.currentTime = value;
        }
      }
      break;
    case "setVolume":
      if (value !== undefined) {
        actions.setVolume(value);
      }
      break;
    case "starCurrentSong":
      actions.starCurrentSong();
      break;
  }
}
