import { useEffect } from "react";
import { useCoordinationStore } from "@/coordination/store";
import type { RemoteCommand } from "@/coordination/types";
import { getNativeAudioPluginAvailability } from "@/native/audio/facade";
import {
  handlePlaybackRemoteCommand,
  type PlaybackRemoteCommandEvent,
} from "@/player/playback";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import { LanControlMessageType } from "@/types/lanControl";
import { logger } from "@/utils/logger";

const LEGACY_REMOTE_COMMAND_SUPPRESS_MS = 500;

function forwardNativeRemoteControlCommand(command: RemoteCommand) {
  const { controlledDeviceId, deviceSnapshots, manager } =
    useCoordinationStore.getState();
  if (!controlledDeviceId) return false;

  const snapshot = deviceSnapshots[controlledDeviceId];
  if (!snapshot) return false;

  manager.sendCommand(controlledDeviceId, snapshot.generation, command);
  return true;
}

function forwardRemoteCommand(event: PlaybackRemoteCommandEvent) {
  const remoteControl = usePlayerStore.getState().remoteControl;
  if (!remoteControl.active || !remoteControl.sendCommand) return false;

  switch (event.command) {
    case "play":
      remoteControl.sendCommand(LanControlMessageType.PLAY);
      return true;
    case "pause":
      remoteControl.sendCommand(LanControlMessageType.PAUSE);
      return true;
    case "togglePlayPause":
      remoteControl.sendCommand(LanControlMessageType.PLAY_PAUSE);
      return true;
    case "next":
      remoteControl.sendCommand(LanControlMessageType.NEXT);
      return true;
    case "previous":
      remoteControl.sendCommand(LanControlMessageType.PREVIOUS);
      return true;
    case "seek":
      remoteControl.sendCommand(LanControlMessageType.SEEK, {
        seconds: Math.max(0, event.position ?? 0),
      });
      return true;
    case "like":
      remoteControl.sendCommand(LanControlMessageType.TOGGLE_LIKE);
      return true;
    case "shuffle":
      remoteControl.sendCommand(LanControlMessageType.TOGGLE_SHUFFLE);
      return true;
  }
}

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
    let lastNativeRemoteControlCommandAt = 0;
    const remoteControlCommandPromise = availability.plugin
      .addListener("remoteControlCommand", (event) => {
        if (disposed) return;

        const command = event.command as RemoteCommand;
        if (forwardNativeRemoteControlCommand(command)) {
          lastNativeRemoteControlCommandAt = Date.now();
        }
      })
      .catch((error) => {
        logger.info(
          "[NativeRemoteCommandObserver] remote control listener failed",
          error,
        );
        return null;
      });

    const handlePromise = availability.plugin
      .addListener("remoteCommand", (event) => {
        if (disposed) return;

        if (
          Date.now() - lastNativeRemoteControlCommandAt <
          LEGACY_REMOTE_COMMAND_SUPPRESS_MS
        ) {
          return;
        }

        const command: PlaybackRemoteCommandEvent = event;

        if (forwardRemoteCommand(command)) return;

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
      remoteControlCommandPromise
        .then((handle) => handle?.remove())
        .catch((error) => {
          logger.info(
            "[NativeRemoteCommandObserver] remote control cleanup failed",
            error,
          );
        });
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

  return null;
}
