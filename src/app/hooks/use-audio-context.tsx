import { useCallback, useEffect, useRef } from "react";
import {
  AudioContext,
  type IAudioContext,
  type IGainNode,
  type IMediaElementAudioSourceNode,
} from "standardized-audio-context";
import {
  usePlayerMediaType,
  useReplayGainState,
  useRemoteControlState,
} from "@/store/player.store";
import { logger } from "@/utils/logger";
import { isIOS } from "@/utils/platform";
import { ReplayGainParams } from "@/utils/replayGain";

type IAudioSource = IMediaElementAudioSourceNode<IAudioContext>;

export function useAudioContext(audio: HTMLAudioElement | null) {
  const { isSong } = usePlayerMediaType();
  const { replayGainError, replayGainEnabled } = useReplayGainState();
  const { active: isRemoteControlActive } = useRemoteControlState();

  // On iOS, when not in remote control mode, use native audio without AudioContext to avoid replay gain issues
  const shouldUseNativeAudio = isIOS() && !isRemoteControlActive;

  const audioContextRef = useRef<IAudioContext | null>(null);
  const sourceNodeRef = useRef<IAudioSource | null>(null);
  const gainNodeRef = useRef<IGainNode<IAudioContext> | null>(null);

  const setupAudioContext = useCallback(() => {
    // Skip AudioContext setup on iOS when not in remote control mode
    if (shouldUseNativeAudio) {
      logger.info("Using native audio on iOS (no AudioContext)");
      return;
    }

    if (!audio || !isSong || replayGainError) return;

    if (!audioContextRef.current) {
      audioContextRef.current = new AudioContext();
    }

    const audioContext = audioContextRef.current;

    if (!sourceNodeRef.current) {
      sourceNodeRef.current = audioContext.createMediaElementSource(audio);
    }

    if (!gainNodeRef.current) {
      gainNodeRef.current = audioContext.createGain();
      // First we need to connect the sourceNode to the gainNode
      sourceNodeRef.current.connect(gainNodeRef.current);
      // And then we can connect the gainNode to the destination
      gainNodeRef.current.connect(audioContext.destination);
    }
  }, [audio, isSong, replayGainError, shouldUseNativeAudio]);

  const resumeContext = useCallback(async () => {
    // Skip AudioContext operations on iOS when not in remote control mode
    if (shouldUseNativeAudio) return;

    const audioContext = audioContextRef.current;
    if (!audioContext || !isSong) return;

    logger.info("AudioContext State", { state: audioContext.state });

    if (audioContext.state === "suspended") {
      try {
        await audioContext.resume();
        logger.info("AudioContext resumed successfully");
      } catch (error) {
        logger.error("Failed to resume AudioContext", error);
      }
    }
    if (audioContext.state === "closed") {
      setupAudioContext();
    }
  }, [isSong, setupAudioContext, shouldUseNativeAudio]);

  const setupGain = useCallback(
    (gainValue: number, replayGain?: ReplayGainParams) => {
      // Skip gain setup on iOS when not in remote control mode (no replay gain)
      if (shouldUseNativeAudio) return;

      if (audioContextRef.current && gainNodeRef.current) {
        const currentTime = audioContextRef.current.currentTime;

        logger.info("Replay Gain Status", {
          enabled: replayGainEnabled,
          gainValue,
          ...replayGain,
        });

        gainNodeRef.current.gain.setValueAtTime(gainValue, currentTime);
      }
    },
    [replayGainEnabled, shouldUseNativeAudio]
  );

  const resetRefs = useCallback(() => {
    if (sourceNodeRef.current) {
      sourceNodeRef.current.disconnect();
      sourceNodeRef.current = null;
    }
    if (gainNodeRef.current) {
      gainNodeRef.current.disconnect();
      gainNodeRef.current = null;
    }
    if (audioContextRef.current) {
      audioContextRef.current.close();
      audioContextRef.current = null;
    }
  }, []);

  useEffect(() => {
    if (replayGainError) resetRefs();
  }, [replayGainError, resetRefs]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: clear state after unmount
  useEffect(() => {
    return () => resetRefs();
  }, []);

  useEffect(() => {
    if (audio) setupAudioContext();
  }, [audio, setupAudioContext]);

  // Handle visibility changes to keep AudioContext alive
  useEffect(() => {
    const handleVisibilityChange = async () => {
      const audioContext = audioContextRef.current;
      if (!audioContext || !isSong) return;

      // When page becomes visible again, resume the context if suspended
      if (!document.hidden && audioContext.state === "suspended") {
        try {
          await audioContext.resume();
          logger.info("AudioContext resumed after visibility change");
        } catch (error) {
          logger.error(
            "Failed to resume AudioContext on visibility change",
            error
          );
        }
      }
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [isSong]);

  return {
    audioContextRef,
    sourceNodeRef,
    gainNodeRef,
    setupAudioContext,
    resumeContext,
    setupGain,
    resetRefs,
  };
}
