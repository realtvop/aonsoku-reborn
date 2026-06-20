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

export function CoordinationObserver() {
  const isConnected = useCoordinationStore((state) => state.isConnected);
  const loadState = useCoordinationStore((state) => state.loadState);
  const manager = useCoordinationStore((state) => state.manager);
  const controlledDeviceId = useCoordinationStore((state) => state.controlledDeviceId);
  const controlledSnapshot = useCoordinationStore((state) =>
    controlledDeviceId ? state.deviceSnapshots[controlledDeviceId] : null
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
      sampledAt: Date.now() / 1000,
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
          playerActions.playPrev();
          break;
        case "next":
          playerActions.playNext();
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
        case "set_repeat":
          playerActions.toggleLoop();
          break;
        case "clear_queue":
          playerActions.clearUserQueue();
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
          sampledAt: Date.now() / 1000,
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
                manager.sendTargetReady(transactionId, generation, snapshotRevision);
              }
            })
            .catch((err) => {
              logger.error("[CoordinationObserver] Handoff candidate load failed:", err);
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
    manager.callbacks.onHandoffFailed = (_transactionId: string, code: string) => {
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
    });

    const currentLocalSong = usePlayerStore.getState().songlist.currentSong;
    if (snapshot.songId && currentLocalSong?.id !== snapshot.songId) {
      import("@/service/subsonic").then(({ subsonic }) => {
        subsonic.songs
          .getSong(snapshot.songId)
          .then((song) => {
            if (song) {
              usePlayerStore.setState((state) => {
                state.songlist.currentSong = song;
                state.songlist.contextQueue.songs = [song];
                state.songlist.contextQueue.currentIndex = 0;
                state.playerState.mediaType = "song";
              });
            }
          })
          .catch((err) => {
            logger.error("[CoordinationObserver] Failed to fetch remote song:", err);
          });
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
