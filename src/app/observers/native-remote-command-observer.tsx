import { useEffect } from "react";
import { mapNativeRemoteControlCommand } from "@/coordination/native-remote-control-command";
import { useCoordinationStore } from "@/coordination/store";
import { getNativeAudioPluginAvailability } from "@/native/audio/facade";
import {
  handlePlaybackRemoteCommand,
  type PlaybackRemoteCommandEvent,
} from "@/player/playback";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import { logger } from "@/utils/logger";

export function NativeRemoteCommandObserver() {
  const {
    togglePlayPause,
    playNextSong,
    playPrevSong,
    setProgress,
    starCurrentSong,
    toggleShuffle,
  } = usePlayerActions();

  useEffect(() => {
    const availability = getNativeAudioPluginAvailability();
    if (!availability.available) return;

    let disposed = false;
    const handlePromise = availability.plugin
      .addListener("remoteCommand", (event) => {
        if (disposed) return;

        const command: PlaybackRemoteCommandEvent = event;

        handlePlaybackRemoteCommand(command, {
          isPlaying: () => usePlayerStore.getState().playerState.isPlaying,
          togglePlayPause,
          playNextSong,
          playPrevSong,
          seek: (position) => setProgress(position, true),
          starCurrentSong,
          toggleShuffle,
        });
      })
      .catch((error) => {
        logger.info("[NativeRemoteCommandObserver] listener failed", error);
        return null;
      });

    return () => {
      disposed = true;
      handlePromise
        .then((handle) => handle?.remove())
        .catch((error) => {
          logger.info("[NativeRemoteCommandObserver] cleanup failed", error);
        });
    };
  }, [
    playNextSong,
    playPrevSong,
    setProgress,
    starCurrentSong,
    togglePlayPause,
    toggleShuffle,
  ]);

  useEffect(() => {
    const availability = getNativeAudioPluginAvailability();
    if (!availability.available) return;

    let disposed = false;
    const handlePromise = availability.plugin
      .addListener("remoteControlCommand", (event) => {
        if (disposed || event.handledNatively) return;

        const command = mapNativeRemoteControlCommand(event.command);
        if (!command) {
          logger.info(
            "[NativeRemoteCommandObserver] ignored malformed remoteControlCommand",
            event.command,
          );
          return;
        }

        const coordinationState = useCoordinationStore.getState();
        const targetDeviceId =
          event.targetDeviceId ?? coordinationState.controlledDeviceId;
        if (!targetDeviceId) {
          logger.info(
            "[NativeRemoteCommandObserver] rejected remoteControlCommand without target",
            command,
          );
          return;
        }

        const snapshotData =
          coordinationState.deviceSnapshots[targetDeviceId] ?? null;
        const expectedGeneration =
          typeof event.expectedGeneration === "number"
            ? event.expectedGeneration
            : snapshotData?.generation;
        if (typeof expectedGeneration !== "number") {
          logger.info(
            "[NativeRemoteCommandObserver] rejected remoteControlCommand without generation",
            command,
          );
          return;
        }

        coordinationState.manager.sendCommand(
          targetDeviceId,
          expectedGeneration,
          command,
        );
      })
      .catch((error) => {
        logger.info(
          "[NativeRemoteCommandObserver] remoteControlCommand listener failed",
          error,
        );
        return null;
      });

    return () => {
      disposed = true;
      handlePromise
        .then((handle) => handle?.remove())
        .catch((error) => {
          logger.info(
            "[NativeRemoteCommandObserver] remoteControlCommand cleanup failed",
            error,
          );
        });
    };
  }, []);

  return null;
}
