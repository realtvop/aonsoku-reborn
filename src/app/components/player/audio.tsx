import {
  ComponentPropsWithoutRef,
  RefObject,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { useAudioContext } from "@/app/hooks/use-audio-context";
import {
  usePlayerActions,
  usePlayerIsPlaying,
  usePlayerMediaType,
  usePlayerVolume,
  useReplayGainActions,
  useReplayGainState,
  useRemoteControlState,
} from "@/store/player.store";
import { logger } from "@/utils/logger";
import { calculateReplayGain, ReplayGainParams } from "@/utils/replayGain";

type AudioPlayerProps = ComponentPropsWithoutRef<"audio"> & {
  audioRef: RefObject<HTMLAudioElement>;
  replayGain?: ReplayGainParams;
};

export function AudioPlayer({
  audioRef,
  replayGain,
  src,
  ...props
}: AudioPlayerProps) {
  const { t } = useTranslation();
  const [previousGain, setPreviousGain] = useState(1);
  const [audioSrc, setAudioSrc] = useState<string | undefined>(undefined);
  const { replayGainEnabled, replayGainError } = useReplayGainState();
  const { isSong, isRadio, isPodcast } = usePlayerMediaType();
  const { setPlayingState } = usePlayerActions();
  const { setReplayGainEnabled, setReplayGainError } = useReplayGainActions();
  const { volume } = usePlayerVolume();
  const isPlaying = usePlayerIsPlaying();
  const { active: isRemoteControlActive } = useRemoteControlState();

  // Use native audio by default, only use AudioContext when acting as a remote controller
  const shouldUseNativeAudio = !isRemoteControlActive;

  // Update audio source only when it actually changes and is valid
  useEffect(() => {
    if (src && src !== audioSrc) {
      logger.info("Audio source changed", {
        src,
        useNativeAudio: shouldUseNativeAudio,
        isRemoteControlActive,
      });
      setAudioSrc(src);
    }
  }, [src, audioSrc, shouldUseNativeAudio, isRemoteControlActive]);

  const gainValue = useMemo(() => {
    const audioVolume = volume / 100;

    // In native audio mode, don't use replay gain - just use volume
    if (shouldUseNativeAudio) {
      return audioVolume * 1;
    }

    if (!replayGain || !replayGainEnabled) {
      return audioVolume * 1;
    }
    const gain = calculateReplayGain(replayGain);

    return audioVolume * gain;
  }, [replayGain, replayGainEnabled, volume, shouldUseNativeAudio]);

  const { resumeContext, setupGain } = useAudioContext(audioRef.current);

  // Ignore AudioContext gain in native mode, when not a song, or when there's a replay gain error
  const ignoreGain = shouldUseNativeAudio || !isSong || replayGainError;

  // In native mode, set audio volume directly instead of using gain node
  useEffect(() => {
    if (!audioRef.current) return;

    if (shouldUseNativeAudio) {
      // Use native volume control
      audioRef.current.volume = volume / 100;
      logger.info("Native audio volume set:", volume / 100);
      return;
    }

    // Use AudioContext gain when in remote control mode
    if (ignoreGain) return;
    if (gainValue === previousGain) return;

    setupGain(gainValue, replayGain);
    setPreviousGain(gainValue);
  }, [
    audioRef,
    ignoreGain,
    gainValue,
    previousGain,
    replayGain,
    setupGain,
    shouldUseNativeAudio,
    volume,
  ]);

  const handleSongError = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const errorDetails = {
      src: audio.src,
      networkState: audio.networkState,
      readyState: audio.readyState,
      error: audio.error
        ? {
            code: audio.error.code,
            message: audio.error.message,
          }
        : null,
    };

    logger.error("Audio load error", errorDetails);

    // Only show toast and reload if this is a replay gain related error
    // Otherwise just log the error to avoid reload loops
    if (
      audio.error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED &&
      replayGainEnabled
    ) {
      toast.error(t("warnings.songError"));
      setReplayGainEnabled(false);
      setReplayGainError(true);
      window.location.reload();
    } else if (audio.error?.code !== MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED) {
      // Only show toast for non-source errors
      toast.error(t("warnings.songError"));
    }
  }, [
    audioRef,
    replayGainEnabled,
    setReplayGainEnabled,
    setReplayGainError,
    t,
  ]);

  const handleRadioError = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;

    toast.error(t("radios.error"));
    setPlayingState(false);
  }, [audioRef, setPlayingState, t]);

  useEffect(() => {
    async function handleSong() {
      const audio = audioRef.current;
      if (!audio) return;

      try {
        if (isPlaying) {
          // Only resume AudioContext if in remote control mode (not using native audio)
          if (isSong && !shouldUseNativeAudio) {
            await resumeContext();
          }
          // Try to play, and if it fails due to autoplay policy, log it
          const playPromise = audio.play();
          if (playPromise !== undefined) {
            playPromise.catch((error) => {
              logger.error("Play was prevented:", error);
              // If play was prevented, try to resume on next user interaction
            });
          }
        } else {
          audio.pause();
          // Ensure audio is fully stopped and won't continue playing
          // This is especially important on mobile devices
          if (audio.currentTime > 0) {
            // Force stop by setting currentTime to itself
            // This clears the audio buffer on some browsers
            const currentTime = audio.currentTime;
            audio.currentTime = currentTime;
          }
        }
      } catch (error) {
        logger.error("Audio playback failed", error);
        handleSongError();
      }
    }
    if (isSong || isPodcast) handleSong();
  }, [
    audioRef,
    handleSongError,
    isPlaying,
    isSong,
    isPodcast,
    resumeContext,
    shouldUseNativeAudio,
  ]);

  useEffect(() => {
    async function handleRadio() {
      const audio = audioRef.current;
      if (!audio) return;

      if (isPlaying) {
        audio.load();
        await audio.play();
      } else {
        audio.pause();
      }
    }
    if (isRadio) handleRadio();
  }, [audioRef, isPlaying, isRadio]);

  const handleError = useMemo(() => {
    if (isSong) return handleSongError;
    if (isRadio) return handleRadioError;

    return undefined;
  }, [handleRadioError, handleSongError, isRadio, isSong]);

  const crossOrigin = useMemo(() => {
    // In native audio mode, don't use crossOrigin as we're not using AudioContext
    if (shouldUseNativeAudio) return undefined;

    if (!isSong || replayGainError) return undefined;

    return "anonymous";
  }, [isSong, replayGainError, shouldUseNativeAudio]);

  return (
    <audio
      ref={audioRef}
      {...props}
      src={audioSrc}
      crossOrigin={crossOrigin}
      onError={handleError}
      playsInline
      preload="auto"
    />
  );
}
