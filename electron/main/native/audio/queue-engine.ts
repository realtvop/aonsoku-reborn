import type {
  NativeAudioEvents,
  NativeFullState,
  NativeQueueSong,
  NativeQueueSourceId,
  NativeSetContextQueueOptions,
} from "@aonsoku/audio-contract";

export type DesktopQueueAdvanceReason =
  NativeAudioEvents["queueStateChanged"]["reason"];

export type DesktopQueueContentsReason =
  NativeAudioEvents["queueContentsChanged"]["reason"];

export interface DesktopQueueEngineDelegate {
  queueEngineLoadSong(
    engine: DesktopQueueEngine,
    song: NativeQueueSong,
    autoplay: boolean,
    startTime?: number,
  ): void | Promise<void>;
  queueEngineDidAdvanceTo(
    engine: DesktopQueueEngine,
    index: number,
    songId: string,
    reason: DesktopQueueAdvanceReason,
  ): void | Promise<void>;
  queueEngineDidChangeContents(
    engine: DesktopQueueEngine,
    reason: DesktopQueueContentsReason,
  ): void | Promise<void>;
  queueEngineDidExhaustQueue(engine: DesktopQueueEngine): void | Promise<void>;
  queueEngineSeekToStart(
    engine: DesktopQueueEngine,
    song: NativeQueueSong,
  ): void | Promise<void>;
}

export interface DesktopQueueEngineOptions {
  random?: () => number;
}

export interface DesktopQueueFullStateOptions {
  currentTime: number;
  duration: number;
  isPlaying: boolean;
}

const PREVIOUS_SEEK_THRESHOLD_SECONDS = 3;

export class DesktopQueueEngine {
  delegate: DesktopQueueEngineDelegate | null = null;

  contextSongs: NativeQueueSong[] = [];
  originalContextSongs: NativeQueueSong[] = [];
  currentIndex = 0;
  userQueue: NativeQueueSong[] = [];
  originalUserSongs: NativeQueueSong[] = [];
  isInUserQueue = false;
  playedUserQueueHistory: NativeQueueSong[] = [];
  loopState: NativeFullState["loopState"] = "off";
  isShuffleActive = false;
  shuffleHistory: string[] = [];
  shuffleStartHistory: string[] = [];
  sourceId: NativeQueueSourceId | null = null;
  sourceName: string | null = null;
  isRestored = false;

  readonly #random: () => number;

  constructor(options: DesktopQueueEngineOptions = {}) {
    this.#random = options.random ?? Math.random;
  }

  get currentSong(): NativeQueueSong | null {
    if (this.isInUserQueue && this.userQueue.length > 0) {
      return this.userQueue[0] ?? null;
    }

    return this.contextSongs[this.currentIndex] ?? null;
  }

  get hasNext(): boolean {
    if (this.isInUserQueue && this.userQueue.length > 1) return true;
    if (!this.isInUserQueue && this.userQueue.length > 0) return true;
    if (this.currentIndex < this.contextSongs.length - 1) return true;
    return this.loopState === "all" && this.contextSongs.length > 0;
  }

  get hasPrevious(): boolean {
    if (this.playedUserQueueHistory.length > 0) return true;
    if (this.isInUserQueue) return true;
    return this.currentIndex > 0;
  }

