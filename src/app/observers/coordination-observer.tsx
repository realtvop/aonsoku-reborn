import { useEffect, useRef } from "react";
import { toast } from "react-toastify";
import { useCoordinationStore } from "@/coordination/store";
import type { PlaybackSnapshot, RemoteCommand } from "@/coordination/types";
import {
  usePlayerActions,
  usePlayerCurrentList,
  usePlayerCurrentSong,
  usePlayerLoop,
  usePlayerProgress,
  usePlayerShuffle,
  usePlayerStore,
  usePlayerVolume,
} from "@/store/player.store";
import { getEffectiveIndex } from "@/store/player/queue-utils";
import { LoopState } from "@/types/playerContext";
import { logger } from "@/utils/logger";

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

export function CoordinationObserver() {
  const isConnected = useCoordinationStore((state) => state.isConnected);
  const loadState = useCoordinationStore((state) => state.loadState);
  const manager = useCoordinationStore((state) => state.manager);
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const controlledSnapshot = useCoordinationStore((state) =>
    controlledDeviceId ? state.deviceSnapshots[controlledDeviceId] : null,
  );

  const playerActions = usePlayerActions();
  const currentSong = usePlayerCurrentSong();
  const currentList = usePlayerCurrentList();
  const playerProgress = usePlayerProgress();
  const { volume } = usePlayerVolume();
  const loopState = usePlayerLoop();
  const shuffleEnabled = usePlayerShuffle();
  const sessionIdRef = useRef<string>(crypto.randomUUID());
  const generationRef = useRef<number>(1);
  const snapshotRevisionRef = useRef<number>(0);

  // Load coordination state and auto-connect on mount
  useEffect(() => {
    loadState().catch(() => {});
  }, [loadState]);

  // Publish snapshot when playback state changes (design §9.2).
  useEffect(() => {
    if (!isConnected || !currentSong) return;
    const state = usePlayerStore.getState();
    if (state.remoteControl.active) return;

    const snapshot: PlaybackSnapshot = {
      sessionId: sessionIdRef.current,
      logicalPlaybackSessionId: sessionIdRef.current,
      mediaKind: "song",
      songId: currentSong.id,
      progressSeconds: playerProgress,
      durationSeconds: currentSong.duration ?? 0,
      isPlaying: state.playerState.isPlaying,
      sampledAt: Math.floor(Date.now() / 1000),
      contextQueue: currentList.map((s) => s.id),
      contextIndex: getEffectiveIndex(state.songlist) ?? null,
      sourceId: state.songlist.contextQueue.sourceId?.id ?? null,
      sourceName: state.songlist.contextQueue.sourceName ?? null,
      userQueue: state.songlist.userQueue.songs.map((s) => s.id),
      inUserQueue: state.songlist.isInUserQueue,
      restorePrevious: [],
      shuffle: shuffleEnabled,
      repeat: mapLoopState(loopState),
      volume: volume / 100,
      accumulatedPlaySeconds: 0,
      historyWritten: false,
      nowPlayingSent: false,
      scrobbleSent: false,
    };
    snapshotRevisionRef.current++;
    logger.info("[CoordinationObserver] Publishing snapshot:", snapshot);
    manager.publishSnapshot(
      sessionIdRef.current,
      generationRef.current,
      snapshotRevisionRef.current,
      snapshot,
    );
  }, [
    isConnected,
    currentSong,
    playerProgress,
    currentList,
    shuffleEnabled,
    loopState,
    volume,
    manager,
  ]);

  // Handle remote commands from other devices (design §10).
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onRemoteCommand;
    manager.callbacks.onRemoteCommand = (
      command: RemoteCommand,
      _sourceDeviceId: string,
    ) => {
      console.info(
        `[CoordinationObserver.onRemoteCommand] received: ${JSON.stringify(command)}`,
      );
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
        case "seek":
          playerActions.setProgress(command.seconds);
          break;
        case "set_volume":
          playerActions.setVolume(command.volume * 100);
          break;
        case "set_shuffle":
          if (command.enabled !== shuffleEnabled) {
            playerActions.toggleShuffle();
          }
          break;
        case "set_repeat": {
          const targetLoop = mapRepeatModeToLoopState(command.mode);
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
                logger.error(
                  "[CoordinationObserver] play_song failed:",
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
                    false,
                    { albumId: command.album_id },
                    album.name,
                  );
                }
              })
              .catch((err) =>
                logger.error(
                  "[CoordinationObserver] play_album failed:",
                  err,
                ),
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
                    false,
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
            Promise.all(command.song_ids.map((id) => subsonic.songs.getSong(id)))
              .then((songs) => {
                const valid = songs.filter((s): s is NonNullable<typeof s> => !!s);
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
            Promise.all(command.song_ids.map((id) => subsonic.songs.getSong(id)))
              .then((songs) => {
                const valid = songs.filter((s): s is NonNullable<typeof s> => !!s);
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
          playerActions.starCurrentSong().catch((err) =>
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
  }, [isConnected, manager, playerActions, shuffleEnabled]);

  // Handle prepare_relinquish: pause the local player (design §11.1 step 4-5).
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onPrepareRelinquish;
    manager.callbacks.onPrepareRelinquish = (
      transactionId: string,
      _expectedRevision: number,
    ) => {
      playerActions.setPlayingState(false);
      if (currentSong) {
        const state = usePlayerStore.getState();
        const finalSnapshot: PlaybackSnapshot = {
          sessionId: sessionIdRef.current,
          logicalPlaybackSessionId: sessionIdRef.current,
          mediaKind: "song",
          songId: currentSong.id,
          progressSeconds: state.playerProgress.progress,
          durationSeconds: currentSong.duration ?? 0,
          isPlaying: false,
          sampledAt: Math.floor(Date.now() / 1000),
          contextQueue: currentList.map((s) => s.id),
          contextIndex: getEffectiveIndex(state.songlist) ?? null,
          sourceId: state.songlist.contextQueue.sourceId?.id ?? null,
          sourceName: state.songlist.contextQueue.sourceName ?? null,
          userQueue: state.songlist.userQueue.songs.map((s) => s.id),
          inUserQueue: state.songlist.isInUserQueue,
          restorePrevious: [],
          shuffle: shuffleEnabled,
          repeat: mapLoopState(loopState),
          volume: volume / 100,
          accumulatedPlaySeconds: 0,
          historyWritten: false,
          nowPlayingSent: false,
          scrobbleSent: false,
        };
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
    currentList,
    shuffleEnabled,
    loopState,
    volume,
  ]);

  // Handle handoff_candidate: fetch metadata, load song paused, seek progress, and send target_ready (design §11.1 step 2-3).
  useEffect(() => {
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
      if (snapshot.songId) {
        import("@/service/subsonic").then(({ subsonic }) => {
          subsonic.songs
            .getSong(snapshot.songId)
            .then((song) => {
              if (song) {
                playerActions.playSong(song);
                playerActions.setPlayingState(false);
                playerActions.setProgress(snapshot.progressSeconds);
                manager.sendTargetReady(
                  transactionId,
                  generation,
                  snapshotRevision,
                  sourceDeviceId,
                  sessionId,
                );
              }
            })
            .catch((err) => {
              logger.error(
                "[CoordinationObserver] Handoff candidate load failed:",
                err,
              );
            });
        });
      }
    };
    return () => {
      manager.callbacks.onHandoffCandidate = original;
    };
  }, [isConnected, manager, playerActions]);

  // Handle handoff_committed: apply final snapshot and start playback (design §11.1 step 7).
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffCommitted;
    manager.callbacks.onHandoffCommitted = (
      snapshot: PlaybackSnapshot,
      _newGeneration: number,
    ) => {
      if (snapshot.songId) {
        playerActions.setProgress(snapshot.progressSeconds);
        playerActions.setPlayingState(true);
      }
    };
    return () => {
      manager.callbacks.onHandoffCommitted = original;
    };
  }, [isConnected, manager, playerActions]);

  // Handle handoff_failed
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffFailed;
    manager.callbacks.onHandoffFailed = (
      _transactionId: string,
      code: string,
    ) => {
      toast.error(`Relay failed: ${code}`);
    };
    return () => {
      manager.callbacks.onHandoffFailed = original;
    };
  }, [isConnected, manager]);

  // Sync controlled device snapshot state to local player store
  useEffect(() => {
    if (!controlledDeviceId || !controlledSnapshot) return;
    const { snapshot } = controlledSnapshot;

    usePlayerStore.setState((state) => {
      state.playerState.isPlaying = snapshot.isPlaying;
      state.playerState.currentDuration = snapshot.durationSeconds;
      if (!state.playerProgress.isScrubbing) {
        state.playerProgress.progress = snapshot.progressSeconds;
      }
      state.songlist.isShuffleActive = snapshot.shuffle;
      state.playerState.loopState = mapRepeatModeToLoopState(snapshot.repeat);
      if (snapshot.volume !== null) {
        state.playerState.volume = Math.round(snapshot.volume * 100);
      }
    });

    const currentLocalSong = usePlayerStore.getState().songlist.currentSong;
    const localQueueIds = usePlayerStore
      .getState()
      .songlist.contextQueue.songs.map((s) => s.id);
    const remoteQueueIds = snapshot.contextQueue;
    const remoteUserQueueIds = snapshot.userQueue;
    const queueChanged =
      remoteQueueIds.length !== localQueueIds.length ||
      remoteQueueIds.some((id, i) => id !== localQueueIds[i]) ||
      remoteUserQueueIds.length !==
        usePlayerStore.getState().songlist.userQueue.songs.length;

    if (snapshot.songId && currentLocalSong?.id !== snapshot.songId) {
      import("@/service/subsonic").then(({ subsonic }) => {
        const idsToFetch = Array.from(
          new Set([
            snapshot.songId,
            ...remoteQueueIds,
            ...remoteUserQueueIds,
          ]),
        );
        Promise.all(idsToFetch.map((id) => subsonic.songs.getSong(id)))
          .then((fetched) => {
            const songMap = new Map<string, NonNullable<(typeof fetched)[number]>>();
            for (const s of fetched) {
              if (s) songMap.set(s.id, s);
            }
            const current = songMap.get(snapshot.songId);
            if (!current) return;
            usePlayerStore.setState((state) => {
              const contextSongs = remoteQueueIds
                .map((id) => songMap.get(id))
                .filter((s): s is NonNullable<typeof s> => !!s);
              const userSongs = remoteUserQueueIds
                .map((id) => songMap.get(id))
                .filter((s): s is NonNullable<typeof s> => !!s);
              state.songlist.currentSong = current;
              state.songlist.contextQueue = {
                songs:
                  contextSongs.length > 0 ? contextSongs : [current],
                currentIndex: Math.max(
                  0,
                  Math.min(
                    snapshot.contextIndex ?? 0,
                    Math.max(0, contextSongs.length - 1),
                  ),
                ),
                sourceId: null,
                sourceName: snapshot.sourceName ?? null,
              };
              state.songlist.userQueue = { songs: userSongs };
              state.songlist.isInUserQueue = snapshot.inUserQueue;
              state.playerState.mediaType = "song";
            });
          })
          .catch((err) => {
            logger.error(
              "[CoordinationObserver] Failed to fetch remote queue:",
              err,
            );
            usePlayerStore.setState((state) => {
              state.songlist.currentSong = current;
              state.songlist.contextQueue = {
                songs: [current],
                currentIndex: 0,
                sourceId: null,
                sourceName: snapshot.sourceName ?? null,
              };
              state.songlist.userQueue = { songs: [] };
              state.playerState.mediaType = "song";
            });
          });
      });
    } else if (snapshot.songId && queueChanged) {
      import("@/service/subsonic").then(({ subsonic }) => {
        const idsToFetch = Array.from(
          new Set([...remoteQueueIds, ...remoteUserQueueIds]),
        );
        Promise.all(idsToFetch.map((id) => subsonic.songs.getSong(id)))
          .then((fetched) => {
            const songMap = new Map<string, NonNullable<(typeof fetched)[number]>>();
            for (const s of fetched) {
              if (s) songMap.set(s.id, s);
            }
            usePlayerStore.setState((state) => {
              const contextSongs = remoteQueueIds
                .map((id) => songMap.get(id))
                .filter((s): s is NonNullable<typeof s> => !!s);
              const userSongs = remoteUserQueueIds
                .map((id) => songMap.get(id))
                .filter((s): s is NonNullable<typeof s> => !!s);
              if (contextSongs.length > 0) {
                state.songlist.contextQueue = {
                  songs: contextSongs,
                  currentIndex: Math.max(
                    0,
                    Math.min(
                      snapshot.contextIndex ?? 0,
                      contextSongs.length - 1,
                    ),
                  ),
                  sourceId: null,
                  sourceName: snapshot.sourceName ?? null,
                };
              }
              state.songlist.userQueue = { songs: userSongs };
              state.songlist.isInUserQueue = snapshot.inUserQueue;
            });
          })
          .catch((err) =>
            logger.error(
              "[CoordinationObserver] Failed to sync remote queue:",
              err,
            ),
          );
      });
    }
  }, [controlledDeviceId, controlledSnapshot]);

  // Interpolate controlled device progress between snapshots
  useEffect(() => {
    if (!controlledDeviceId || !controlledSnapshot) return;
    const { snapshot } = controlledSnapshot;
    if (!snapshot.isPlaying) return;

    const interval = setInterval(() => {
      usePlayerStore.setState((state) => {
        if (!state.playerProgress.isScrubbing) {
          const newProgress = Math.min(
            state.playerProgress.progress + 0.1,
            state.playerState.currentDuration,
          );
          state.playerProgress.progress = newProgress;
        }
      });
    }, 100);

    return () => clearInterval(interval);
  }, [controlledDeviceId, controlledSnapshot]);

  return null;
}
