import type { LoopState, QueueSourceId } from "@/types/playerContext";
import type { Radio } from "@/types/responses/radios";
import type { ISong } from "@/types/responses/song";

export interface QueueControllerState {
  currentSong: ISong | null;
  contextQueue: {
    songs: ISong[];
    currentIndex: number;
    sourceId: QueueSourceId;
    sourceName: string | null;
  };
  userQueue: ISong[];
  isInUserQueue: boolean;
  isShuffleActive: boolean;
  loopState: LoopState;
  isPlaying: boolean;
  progress: number;
  duration: number;
  mediaType: "song" | "radio";
}

export type QueueStateChangeReason =
  | "next"
  | "previous"
  | "ended"
  | "skip"
  | "set-list"
  | "shuffle"
  | "queue-edit";

export interface QueueStateChangeEvent {
  reason: QueueStateChangeReason;
  state: QueueControllerState;
}

export type QueueControllerEventMap = {
  stateChanged: QueueStateChangeEvent;
};

export type QueueControllerEvent = keyof QueueControllerEventMap;

export type QueueControllerListener<T extends QueueControllerEvent> = (
  event: QueueControllerEventMap[T],
) => void;

export interface QueueController {
  setSongList(
    songs: ISong[],
    index?: number | null,
    shuffle?: boolean,
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void;

  playFromQueue(contextSongs: ISong[], contextIndex: number): void;

  playFromUserQueue(userQueueIndex: number): void;

  playSong(song: ISong, sourceName?: string): void;

  playNext(): void;

  playPrev(): void;

  toggleShuffle(): void;

  setShuffleState(enabled: boolean): void;

  setLoopState(state: LoopState): void;

  toggleLoop(): void;

  play(): void;

  pause(): void;

  togglePlayPause(): void;

  seek(seconds: number): void;

  setVolume(volume: number): void;

  setPlayRadio(list: Radio[], index: number): void;

  addToQueueNext(
    songs: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void;

  addToQueueLast(
    songs: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void;

  removeFromQueue(id: string, tier?: "context" | "user"): void;

  reorderQueue(fromIndex: number, toIndex: number): void;

  clearUserQueue(): void;

  clearPlayerState(): void;

  handleSongEnded(): void;

  hasNextSong(): boolean;

  hasPrevSong(): boolean;

  consumeNativeDrivenTransition(): boolean;

  getState(): QueueControllerState;

  subscribe<T extends QueueControllerEvent>(
    event: T,
    listener: QueueControllerListener<T>,
  ): () => void;

  dispose(): void;
}
