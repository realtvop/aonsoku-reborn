import { useCallback, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { projectPlaybackProgress } from "@/coordination/progress";
import { useCoordinationStore } from "@/coordination/store";
import type { PlaybackSnapshot, RemoteCommand } from "@/coordination/types";
import { isNativeCoordinationAvailable } from "@/native/coordination";
import { seekPlaybackTarget } from "@/player/playback/backend-registry";
import { getNativeQueueController } from "@/player/queue-controller";
import {
  usePlayerActions,
  usePlayerCurrentSong,
  usePlayerIsPlaying,
  usePlayerLoop,
  usePlayerShuffle,
  usePlayerStore,
  usePlayerVolume,
} from "@/store/player.store";
import { LoopState, type QueueSourceId } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import { getPlaybackCapabilities } from "@/utils/capabilities";
import { logger } from "@/utils/logger";

const SNAPSHOT_HEARTBEAT_MS = 10_000;

// Encode a QueueSourceId into the snapshot's free-form sourceId string as
// "<type>:<id>" so the receiver can reconstruct the source identity (album /
// playlist / artist / genre / radio) and re-fetch the original ordered list
// for unshuffle support. `null` source becomes `null`.
function encodeSourceId(sourceId: QueueSourceId): string | null {
  if (!sourceId) return null;
  return `${sourceId.type}:${sourceId.id}`;
}

// Decode a snapshot sourceId string ("<type>:<id>") back to QueueSourceId.
// Returns null when absent or unparseable.
function decodeSourceId(raw: string | null | undefined): QueueSourceId {
  if (!raw) return null;
  const sep = raw.indexOf(":");
  if (sep <= 0) return null;
  const type = raw.slice(0, sep);
  const id = raw.slice(sep + 1);
  if (!id) return null;
  if (
    type === "album" ||
    type === "playlist" ||
    type === "artist" ||
    type === "genre" ||
    type === "radio"
  ) {
    return { type, id };
  }
  return null;
}

// Re-fetch the original ordered source list (album/playlist) from the
// Navidrome/Subsonic API so the receiver can restore shuffle-off-to-original
// behavior. Returns null for non-refetchable sources.
async function fetchOriginalSourceSongs(
  sourceId: QueueSourceId,
): Promise<ISong[] | null> {
  if (!sourceId) return null;
  const { subsonic } = await import("@/service/subsonic");
  if (sourceId.type === "album") {
    try {
      const album = await subsonic.albums.getOne(sourceId.id);
      return album?.song ?? null;
    } catch (err) {
      logger.error(
        "[CoordinationObserver] fetchOriginalSourceSongs album failed:",
        err,
      );
      return null;
    }
  }
  if (sourceId.type === "playlist") {
    try {
      const playlist = await subsonic.playlists.getOne(sourceId.id);
      return playlist?.entry ?? null;
    } catch (err) {
      logger.error(
        "[CoordinationObserver] fetchOriginalSourceSongs playlist failed:",
        err,
      );
      return null;
    }
  }
  return null;
}

// Fetch song metadata for all song ids in a snapshot and return a Map keyed
// by song id. Used when restoring a full queue from a remote snapshot.
async function fetchSongMap(
  snapshot: PlaybackSnapshot,
): Promise<Map<
  string,
  NonNullable<
    Awaited<
      ReturnType<typeof import("@/service/subsonic")>["songs"]["getSong"]
    >["0"]
  >
> | null> {
  const { subsonic } = await import("@/service/subsonic");
  const ids = Array.from(
    new Set([
      snapshot.songId,
      ...snapshot.contextQueue,
      ...snapshot.userQueue,
      ...snapshot.restorePrevious,
    ]),
  ).filter(Boolean);
  if (ids.length === 0) return null;
  const fetched = await Promise.all(
    ids.map((id) => subsonic.songs.getSong(id)),
  );
  const map = new Map<string, NonNullable<(typeof fetched)[number]>>();
  for (const s of fetched) {
    if (s) map.set(s.id, s);
  }
  return map;
}

// Apply the full snapshot to the local player store, restoring the exact
// queue experience (current song, context queue, user queue, shuffle, repeat,
// volume, progress, inUserQueue, sourceName). Song metadata is fetched from
// the local Navidrome/Subsonic API by id (design §7.3). The original source
// list (album/playlist order) is re-fetched when a typed sourceId is present
// so that unshuffle restores the original order, matching the source device.
async function applySnapshotToPlayerStore(
  snapshot: PlaybackSnapshot,
  opts: { playing: boolean },
): Promise<void> {
  const songMap = await fetchSongMap(snapshot);
  if (!songMap) return;
  const current = songMap.get(snapshot.songId);
  if (!current) return;

  const contextSongs = snapshot.contextQueue
    .map((id) => songMap.get(id))
    .filter((s): s is NonNullable<typeof s> => !!s);
  const userSongs = snapshot.userQueue
    .map((id) => songMap.get(id))
    .filter((s): s is NonNullable<typeof s> => !!s);
  const restorePreviousSongs = snapshot.restorePrevious
    .map((id) => songMap.get(id))
    .filter((s): s is NonNullable<typeof s> => !!s);

  const sourceId = decodeSourceId(snapshot.sourceId);
  // Re-fetch the original ordered list so unshuffle returns to album/playlist
  // order exactly like on the source device. Falls back to the context queue
  // (already-ordered) when the source cannot be re-fetched.
  const originalSourceSongs = sourceId
    ? ((await fetchOriginalSourceSongs(sourceId)) ?? null)
    : null;
  const sourceSongsForRestore: ISong[] =
    originalSourceSongs && originalSourceSongs.length > 0
      ? originalSourceSongs
      : contextSongs.length > 0
        ? contextSongs
        : [current];

  // Find the current song's position in the original source list so that
  // sourceQueue.currentIndex reflects the unshuffled position.
  const sourceIndex = sourceSongsForRestore.findIndex(
    (s) => s.id === current.id,
  );
  const sourceCurrentIndex = sourceIndex >= 0 ? sourceIndex : 0;

  usePlayerStore.setState((state) => {
    const effectiveContext = contextSongs.length > 0 ? contextSongs : [current];
    const ctxIdx = Math.max(
      0,
      Math.min(
        snapshot.contextIndex ?? 0,
        Math.max(0, effectiveContext.length - 1),
      ),
    );
    state.songlist.currentSong = current;
    state.songlist.contextQueue = {
      songs: effectiveContext,
      currentIndex: ctxIdx,
      sourceId,
      sourceName: snapshot.sourceName ?? null,
    };
    state.songlist.sourceQueue = {
      songs: sourceSongsForRestore,
      currentIndex: sourceCurrentIndex,
      sourceId,
      sourceName: snapshot.sourceName ?? null,
    };
    state.songlist.userQueue = { songs: userSongs };
    state.songlist.isInUserQueue = snapshot.inUserQueue;
    state.songlist.playedUserQueueHistory = restorePreviousSongs;
    state.songlist.isShuffleActive = snapshot.shuffle;
    state.songlist.shuffleHistory = [];
    state.songlist.shuffleStartHistory = [];
    state.songlist.originalContextSongs = [...sourceSongsForRestore];
    state.songlist.radioList = [];
    state.playerState.mediaType = "song";
    state.playerState.isPlaying = opts.playing;
    state.playerState.currentDuration = snapshot.durationSeconds;
    state.playerState.loopState = mapRepeatModeToLoopState(snapshot.repeat);
    if (snapshot.volume !== null) {
      state.playerState.volume = Math.round(snapshot.volume * 100);
    }
    state.playerProgress.progress = snapshot.progressSeconds;
    state.playerProgress.bufferedProgress = 0;
  });
}

function mapLoopState(loop: LoopState): "off" | "one" | "all" {
  switch (loop) {
    case LoopState.One:
      return "one";
    case LoopState.All:
      return "all";
    default:
      return "off";
  }
}

function mapRepeatModeToLoopState(mode: string): LoopState {
  switch (mode) {
    case "one":
      return LoopState.One;
    case "all":
      return LoopState.All;
    default:
      return LoopState.Off;
  }
}

function buildPlaybackSnapshot(
  sessionId: string,
  song: ISong,
  isPlaying: boolean,
  shuffleEnabled: boolean,
  loopState: LoopState,
  volume: number,
): PlaybackSnapshot {
  const state = usePlayerStore.getState();
  const audioProgress = state.playerState.audioPlayerRef?.currentTime;
  const canReadWebAudioProgress =
    !getPlaybackCapabilities().supportsNativePlayback &&
    typeof audioProgress === "number" &&
    Number.isFinite(audioProgress);

  return {
    sessionId,
    logicalPlaybackSessionId: sessionId,
    mediaKind: "song",
    songId: song.id,
    progressSeconds: canReadWebAudioProgress
      ? Math.max(0, audioProgress)
      : Math.max(0, state.playerProgress.progress),
    durationSeconds: song.duration ?? 0,
    isPlaying,
    sampledAt: Date.now() / 1000,
    contextQueue: state.songlist.contextQueue.songs.map((s) => s.id),
    contextIndex: state.songlist.contextQueue.currentIndex,
    sourceId: encodeSourceId(state.songlist.contextQueue.sourceId),
    sourceName: state.songlist.contextQueue.sourceName ?? null,
    userQueue: state.songlist.userQueue.songs.map((s) => s.id),
    inUserQueue: state.songlist.isInUserQueue,
    restorePrevious: state.songlist.playedUserQueueHistory.map((s) => s.id),
    shuffle: shuffleEnabled,
    repeat: mapLoopState(loopState),
    volume: volume / 100,
    accumulatedPlaySeconds: 0,
    historyWritten: false,
    nowPlayingSent: false,
    scrobbleSent: false,
  };
}

async function prepareNativeHandoffPlayback(
  snapshot: PlaybackSnapshot,
  autoplay: boolean,
): Promise<boolean> {
  const nativeController = getNativeQueueController();
  if (!nativeController) return false;

  await nativeController.prepareHandoffPlayback(snapshot.progressSeconds, {
    autoplay,
  });
  return true;
}

export function CoordinationObserver() {
  const nativeCoordinationAvailable = isNativeCoordinationAvailable();
  const isConnected = useCoordinationStore((state) => state.isConnected);
  const loadState = useCoordinationStore((state) => state.loadState);
  const manager = useCoordinationStore((state) => state.manager);
  const setLocalDeviceSnapshot = useCoordinationStore(
    (state) => state.setLocalDeviceSnapshot,
  );
  const { t } = useTranslation();
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const controlledSnapshot = useCoordinationStore((state) =>
    controlledDeviceId ? state.deviceSnapshots[controlledDeviceId] : null,
  );

  const playerActions = usePlayerActions();
  const currentSong = usePlayerCurrentSong();
  const isPlaying = usePlayerIsPlaying();
  const { volume } = usePlayerVolume();
  const loopState = usePlayerLoop();
  const shuffleEnabled = usePlayerShuffle();
  const sessionIdRef = useRef<string>(crypto.randomUUID());
  const generationRef = useRef<number>(1);
  const snapshotRevisionRef = useRef<number>(0);

  const publishCurrentSnapshot = useCallback(() => {
    if (nativeCoordinationAvailable) return;
    if (!isConnected || !currentSong) return;
    if (usePlayerStore.getState().remoteControl.active) return;

    const snapshot = buildPlaybackSnapshot(
      sessionIdRef.current,
      currentSong,
      isPlaying,
      shuffleEnabled,
      loopState,
      volume,
    );
    snapshotRevisionRef.current++;
    setLocalDeviceSnapshot(
      snapshot,
      generationRef.current,
      snapshotRevisionRef.current,
    );
    manager.publishSnapshot(
      sessionIdRef.current,
      generationRef.current,
      snapshotRevisionRef.current,
      snapshot,
    );
  }, [
    isConnected,
    currentSong,
    isPlaying,
    shuffleEnabled,
    loopState,
    volume,
    manager,
    setLocalDeviceSnapshot,
    nativeCoordinationAvailable,
  ]);

  // Load coordination state and auto-connect on mount
  useEffect(() => {
    loadState().catch(() => {});
  }, [loadState]);

  // Publish snapshot when playback state changes (design §9.2).
  // NOTE: playerProgress is intentionally excluded from the dependency array.
  // Progress updates fire ~4x/sec via `timeupdate` and would bump
  // snapshotRevision on every tick, making handoff's optimistic-concurrency
  // check (expectedSnapshotRevision) fail almost immediately. Structural
  // changes (song/queue/shuffle/repeat/volume/play-pause) still publish; the
  // current progress is read from the store and included in those snapshots.
  // Receivers interpolate progress via sampledAt + isPlaying, and the
  // handoff's relinquish_ack carries an exact final progress.
  useEffect(() => {
    publishCurrentSnapshot();
  }, [publishCurrentSnapshot]);

  useEffect(
    () =>
      usePlayerStore.subscribe(
        (state) => state.playerProgress.seekCount,
        publishCurrentSnapshot,
      ),
    [publishCurrentSnapshot],
  );

  useEffect(() => {
    if (!isConnected || !currentSong || !isPlaying) return;
    const interval = setInterval(publishCurrentSnapshot, SNAPSHOT_HEARTBEAT_MS);
    return () => clearInterval(interval);
  }, [isConnected, currentSong, isPlaying, publishCurrentSnapshot]);

  useEffect(() => {
    const handleForeground = () => {
      if (document.hidden) return;
      publishCurrentSnapshot();
    };
    document.addEventListener("visibilitychange", handleForeground);
    window.addEventListener("pageshow", handleForeground);
    return () => {
      document.removeEventListener("visibilitychange", handleForeground);
      window.removeEventListener("pageshow", handleForeground);
    };
  }, [publishCurrentSnapshot]);

  // Handle remote commands from other devices (design §10).
  useEffect(() => {
    if (nativeCoordinationAvailable) return;
    if (!isConnected) return;
    const original = manager.callbacks.onRemoteCommand;
    manager.callbacks.onRemoteCommand = (
      command: RemoteCommand,
      _sourceDeviceId: string,
    ) => {
      switch (command.type) {
        case "play":
          playerActions.setPlayingState(true);
          break;
        case "pause":
          playerActions.setPlayingState(false);
          break;
        case "toggle_play_pause":
          playerActions.togglePlayPause();
          break;
        case "previous":
          playerActions.playPrevSong();
          break;
        case "next":
          playerActions.playNextSong();
          break;
        case "seek": {
          const audio = usePlayerStore.getState().playerState.audioPlayerRef;
          if (audio && !getPlaybackCapabilities().supportsNativePlayback) {
            seekPlaybackTarget(audio, command.seconds);
          }
          playerActions.setProgress(command.seconds, true);
          break;
        }
        case "set_volume":
          playerActions.setVolume(command.volume * 100);
          break;
        case "set_shuffle": {
          const nativeController = getNativeQueueController();
          if (nativeController) {
            nativeController.setShuffleState(command.enabled);
            break;
          }
          if (command.enabled !== shuffleEnabled) {
            playerActions.toggleShuffle();
          }
          break;
        }
        case "set_repeat": {
          const targetLoop = mapRepeatModeToLoopState(command.mode);
          const nativeController = getNativeQueueController();
          if (nativeController) {
            nativeController.setLoopState(targetLoop);
            break;
          }
          const currentLoop = usePlayerStore.getState().playerState.loopState;
          if (targetLoop === currentLoop) break;
          // toggleLoop cycles Off → All → One → Off.
          // Compute the number of toggles needed to reach targetLoop.
          const order = [LoopState.Off, LoopState.All, LoopState.One];
          const currentPos = order.indexOf(currentLoop);
          const targetPos = order.indexOf(targetLoop);
          const toggles = (targetPos - currentPos + 3) % 3;
          for (let i = 0; i < toggles; i++) playerActions.toggleLoop();
          break;
        }
        case "clear_queue":
          playerActions.clearUserQueue();
          break;
        case "play_song":
          import("@/service/subsonic").then(({ subsonic }) => {
            subsonic.songs
              .getSong(command.song_id)
              .then((song) => {
                if (song) playerActions.playSong(song);
              })
              .catch((err) =>
                logger.error("[CoordinationObserver] play_song failed:", err),
              );
          });
          break;
        case "play_at_index":
          import("@/service/subsonic").then(({ subsonic }) => {
            Promise.all(
              command.song_ids.map((id) => subsonic.songs.getSong(id)),
            )
              .then((songs) => {
                const valid = songs.filter(
                  (s): s is NonNullable<typeof s> => !!s,
                );
                if (valid.length > 0) {
                  const index = Math.max(
                    0,
                    Math.min(command.index, valid.length - 1),
                  );
                  playerActions.setSongList(valid, index, false);
                }
              })
              .catch((err) =>
                logger.error(
                  "[CoordinationObserver] play_at_index failed:",
                  err,
                ),
              );
          });
          break;
        case "play_album":
          import("@/service/subsonic").then(({ subsonic }) => {
            subsonic.albums
              .getOne(command.album_id)
              .then((album) => {
                if (album && album.song.length > 0) {
                  const index = Math.max(
                    0,
                    Math.min(command.index ?? 0, album.song.length - 1),
                  );
                  playerActions.setSongList(
                    album.song,
                    index,
                    Boolean(command.shuffle),
                    { albumId: command.album_id },
                    album.name,
                  );
                }
              })
              .catch((err) =>
                logger.error("[CoordinationObserver] play_album failed:", err),
              );
          });
          break;
        case "play_playlist":
          import("@/service/subsonic").then(({ subsonic }) => {
            subsonic.playlists
              .getOne(command.playlist_id)
              .then((playlist) => {
                if (playlist && playlist.entry.length > 0) {
                  const index = Math.max(
                    0,
                    Math.min(command.index ?? 0, playlist.entry.length - 1),
                  );
                  playerActions.setSongList(
                    playlist.entry,
                    index,
                    Boolean(command.shuffle),
                    { playlistId: command.playlist_id },
                    playlist.name,
                  );
                }
              })
              .catch((err) =>
                logger.error(
                  "[CoordinationObserver] play_playlist failed:",
                  err,
                ),
              );
          });
          break;
        case "add_to_queue_next":
          import("@/service/subsonic").then(({ subsonic }) => {
            Promise.all(
              command.song_ids.map((id) => subsonic.songs.getSong(id)),
            )
              .then((songs) => {
                const valid = songs.filter(
                  (s): s is NonNullable<typeof s> => !!s,
                );
                if (valid.length > 0) playerActions.setNextOnQueue(valid);
              })
              .catch((err) =>
                logger.error(
                  "[CoordinationObserver] add_to_queue_next failed:",
                  err,
                ),
              );
          });
          break;
        case "add_to_queue_last":
          import("@/service/subsonic").then(({ subsonic }) => {
            Promise.all(
              command.song_ids.map((id) => subsonic.songs.getSong(id)),
            )
              .then((songs) => {
                const valid = songs.filter(
                  (s): s is NonNullable<typeof s> => !!s,
                );
                if (valid.length > 0) playerActions.setLastOnQueue(valid);
              })
              .catch((err) =>
                logger.error(
                  "[CoordinationObserver] add_to_queue_last failed:",
                  err,
                ),
              );
          });
          break;
        case "remove_from_queue":
          for (const id of command.song_ids) {
            playerActions.removeSongFromQueue(id);
          }
          break;
        case "reorder_queue":
          playerActions.reorderQueue(command.from, command.to);
          break;
        case "toggle_like":
          playerActions
            .starCurrentSong()
            .catch((err) =>
              logger.error("[CoordinationObserver] toggle_like failed:", err),
            );
          break;
        default:
          break;
      }
    };
    return () => {
      manager.callbacks.onRemoteCommand = original;
    };
  }, [
    isConnected,
    manager,
    nativeCoordinationAvailable,
    playerActions,
    shuffleEnabled,
  ]);

  // Handle prepare_relinquish: pause the local player (design §11.1 step 4-5).
  useEffect(() => {
    if (nativeCoordinationAvailable) return;
    if (!isConnected) return;
    const original = manager.callbacks.onPrepareRelinquish;
    manager.callbacks.onPrepareRelinquish = (
      transactionId: string,
      _expectedRevision: number,
    ) => {
      playerActions.setPlayingState(false);
      if (currentSong) {
        const finalSnapshot = buildPlaybackSnapshot(
          sessionIdRef.current,
          currentSong,
          false,
          shuffleEnabled,
          loopState,
          volume,
        );
        manager.sendRelinquishAck(transactionId, finalSnapshot);
      }
    };
    return () => {
      manager.callbacks.onPrepareRelinquish = original;
    };
  }, [
    isConnected,
    manager,
    playerActions,
    currentSong,
    shuffleEnabled,
    loopState,
    volume,
    nativeCoordinationAvailable,
  ]);

  // Handle handoff_candidate: fetch metadata, preload the full queue paused,
  // seek to the snapshot progress, and send target_ready (design §11.1 step 2-3).
  useEffect(() => {
    if (nativeCoordinationAvailable) return;
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffCandidate;
    manager.callbacks.onHandoffCandidate = (
      snapshot: PlaybackSnapshot,
      transactionId: string,
      generation: number,
      snapshotRevision: number,
      sourceDeviceId?: string | null,
      sessionId?: string | null,
    ) => {
      if (!snapshot.songId) return;
      const state = usePlayerStore.getState();
      const isSameSong = state.songlist.currentSong?.id === snapshot.songId;
      applySnapshotToPlayerStore(snapshot, { playing: false })
        .then(async () => {
          const nativePrepared = await prepareNativeHandoffPlayback(
            snapshot,
            false,
          );
          if (nativePrepared) {
            manager.sendTargetReady(
              transactionId,
              generation,
              snapshotRevision,
              sourceDeviceId,
              sessionId,
            );
            return;
          }

          if (isSameSong) {
            const audio = usePlayerStore.getState().playerState.audioPlayerRef;
            if (audio) {
              seekPlaybackTarget(audio, snapshot.progressSeconds);
            }
          }
          manager.sendTargetReady(
            transactionId,
            generation,
            snapshotRevision,
            sourceDeviceId,
            sessionId,
          );
        })
        .catch((err) => {
          logger.error(
            "[CoordinationObserver] Handoff candidate load failed:",
            err,
          );
        });
    };
    return () => {
      manager.callbacks.onHandoffCandidate = original;
    };
  }, [isConnected, manager, nativeCoordinationAvailable]);

  // Handle handoff_committed: apply the final snapshot (with A's last-second
  // state) and resume playback (design §11.1 step 7).
  useEffect(() => {
    if (nativeCoordinationAvailable) return;
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffCommitted;
    manager.callbacks.onHandoffCommitted = (
      snapshot: PlaybackSnapshot,
      _newGeneration: number,
    ) => {
      if (!snapshot.songId) return;
      const state = usePlayerStore.getState();
      const isSameSong = state.songlist.currentSong?.id === snapshot.songId;
      applySnapshotToPlayerStore(snapshot, { playing: true })
        .then(async () => {
          const nativePrepared = await prepareNativeHandoffPlayback(
            snapshot,
            true,
          );
          if (nativePrepared) return;

          if (isSameSong) {
            const audio = usePlayerStore.getState().playerState.audioPlayerRef;
            if (audio) {
              seekPlaybackTarget(audio, snapshot.progressSeconds);
            }
          }
        })
        .catch((err) => {
          logger.error(
            "[CoordinationObserver] Handoff committed apply failed:",
            err,
          );
        });
    };
    return () => {
      manager.callbacks.onHandoffCommitted = original;
    };
  }, [isConnected, manager, nativeCoordinationAvailable]);

  // Handle handoff_failed
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffFailed;
    manager.callbacks.onHandoffFailed = (
      _transactionId: string,
      code: string,
    ) => {
      toast.error(
        t("settings.crossDevice.toast.relayFailed", {
          defaultValue: "Handoff failed: {{code}}",
          code,
        }),
      );
    };
    return () => {
      manager.callbacks.onHandoffFailed = original;
    };
  }, [isConnected, manager, t]);

  // Handle session_superseded (design §11.3): A's session was transferred to
  // another device while A was offline/away. Pause local playback, drop the
  // stale session id/generation so the next publish uses a fresh session,
  // and notify the user. The user must manually start a new session to
  // resume local playback.
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onSessionSuperseded;
    manager.callbacks.onSessionSuperseded = (
      _supersededGeneration: number,
      transferredToDevice: string | null,
    ) => {
      if (!nativeCoordinationAvailable) {
        playerActions.setPlayingState(false);
        sessionIdRef.current = crypto.randomUUID();
        generationRef.current = 1;
        snapshotRevisionRef.current = 0;
      }
      const deviceName =
        useCoordinationStore
          .getState()
          .devices.find((d) => d.id === transferredToDevice)?.name ??
        "another device";
      toast.info(
        t("settings.crossDevice.toast.sessionSuperseded", {
          defaultValue:
            "This session has been taken over by {{deviceName}}, playback paused.",
          deviceName,
        }),
      );
    };
    return () => {
      manager.callbacks.onSessionSuperseded = original;
    };
  }, [isConnected, manager, nativeCoordinationAvailable, playerActions, t]);

  // Reflect controlled-device transport state without adopting its queue.
  // Remote control is observation/control, not handoff: the local queue must
  // remain intact so returning to local playback resumes the user's queue.
  useEffect(() => {
    if (!controlledDeviceId || !controlledSnapshot) return;
    const { snapshot } = controlledSnapshot;
    const projectedProgress = projectPlaybackProgress(controlledSnapshot);

    usePlayerStore.setState((state) => {
      state.playerState.isPlaying = snapshot.isPlaying;
      state.playerState.currentDuration = snapshot.durationSeconds;
      if (!state.playerProgress.isScrubbing) {
        state.playerProgress.progress = projectedProgress;
      }
      if (snapshot.volume !== null) {
        state.playerState.volume = Math.round(snapshot.volume * 100);
      }
    });
  }, [controlledDeviceId, controlledSnapshot]);

  // Interpolate controlled device progress between snapshots.
  //
  // Use a wall-clock based accumulator rather than a fixed +0.1s tick so the
  // progress tracks real elapsed time even when the browser throttles
  // background timers. When the tab becomes visible again, request a fresh
  // snapshot projection from the server to hard-correct any residual drift.
  useEffect(() => {
    if (!controlledDeviceId || !controlledSnapshot) return;
    const { snapshot } = controlledSnapshot;
    if (!snapshot.isPlaying) return;

    const refreshProgress = () => {
      const projectedProgress = projectPlaybackProgress(controlledSnapshot);
      usePlayerStore.setState((state) => {
        if (!state.playerProgress.isScrubbing) {
          state.playerProgress.progress = projectedProgress;
        }
      });
    };

    const interval = setInterval(refreshProgress, 100);

    const handleForeground = () => {
      if (document.hidden) return;
      refreshProgress();
      if (usePlayerStore.getState().remoteControl.active) {
        manager?.requestSnapshots();
      }
    };
    document.addEventListener("visibilitychange", handleForeground);
    window.addEventListener("pageshow", handleForeground);

    return () => {
      clearInterval(interval);
      document.removeEventListener("visibilitychange", handleForeground);
      window.removeEventListener("pageshow", handleForeground);
    };
  }, [controlledDeviceId, controlledSnapshot, manager]);

  return null;
}
