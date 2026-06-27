import { useEffect } from "react";
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

  return null;
}
