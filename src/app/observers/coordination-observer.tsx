// Coordination observer — bridges the coordination protocol with the player
// store and playback backend (design §9.2, §10, §11).
//
// This component is mounted at the root (like LanControlObserver) and:
// 1. Publishes playback snapshots to the coordination server on state changes.
// 2. Handles incoming remote commands by dispatching to playerActions.
// 3. Handles handoff prepare_relinquish by pausing the local player.
// 4. Applies handoff_committed snapshots to resume playback on B.
//
// Multi-stack consistency: the same RemoteCommand → playerAction mapping is
// used for both Web/Electron and native (via the existing playback-actions
// branch that delegates to getNativeQueueController() on iOS/Android).

import { useEffect, useRef } from "react";
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
          // Media commands (play_song, play_album, etc.) require fetching
          // metadata from Navidrome — handled in a future iteration
          // with the same subsonic service used by LanControlObserver.
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
      // Pause the local playback backend (Web or native, via playerActions
      // which branches to the native controller when available).
      playerActions.setPlayingState(false);
      // Build the final precise snapshot and send relinquish_ack.
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

  // Handle handoff_committed: apply the final snapshot and start playback
  // on B (design §11.1 step 7).
  useEffect(() => {
    if (!isConnected) return;
    const original = manager.callbacks.onHandoffCommitted;
    manager.callbacks.onHandoffCommitted = (
      snapshot: PlaybackSnapshot,
      _newGeneration: number,
    ) => {
      // Seek to the handoff progress and start playing.
      if (snapshot.songId) {
        playerActions.setProgress(snapshot.progressSeconds);
        playerActions.setPlayingState(true);
      }
    };
    return () => {
      manager.callbacks.onHandoffCommitted = original;
    };
  }, [isConnected, manager, playerActions]);

  return null;
}