  get #maxShuffleHistory(): number {
    return Math.max(20, Math.min(Math.floor(this.contextSongs.length / 2), 200));
  }

  get #maxShuffleStartHistory(): number {
    return Math.max(10, Math.min(Math.floor(this.contextSongs.length / 4), 50));
  }

  clear(): void {
    this.contextSongs = [];
    this.originalContextSongs = [];
    this.currentIndex = 0;
    this.userQueue = [];
    this.originalUserSongs = [];
    this.isInUserQueue = false;
    this.playedUserQueueHistory = [];
    this.loopState = "off";
    this.isShuffleActive = false;
    this.shuffleHistory = [];
    this.shuffleStartHistory = [];
    this.sourceId = null;
    this.sourceName = null;
    this.isRestored = false;
  }

  setContextQueue(options: NativeSetContextQueueOptions): void {
    this.contextSongs = copySongs(options.songs);
    this.originalContextSongs = [];
    this.currentIndex = normalizeSongIndex(
      options.currentIndex,
      this.contextSongs,
    );
    this.userQueue = [];
    this.originalUserSongs = [];
    this.isInUserQueue = false;
    this.playedUserQueueHistory = [];
    this.isShuffleActive = false;
    this.shuffleHistory = [];
    this.sourceId = options.sourceId ?? null;
    this.sourceName = options.sourceName ?? null;
    this.isRestored = false;

    if (options.repeatMode) {
      this.loopState = options.repeatMode;
    }

    const song = this.currentSong;
    if (song) {
      this.delegate?.queueEngineLoadSong(
        this,
        song,
        options.autoplay ?? true,
        options.startTime,
      );
    }
  }

  updateContextQueue(songs: NativeQueueSong[], currentIndex: number): void {
    const previousSongId = this.currentSong?.id ?? null;

    this.contextSongs = copySongs(songs);
    this.currentIndex = normalizeSongIndex(currentIndex, this.contextSongs);
    this.originalContextSongs = this.originalContextSongs.filter((original) =>
      this.contextSongs.some((song) => song.id === original.id),
    );

    const song = this.currentSong;
    if (previousSongId !== (song?.id ?? null)) {
      if (!song) return;

      this.delegate?.queueEngineLoadSong(this, song, true, undefined);
      this.delegate?.queueEngineDidAdvanceTo(
        this,
        this.currentIndex,
        song.id,
        "skip",
      );
      return;
    }

    this.delegate?.queueEngineDidChangeContents(this, "queue-edit");
  }

  reorderContextQueue(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex) return;
    if (!isValidIndex(fromIndex, this.contextSongs)) return;
    if (!isValidIndex(toIndex, this.contextSongs)) return;

    const songs = copySongs(this.contextSongs);
    const [song] = songs.splice(fromIndex, 1);
    if (!song) return;

    songs.splice(toIndex, 0, song);
    this.contextSongs = songs;
    this.delegate?.queueEngineDidChangeContents(this, "queue-edit");
  }

  addToUserQueue(songs: NativeQueueSong[], position: "next" | "last"): void {
    const updatedQueue = copySongs(this.userQueue);

    if (position === "next") {
      const insertIndex = this.isInUserQueue ? 1 : 0;
      updatedQueue.splice(
        Math.min(insertIndex, updatedQueue.length),
        0,
        ...copySongs(songs),
      );
    } else {
      updatedQueue.push(...copySongs(songs));
    }

    this.userQueue = updatedQueue;
    this.delegate?.queueEngineDidChangeContents(this, "queue-edit");
  }

  removeFromUserQueue(indices: number[]): void {
    const updatedQueue = copySongs(this.userQueue);

    for (const index of [...indices].sort((a, b) => b - a)) {
      if (isValidIndex(index, updatedQueue)) {
        updatedQueue.splice(index, 1);
      }
    }

    this.userQueue = updatedQueue;
    if (this.userQueue.length === 0 && this.isInUserQueue) {
      this.isInUserQueue = false;
    }
    this.delegate?.queueEngineDidChangeContents(this, "queue-edit");
  }

  clearUserQueue(): void {
    this.userQueue = [];
    this.originalUserSongs = [];
    this.playedUserQueueHistory = [];
    if (this.isInUserQueue) {
      this.isInUserQueue = false;
    }
    this.delegate?.queueEngineDidChangeContents(this, "queue-edit");
  }

  playAtIndex(index: number, startTime?: number): void {
    if (!isValidIndex(index, this.contextSongs)) return;

    this.isInUserQueue = false;
    this.currentIndex = index;

    const song = this.currentSong;
    if (!song) return;

    this.delegate?.queueEngineLoadSong(this, song, true, startTime);
    this.delegate?.queueEngineDidAdvanceTo(
      this,
      this.currentIndex,
      song.id,
      "skip",
    );
  }

  handleEnded(): void {
    if (this.loopState === "one") {
      const userQueueRemaining = this.isInUserQueue
        ? this.userQueue.length - 1
        : this.userQueue.length;
      if (userQueueRemaining > 0) {
        this.#advanceToNext("ended");
        return;
      }

      const song = this.currentSong;
      if (song) {
        this.delegate?.queueEngineSeekToStart(this, song);
      }
      return;
    }

    this.#advanceToNext("ended");
  }

  skipToNext(): void {
    this.#advanceToNext("next");
  }

  skipToPrevious(currentTime = 0): void {
    if (currentTime > PREVIOUS_SEEK_THRESHOLD_SECONDS) {
      const song = this.currentSong;
      if (song) {
        this.delegate?.queueEngineSeekToStart(this, song);
      }
      return;
    }

    this.#advanceToPrevious();
  }

  setShuffleActive(active: boolean): void {
    if (active) {
      this.#applyShuffle();
    } else {
      this.#applyUnshuffle();
    }
  }

  markAsShuffled(originalSongs: NativeQueueSong[]): void {
    this.isShuffleActive = true;
    this.originalContextSongs = copySongs(originalSongs);
  }

  setLoopState(state: NativeFullState["loopState"]): void {
    this.loopState = state;
  }

  getFullState(options: DesktopQueueFullStateOptions): NativeFullState {
    return {
      contextQueue: {
        songs: copySongs(this.contextSongs),
        currentIndex: this.currentIndex,
        sourceId: this.sourceId,
        sourceName: this.sourceName,
      },
      userQueue: copySongs(this.userQueue),
      originalContextSongs: copySongs(this.originalContextSongs),
      originalUserSongs: copySongs(this.originalUserSongs),
      shuffleHistory: [...this.shuffleHistory],
      shuffleStartHistory: [...this.shuffleStartHistory],
      playedUserQueueHistory: copySongs(this.playedUserQueueHistory),
      isInUserQueue: this.isInUserQueue,
      isShuffleActive: this.isShuffleActive,
      loopState: this.loopState,
      isPlaying: options.isPlaying,
      currentTime: options.currentTime,
      duration: options.duration,
      currentSongId: this.currentSong?.id ?? null,
      isRestored: this.isRestored,
    };
  }

  #advanceToNext(reason: DesktopQueueAdvanceReason): void {
    if (this.isInUserQueue) {
      const updatedQueue = copySongs(this.userQueue);
      const consumed = updatedQueue.shift();
      if (consumed) {
        this.userQueue = updatedQueue;
        this.playedUserQueueHistory = [
          ...this.playedUserQueueHistory,
          consumed,
        ];
        this.#pushShuffleHistory(consumed.id);
      }

      if (this.userQueue.length > 0) {
        this.#notifyAdvance(reason);
        return;
      }

      this.isInUserQueue = false;
      if (this.currentIndex < this.contextSongs.length - 1) {
        this.currentIndex += 1;
      } else if (this.loopState === "all") {
        this.#wrapToStart();
      }
      this.#notifyAdvance(reason);
      return;
    }

    if (this.userQueue.length > 0) {
      const current = this.currentSong;
      if (current) this.#pushShuffleHistory(current.id);
      this.isInUserQueue = true;
      this.#notifyAdvance(reason);
      return;
    }

    const current = this.currentSong;
    if (current) this.#pushShuffleHistory(current.id);

    if (this.currentIndex < this.contextSongs.length - 1) {
      this.currentIndex += 1;
      this.#notifyAdvance(reason);
      return;
    }

    if (this.loopState === "all") {
      this.#wrapToStart();
      this.#notifyAdvance(reason);
      return;
    }

    this.delegate?.queueEngineDidExhaustQueue(this);
  }

  #advanceToPrevious(): void {
    if (this.playedUserQueueHistory.length > 0) {
      const updatedHistory = copySongs(this.playedUserQueueHistory);
      const restored = updatedHistory.pop();
      if (!restored) return;

      this.playedUserQueueHistory = updatedHistory;
      this.userQueue = [restored, ...this.userQueue];

      const wasInUserQueue = this.isInUserQueue;
      this.isInUserQueue = true;

      if (!wasInUserQueue && this.currentIndex > 0) {
        this.currentIndex -= 1;
      }

      this.#notifyAdvance("previous");
      return;
    }

    if (this.isInUserQueue) {
      this.isInUserQueue = false;
      this.#notifyAdvance("previous");
      return;
    }

    if (this.currentIndex > 0) {
      this.currentIndex -= 1;
      this.#notifyAdvance("previous");
    }
  }

  #wrapToStart(): void {
    const lastPlayedId = this.contextSongs[this.currentIndex]?.id ?? null;
    this.currentIndex = 0;
    this.#reshuffleForWrap(lastPlayedId);
  }

  #notifyAdvance(reason: DesktopQueueAdvanceReason): void {
    const song = this.currentSong;
    if (!song) return;

    this.delegate?.queueEngineLoadSong(this, song, true, undefined);
    this.delegate?.queueEngineDidAdvanceTo(
      this,
      this.currentIndex,
      song.id,
      reason,
    );
  }

  #applyShuffle(): void {
    if (this.contextSongs.length <= 1) return;

    this.originalContextSongs = copySongs(this.contextSongs);

    const current = this.currentSong;
    if (current) {
      this.shuffleStartHistory = pushToHistory(
        this.shuffleStartHistory,
        current.id,
        this.#maxShuffleStartHistory,
      );
    }

    const upcoming = this.contextSongs.slice(this.currentIndex + 1);
    if (upcoming.length > 0) {
      this.contextSongs = [
        ...this.contextSongs.slice(0, this.currentIndex + 1),
        ...shuffleWithGapAvoidance(
          upcoming,
          this.shuffleHistory,
          this.#random,
        ),
      ];
    }

    if (this.userQueue.length > 0) {
      this.originalUserSongs = copySongs(this.userQueue);
      this.userQueue = shuffleWithGapAvoidance(
        this.userQueue,
        this.shuffleHistory,
        this.#random,
      );
    }

    this.isShuffleActive = true;
    this.delegate?.queueEngineDidChangeContents(this, "shuffle");
  }

  #applyUnshuffle(): void {
    if (this.originalContextSongs.length === 0) {
      this.isShuffleActive = false;
      return;
    }

    const currentSongId = this.currentSong?.id ?? null;
    const newIndex =
      currentSongId === null
        ? -1
        : this.originalContextSongs.findIndex(
            (song) => song.id === currentSongId,
          );

    this.contextSongs = copySongs(this.originalContextSongs);
    this.currentIndex =
      newIndex === -1
        ? Math.min(this.currentIndex, this.contextSongs.length - 1)
        : newIndex;

    if (this.originalUserSongs.length > 0) {
      this.userQueue = copySongs(this.originalUserSongs);
      this.originalUserSongs = [];
    }

    this.originalContextSongs = [];
    this.playedUserQueueHistory = [];
    this.isShuffleActive = false;
    this.shuffleHistory = [];
    this.delegate?.queueEngineDidChangeContents(this, "unshuffle");
  }

  #reshuffleForWrap(lastPlayedSongId: string | null): void {
    if (!this.isShuffleActive || this.contextSongs.length <= 1) return;

    const reshuffled = shuffleWithGapAvoidance(
      this.contextSongs.slice(1),
      this.shuffleHistory,
      this.#random,
    );

    if (lastPlayedSongId) {
      const lastPlayedIndex = reshuffled.findIndex(
        (song) => song.id === lastPlayedSongId,
      );
      if (lastPlayedIndex !== -1) {
        const [song] = reshuffled.splice(lastPlayedIndex, 1);
        if (song) reshuffled.push(song);
      }
    }

    const firstSong = this.contextSongs[0];
    this.contextSongs = firstSong ? [firstSong, ...reshuffled] : reshuffled;
  }

  #pushShuffleHistory(id: string): void {
    this.shuffleHistory = pushToHistory(
      this.shuffleHistory,
      id,
      this.#maxShuffleHistory,
    );
  }
}

