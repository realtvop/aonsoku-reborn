import { useEffect, useRef } from "react";
import { shouldUseNativePlaybackBackend } from "@/player/playback/backend-factory";
import { subsonic } from "@/service/subsonic";
import {
  useIsRemoteControlActive,
  usePlayerCurrentSong,
  usePlayerDuration,
  usePlayerIsPlaying,
  usePlayerMediaType,
  usePlayerStore,
} from "@/store/player.store";

const SCROBBLE_THRESHOLD_PERCENT = 50;
const SCROBBLE_THRESHOLD_SECONDS = 60 * 4;

export function useScrobble() {
  const currentSong = usePlayerCurrentSong();
  const isNative = !shouldRendererSubmitScrobbles();
  const progress = usePlayerStore((state) =>
    isNative ? 0 : state.playerProgress.progress,
  );
  const currentDuration = usePlayerDuration();
  const isPlaying = usePlayerIsPlaying();
  const { isSong } = usePlayerMediaType();
  const isRemoteControlActive = useIsRemoteControlActive();

  const isScrobbleSentRef = useRef(false);
  const isNowPlayingSentRef = useRef(false);
  const lastSongIdRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (currentSong?.id !== lastSongIdRef.current) {
      lastSongIdRef.current = currentSong?.id;
      isScrobbleSentRef.current = false;
      isNowPlayingSentRef.current = false;
    }
  }, [currentSong?.id]);

  useEffect(() => {
    if (isNative) return;
    if (isRemoteControlActive || !isSong || !isPlaying) return;

    const progressPercentage =
      currentDuration > 0 ? (progress / currentDuration) * 100 : 0;

    if (progressPercentage === 0) {
      if (currentSong?.id && !isNowPlayingSentRef.current) {
        subsonic.scrobble.send(currentSong.id, false);
        isNowPlayingSentRef.current = true;
      }
    } else {
      const scrobbleThreshold = Math.min(
        currentDuration * (SCROBBLE_THRESHOLD_PERCENT / 100),
        SCROBBLE_THRESHOLD_SECONDS,
      );

      if (
        progress >= scrobbleThreshold &&
        !isScrobbleSentRef.current &&
        currentSong?.id
      ) {
        subsonic.scrobble.send(currentSong.id);
        isScrobbleSentRef.current = true;
      }
    }
  }, [
    progress,
    currentDuration,
    isSong,
    isPlaying,
    currentSong?.id,
    isRemoteControlActive,
    isNative,
  ]);
}

export function shouldRendererSubmitScrobbles(): boolean {
  return !shouldUseNativePlaybackBackend();
}
