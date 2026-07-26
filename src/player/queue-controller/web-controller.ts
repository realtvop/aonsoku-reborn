import { getCurrentSong } from "@/store/player/queue-utils";
import { usePlayerStore } from "@/store/player/store";
import type { LoopState, QueueSourceId } from "@/types/playerContext";
import type { Radio } from "@/types/responses/radios";
import type { ISong } from "@/types/responses/song";
import type {
  QueueController,
  QueueControllerEvent,
  QueueControllerListener,
  QueueControllerState,
} from "./types";

export class WebQueueController implements QueueController {
  #listeners: Map<
    QueueControllerEvent,
    Set<QueueControllerListener<QueueControllerEvent>>
  > = new Map();

  #getActions() {
    return usePlayerStore.getState().actions;
  }

  #getStore() {
    return usePlayerStore.getState();
  }

  setSongList(
    songs: ISong[],
    index?: number | null,
    shuffle?: boolean,
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void {
    this.#getActions().setSongList(songs, index, shuffle, sourceId, sourceName);
  }

  playFromQueue(contextSongs: ISong[], contextIndex: number): void {
    this.#getActions().playFromQueue(contextSongs, contextIndex);
  }

  playFromUserQueue(userQueueIndex: number): void {
    this.#getActions().playFromUserQueue(userQueueIndex);
  }

  playSong(song: ISong, sourceName?: string): void {
    this.#getActions().playSong(song, sourceName);
  }

  playNext(): void {
    this.#getActions().playNextSong();
  }

  playPrev(): void {
    this.#getActions().playPrevSong();
  }

  toggleShuffle(): void {
    this.#getActions().toggleShuffle();
  }

  setShuffleState(enabled: boolean): void {
    const store = this.#getStore();
    if (store.songlist.isShuffleActive !== enabled) {
      this.#getActions().toggleShuffle();
    }
  }

  setLoopState(_state: LoopState): void {
    const store = this.#getStore();
    const current = store.playerState.loopState;
    if (current !== _state) {
      usePlayerStore.setState((s) => {
        s.playerState.loopState = _state;
      });
    }
  }

  toggleLoop(): void {
    this.#getActions().toggleLoop();
  }

  play(): void {
    this.#getActions().setPlayingState(true);
  }

  pause(): void {
    this.#getActions().setPlayingState(false);
  }

  togglePlayPause(): void {
    this.#getActions().togglePlayPause();
  }

  seek(seconds: number): void {
    this.#getActions().setProgress(seconds, true);
  }

  setVolume(volume: number): void {
    this.#getActions().setVolume(volume);
  }

  setPlayRadio(list: Radio[], index: number): void {
    this.#getActions().setPlayRadio(list, index);
  }

  addToQueueNext(
    songs: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void {
    this.#getActions().setNextOnQueue(songs, sourceId, sourceName);
  }

  addToQueueLast(
    songs: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ): void {
    this.#getActions().setLastOnQueue(songs, sourceId, sourceName);
  }

  removeFromQueue(id: string, tier?: "context" | "user"): void {
    this.#getActions().removeSongFromQueue(id, tier);
  }

  reorderQueue(fromIndex: number, toIndex: number): void {
    this.#getActions().reorderQueue(fromIndex, toIndex);
  }

  clearUserQueue(): void {
    this.#getActions().clearUserQueue();
  }

  clearPlayerState(): void {
    this.#getActions().clearPlayerState();
  }

  handleSongEnded(): void {
    this.#getActions().handleSongEnded();
  }

  hasNextSong(): boolean {
    return this.#getActions().hasNextSong();
  }

  hasPrevSong(): boolean {
    return this.#getActions().hasPrevSong();
  }

  consumeNativeDrivenTransition(): boolean {
    return false;
  }

  getState(): QueueControllerState {
    const store = this.#getStore();
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
    this.#listeners.clear();
  }
}