function copySongs(songs: NativeQueueSong[]): NativeQueueSong[] {
  return songs.map((song) => ({ ...song }));
}

function normalizeSongIndex(index: number, songs: NativeQueueSong[]): number {
  if (songs.length === 0) return 0;
  return Math.max(0, Math.min(index, songs.length - 1));
}

function isValidIndex(index: number, songs: NativeQueueSong[]): boolean {
  return Number.isInteger(index) && index >= 0 && index < songs.length;
}

function shuffleWithGapAvoidance(
  songs: NativeQueueSong[],
  history: string[],
  random: () => number,
): NativeQueueSong[] {
  if (history.length === 0) {
    return fisherYates(copySongs(songs), random);
  }

  const historyIndex = new Map(history.map((id, index) => [id, index]));
  const fresh: NativeQueueSong[] = [];
  const recent: NativeQueueSong[] = [];

  for (const song of songs) {
    if (historyIndex.has(song.id)) {
      recent.push({ ...song });
    } else {
      fresh.push({ ...song });
    }
  }

  recent.sort((a, b) => {
    return (historyIndex.get(a.id) ?? 0) - (historyIndex.get(b.id) ?? 0);
  });

  return [...fisherYates(fresh, random), ...recent];
}

function fisherYates<T>(items: T[], random: () => number): T[] {
  for (let index = items.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1));
    [items[index], items[swapIndex]] = [items[swapIndex], items[index]];
  }

  return items;
}

function pushToHistory(history: string[], id: string, maxLength: number) {
  const updated = history.filter((item) => item !== id);
  updated.push(id);

  if (updated.length > maxLength) {
    return updated.slice(updated.length - maxLength);
  }

  return updated;
}
