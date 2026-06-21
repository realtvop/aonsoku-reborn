import { RefObject, useCallback, useState } from "react";
import { seekPlaybackTarget } from "@/player/playback/backend-registry";
import { getNativeQueueController } from "@/player/queue-controller";
import {
  useIsRemoteControlActive,
  usePlayerActions,
} from "@/store/player.store";
import { logger } from "@/utils/logger";

interface UseAudioSeekingOptions {
  audioRef: RefObject<HTMLAudioElement> | { current: HTMLAudioElement | null };
}

export function useAudioSeeking({ audioRef }: UseAudioSeekingOptions) {
  const { setProgress, setIsScrubbing, setScrubbingProgress } =
    usePlayerActions();
  const isRemoteControlActive = useIsRemoteControlActive();
  const [localProgress, setLocalProgress] = useState(0);
  const [isLocalSeeking, setIsLocalSeeking] = useState(false);

  const updateAudioCurrentTime = useCallback(
    (value: number) => {
      if (isRemoteControlActive) return;
      const audio = audioRef.current;
      if (audio) {
        logger.debug("Seeking to:", value);
        seekPlaybackTarget(audio, value);
      }
    },
    [audioRef, isRemoteControlActive],
  );

  const handleSeeking = useCallback(
    (amount: number) => {
      setIsLocalSeeking(true);
      setLocalProgress(amount);
      setIsScrubbing(true);
      setScrubbingProgress(amount);
    },
    [setIsScrubbing, setScrubbingProgress],
  );

  const handleSeeked = useCallback(
    (amount: number) => {
      logger.debug("Seek completed:", amount);
      setProgress(amount, true);
      setLocalProgress(amount);
      setIsLocalSeeking(false);
      setIsScrubbing(false);
      if (!isRemoteControlActive && !getNativeQueueController()) {
        updateAudioCurrentTime(amount);
      }
    },
    [
      isRemoteControlActive,
      setIsScrubbing,
      setProgress,
      updateAudioCurrentTime,
    ],
  );

  return {
    localProgress,
    setLocalProgress,
    isLocalSeeking,
    setIsLocalSeeking,
    updateAudioCurrentTime,
    handleSeeking,
    handleSeeked,
  };
}
