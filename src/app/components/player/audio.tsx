import {
  ComponentPropsWithoutRef,
  RefObject,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useAudioContext } from "@/app/hooks/use-audio-context";
import { getNetworkStatus } from "@/app/hooks/use-network-status";
import {
  createPlaybackBackend,
  createUrlPlaybackSource,
  getPlaybackEndedDecision,
  getPlaybackErrorKind,
  type PlaybackBackend,
  type PlaybackBackendKind,
  type PlaybackErrorEvent,
  type PlaybackMetadata,
  PlaybackSession,
  type PlaybackSource,
  playbackRepeatModeFromLoopState,
  registerPlaybackBackend,
  shouldRetryPlaybackError,
  shouldUseNativePlaybackBackend,
} from "@/player/playback";
import { getQueueController } from "@/player/queue-controller";
import { type AudioSourceDescriptor, getAudioSourceUrl } from "@/service/cache";
import { useCacheStore } from "@/store/cache.store";
import {
  useIsRemoteControlActive,
  usePlayerActions,
  usePlayerIsPlaying,
  usePlayerLoop,
  usePlayerMediaType,
  usePlayerShuffle,
  usePlayerStore,
  usePlayerVolume,
  useReplayGainActions,
  useReplayGainState,
} from "@/store/player.store";
import { getPlaybackCapabilities } from "@/utils/capabilities";
import { logger } from "@/utils/logger";
import { calculateReplayGain, ReplayGainParams } from "@/utils/replayGain";
import { manageMediaSession } from "@/utils/setMediaSession";
import { perceptualToGain } from "@/utils/volume";

type AudioPlayerProps = ComponentPropsWithoutRef<"audio"> & {
  audioRef: RefObject<HTMLAudioElement>;
  audioSource?: AudioSourceDescriptor | null;
  replayGain?: ReplayGainParams;
  metadata?: PlaybackMetadata | null;
  onPlaybackError?: () => void;
  onReplayGainError?: () => void;
  songId?: string;
};

export function AudioPlayer({
  audioRef,
  replayGain,
  metadata,
  audioSource,
  onPlaybackError,
  onReplayGainError,
  src,
  songId,
  onLoadedMetadata,
  onTimeUpdate,
  onProgress,
  onCanPlay,
  onPlay,
  onPause,
  onEnded,
  ...props
}: AudioPlayerProps) {
  const previousGainRef = useRef(1);
  const [audioSrc, setAudioSrc] = useState<string | undefined>(undefined);
  const { replayGainEnabled, replayGainError } = useReplayGainState();
  const { isSong, isRadio } = usePlayerMediaType();
  const { setReplayGainEnabled, setReplayGainError } = useReplayGainActions();
  const { volume } = usePlayerVolume();
  const isPlaying = usePlayerIsPlaying();
  const loopState = usePlayerLoop();
  const isShuffleActive = usePlayerShuffle();
  const seekToStart = usePlayerStore((s) => s.playerState.seekToStart);
  const isRemoteControlActive = useIsRemoteControlActive();
  const playbackCapabilities = useMemo(() => getPlaybackCapabilities(), []);
  const shouldUseDetachedPlayback = useMemo(
    () => shouldUseNativePlaybackBackend(),
    [],
  );

  const shouldUseWebAudioReplayGain =
    playbackCapabilities.supportsWebAudioReplayGain &&
    !shouldUseDetachedPlayback &&
    isSong &&
    replayGainEnabled &&
    !replayGainError &&
    !isRemoteControlActive;
  const shouldUseNativeAudio = !shouldUseWebAudioReplayGain;

  const backendRef = useRef<{
    audio: HTMLAudioElement;
    backend: PlaybackBackend;
    kind: PlaybackBackendKind;
    unregisterBackend: () => void;
  } | null>(null);
  const sessionRef = useRef(new PlaybackSession<HTMLAudioElement>());

  const cancelRetry = useCallback(() => {
    sessionRef.current.cancelRetry();
  }, []);

  const {
    setBufferedProgress: setStoreBufferedProgress,
    setCurrentDuration: setStoreCurrentDuration,
    setIsBuffering: setStoreIsBuffering,
    setProgress: setStoreProgress,
  } = usePlayerActions();

  const getPlaybackBackendEntry = useCallback(
    (audioOverride?: HTMLAudioElement | null) => {
      const audio = audioOverride ?? audioRef.current;
      if (!audio) return null;

      if (!backendRef.current || backendRef.current.audio !== audio) {
        backendRef.current?.unregisterBackend();
        backendRef.current?.backend.dispose();
        const selection = createPlaybackBackend(audio);
        if (selection.fallbackReason) {
          logger.info(
            `[PlaybackBackend] native fallback=${selection.fallbackReason}`,
          );
        }
        backendRef.current = {
          audio,
          backend: selection.backend,
          kind: selection.kind,
          unregisterBackend: registerPlaybackBackend(audio, selection.backend),
        };
      }

      return backendRef.current;
    },
    [audioRef],
  );

  const getPlaybackBackend = useCallback(
    (audioOverride?: HTMLAudioElement | null) =>
      getPlaybackBackendEntry(audioOverride)?.backend ?? null,
    [getPlaybackBackendEntry],
  );

  const createPlaybackSource = useCallback(
    (url: string): PlaybackSource => {
      if (audioSource && getAudioSourceUrl(audioSource) === url) {
        switch (audioSource.kind) {
          case "stream":
            return {
              kind: "stream",
              url: audioSource.url,
              songId: audioSource.songId,
            };
          case "blob":
            return {
              kind: "blob",
              url: audioSource.url,
              songId: audioSource.songId,
            };
          case "native-file":
            return {
              kind: "native-file",
              uri: audioSource.uri,
              songId: audioSource.songId,
            };
          case "radio":
            return {
              kind: "radio",
              url: audioSource.url,
              radioId: audioSource.radioId,
            };
        }
      }

      return createUrlPlaybackSource(url, {
        kind: isRadio ? "radio" : undefined,
        songId: isRadio ? undefined : songId,
      });
    },
    [audioSource, isRadio, songId],
  );

  const loadAudio = useCallback(
    (audio: HTMLAudioElement) => {
      const sourceUrl = audio.currentSrc || audio.src || audioSrc;
      if (!sourceUrl) {
        audio.load();
        return;
      }

      const backend = getPlaybackBackend(audio);
      if (backend) {
        backend.load(createPlaybackSource(sourceUrl), metadata ?? undefined);
      } else {
        audio.load();
      }
    },
    [audioSrc, createPlaybackSource, getPlaybackBackend, metadata],
  );

  const seekAudio = useCallback(
    (audio: HTMLAudioElement, seconds: number) => {
      const backend = getPlaybackBackend(audio);
      if (backend) {
        backend.seek(seconds);
      } else {
        audio.currentTime = seconds;
      }
    },
    [getPlaybackBackend],
  );

  useEffect(() => {
    if (src !== audioSrc) {
      const currentProgress = usePlayerStore.getState().playerProgress.progress;
      const sourceChange = sessionRef.current.beginSourceChange(songId, {
        resumePosition: currentProgress > 0 ? currentProgress : undefined,
      });
      logger.info(
        `[AudioSrcChange] newSrc=${src?.slice(-60)} | oldSrc=${audioSrc?.slice(-60)} | cancelledRetry=${sourceChange.cancelledRetry} | retryCount=${sourceChange.retryCount} | resumePosition=${currentProgress} | srcChangingRef=true`,
      );

      const state = usePlayerStore.getState();
      if (state.playerState.isPlaying && !state.remoteControl.active) {
        manageMediaSession.ensurePlaybackStatePlaying();
      }

      const isNativeTransition =
        getQueueController().consumeNativeDrivenTransition();
      if (isNativeTransition) {
        logger.info(
          `[AudioSrcChange:SKIP] reason=nativeDrivenTransition | songId=${songId} | src=${src?.slice(-60)}`,
        );
        sessionRef.current.markLoopRestartSyncHandled();
        setAudioSrc(src || undefined);
        return;
      }

      setAudioSrc(src || undefined);
      const audio = audioRef.current;
      if (audio && src) {
        const shouldAutoplay =
          state.playerState.isPlaying && !state.remoteControl.active;
        getPlaybackBackend(audio)?.load(
          createPlaybackSource(src),
          metadata ?? undefined,
          shouldAutoplay ? { autoplay: true } : undefined,
        );
        if (shouldAutoplay) {
          sessionRef.current.markLoopRestartSyncHandled();
        }
      }
    }
  }, [
    audioRef,
    audioSrc,
    createPlaybackSource,
    getPlaybackBackend,
    metadata,
    src,
    songId,
  ]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !metadata) return;
    if (playbackCapabilities.supportsNativePlayback) return;

    getPlaybackBackend(audio)?.updateMetadata(metadata);
  }, [audioRef, getPlaybackBackend, metadata, playbackCapabilities]);

  const audioVolume = useMemo(
    () =>
      playbackCapabilities.requiresSystemVolume ? 1 : perceptualToGain(volume),
    [playbackCapabilities.requiresSystemVolume, volume],
  );

  const gainValue = useMemo(() => {
    if (!shouldUseWebAudioReplayGain || !replayGain) {
      return audioVolume;
    }

    const gain = calculateReplayGain(replayGain);

    return audioVolume * gain;
  }, [audioVolume, replayGain, shouldUseWebAudioReplayGain]);

  const handleReplayGainSetupError = useCallback(() => {
    onReplayGainError?.();
    setReplayGainEnabled(false);
    setReplayGainError(true);
  }, [onReplayGainError, setReplayGainEnabled, setReplayGainError]);

  const { resumeContext, setupGain } = useAudioContext(audioRef.current, {
    enabled: shouldUseWebAudioReplayGain,
    onSetupError: handleReplayGainSetupError,
  });

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    if (shouldUseNativeAudio) {
      getPlaybackBackend(audio)?.setVolume(audioVolume);
      previousGainRef.current = Number.NaN;
      logger.info("Native audio volume set:", audioVolume);
      return;
    }

    getPlaybackBackend(audio)?.setVolume(1);
    if (gainValue === previousGainRef.current) return;

    setupGain(gainValue, replayGain);
    previousGainRef.current = gainValue;
  }, [
    audioRef,
    audioVolume,
    getPlaybackBackend,
    gainValue,
    replayGain,
    setupGain,
    shouldUseNativeAudio,
  ]);

  const safePlay = useCallback(
    (audio: HTMLAudioElement, contextLabel: string) => {
      const state = usePlayerStore.getState();
      logger.info(
        `[safePlay] source=${contextLabel} | readyState=${audio.readyState} | currentTime=${audio.currentTime.toFixed(2)} | paused=${audio.paused} | ended=${audio.ended} | src=${audio.src?.slice(-60)}`,
      );
      if (state.playerState.isPlaying && !state.remoteControl.active) {
        manageMediaSession.ensurePlaybackStatePlaying();
      }
      const playPromise = getPlaybackBackend(audio)?.play() ?? audio.play();
      const promise = playPromise ?? undefined;
      sessionRef.current.setPlayPromise(promise ?? null);
      if (promise !== undefined) {
        promise
          .then(() => {
            sessionRef.current.clearPlayPromise(promise);
            logger.info(
              `[safePlay:OK] source=${contextLabel} | currentTime=${audio.currentTime.toFixed(2)}`,
            );
          })
          .catch((error) => {
            sessionRef.current.clearPlayPromise(promise);
            if (error.name === "AbortError") {
              logger.info(
                `[safePlay:ABORTED] source=${contextLabel} | expected=${contextLabel === "LoopRestartSync" || contextLabel === "Song" ? "check" : "unknown"}`,
              );
            } else {
              logger.error(
                `[safePlay:ERROR] source=${contextLabel} | error=${error.name} ${error.message}`,
              );
            }
          });
      }
    },
    [getPlaybackBackend],
  );

  const pauseAudio = useCallback(
    (audio: HTMLAudioElement) => {
      logger.info(
        `[pauseAudio] currentTime=${audio.currentTime.toFixed(2)} | duration=${audio.duration?.toFixed(2)} | src=${audio.src?.slice(-60)}`,
      );
      const pending = sessionRef.current.consumePlayPromise();
      if (pending) {
        pending.catch(() => {});
      }
      sessionRef.current.beginEffectPause();
      const backend = getPlaybackBackend(audio);
      if (backend) {
        backend.pause();
      } else {
        audio.pause();
      }
      sessionRef.current.clearEffectPauseIfPaused(audio.paused);
    },
    [getPlaybackBackend],
  );

  const scheduleRetry = useCallback(
    (audio: HTMLAudioElement) => {
      const result = sessionRef.current.scheduleRetry(
        {
          audio,
          getCurrentAudio: () => audioRef.current,
          getStoreProgress: () =>
            usePlayerStore.getState().playerProgress.progress,
          setStoreProgress,
          isOnline: () => getNetworkStatus().isOnline,
          shouldResume: () => usePlayerStore.getState().playerState.isPlaying,
          loadAudio,
          seekAudio,
          playAudio: safePlay,
          onPlaybackError,
        },
        (event) => {
          if (event.type === "skipped") {
            logger.info(
              `Retry skipped: ${event.reason ?? "source changed or playback stopped"}`,
            );
          }
        },
      );

      if (result.type === "offline") {
        logger.info("[scheduleRetry] Offline, skipping retry");
      } else if (result.type === "rangeFallback") {
        logger.info(
          "[scheduleRetry] All retries failed — retrying from position 0",
          {
            fallbackPosition: result.fallbackPosition,
          },
        );
      } else if (result.type === "scheduled") {
        logger.info(
          `[scheduleRetry] attempt=${result.attempt}/5 | delay=${result.delay}ms | fromPosition=${result.resumePosition.toFixed(2)}`,
        );
      }
    },
    [
      audioRef,
      loadAudio,
      onPlaybackError,
      safePlay,
      seekAudio,
      setStoreProgress,
    ],
  );

  const handleAudioError = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const errorCode = audio.error?.code;
    logger.info(
      `[onError] code=${errorCode} | message=${audio.error?.message} | mediaType=${isSong ? "song" : isRadio ? "radio" : "unknown"} | retryAttempt=${sessionRef.current.retryCount + 1}/5 | src=${audio.src?.slice(-60)}`,
    );

    switch (errorCode) {
      case MediaError.MEDIA_ERR_ABORTED:
        logger.info("[onError:ABORTED] Skipping retry");
        return;

      case MediaError.MEDIA_ERR_NETWORK:
        scheduleRetry(audio);
        return;

      case MediaError.MEDIA_ERR_DECODE:
        if (isRadio) {
          scheduleRetry(audio);
        } else {
          logger.info("[onError:DECODE] Skipping to next song");
          onPlaybackError?.();
          cancelRetry();
        }
        return;

      case MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED:
        if (shouldUseWebAudioReplayGain) {
          handleReplayGainSetupError();
        }
        return;

      default:
        scheduleRetry(audio);
    }
  }, [
    audioRef,
    cancelRetry,
    handleReplayGainSetupError,
    isRadio,
    isSong,
    onPlaybackError,
    scheduleRetry,
    shouldUseWebAudioReplayGain,
  ]);

  const handleRadioError = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;

    scheduleRetry(audio);
  }, [audioRef, scheduleRetry]);

  const handleError = useMemo(() => {
    if (isSong) return handleAudioError;
    if (isRadio) return handleRadioError;

    return undefined;
  }, [handleAudioError, handleRadioError, isRadio, isSong]);

  const handleNativeBackendError = useCallback(
    (event: PlaybackErrorEvent) => {
      const audio = audioRef.current;
      if (!audio) return;

      logger.info(
        `[NativeBackend:onError] kind=${getPlaybackErrorKind(event)} | code=${event.code ?? "unknown"} | nativeCode=${event.nativeCode ?? "none"} | message=${event.message ?? ""} | mediaType=${isSong ? "song" : isRadio ? "radio" : "unknown"} | retryAttempt=${sessionRef.current.retryCount + 1}/5`,
      );

      if (shouldRetryPlaybackError(event, { isRadio })) {
        scheduleRetry(audio);
        return;
      }

      if (getPlaybackErrorKind(event) === "aborted") {
        logger.info("[NativeBackend:onError:ABORTED] Skipping retry");
        return;
      }

      if (isSong || isRadio) {
        onPlaybackError?.();
        cancelRetry();
      }
    },
    [audioRef, cancelRetry, isRadio, isSong, onPlaybackError, scheduleRetry],
  );

  const handleAudioErrorRef = useRef(handleAudioError);
  handleAudioErrorRef.current = handleAudioError;

  const applyPendingResume = useCallback(
    (audio: HTMLAudioElement) => {
      const clampedPos = sessionRef.current.applyPendingResume(audio, {
        seekAudio,
        setStoreProgress,
      });
      if (clampedPos === null) return;

      logger.info("Applying pending resume position:", clampedPos);
    },
    [seekAudio, setStoreProgress],
  );

  useEffect(() => {
    return () => {
      sessionRef.current.dispose();
      backendRef.current?.unregisterBackend();
      backendRef.current?.backend.dispose();
      backendRef.current = null;
    };
  }, []);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const entry = getPlaybackBackendEntry(audio);
    if (!entry) return;

    const repeatMode = playbackRepeatModeFromLoopState(loopState);
    Promise.resolve(entry.backend.setRepeatMode(repeatMode)).catch((error) => {
      logger.info("[PlaybackBackend] repeat sync failed", error);
    });
    if (entry.kind === "web") {
      Promise.resolve(entry.backend.setShuffle(isShuffleActive)).catch(
        (error) => {
          logger.info("[PlaybackBackend] shuffle sync failed", error);
        },
      );
    }
  }, [audioRef, getPlaybackBackendEntry, isShuffleActive, loopState]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const backendEntry = getPlaybackBackendEntry(audio);
    if (!backendEntry || backendEntry.kind === "web") return;

    const unsubscribeProgress = backendEntry.backend.subscribe(
      "progress",
      (event) => {
        if (!sessionRef.current.shouldSuppressProgressUpdate()) {
          usePlayerStore.setState((state) => {
            state.playerProgress.progress = event.currentTime;
          });
        }
        setStoreBufferedProgress(event.bufferedTime);
      },
    );
    const unsubscribeDuration = backendEntry.backend.subscribe(
      "duration",
      (event) => {
        const duration = Math.round(event.duration);
        if (duration > 0) {
          setStoreCurrentDuration(duration);
          // For native backend, we use duration event as a signal that metadata is ready
          // similar to loadedmetadata/canplay for DOM audio.
          if (sessionRef.current.pendingResumePosition !== null) {
            applyPendingResume(audio);
          }
          sessionRef.current.finishCanPlay();
        }
      },
    );
    const unsubscribeBuffering = backendEntry.backend.subscribe(
      "buffering",
      (event) => {
        setStoreIsBuffering(event.isBuffering);
      },
    );
    const unsubscribePlay = backendEntry.backend.subscribe("play", () => {
      sessionRef.current.handlePlayEvent();
    });
    const unsubscribePause = backendEntry.backend.subscribe("pause", () => {
      // native-controller already handles playbackStateChanged → store update.
      // Sending a pause command back here would race with queue engine transitions.
    });
    const unsubscribeEnded = backendEntry.backend.subscribe("ended", () => {
      const state = usePlayerStore.getState();
      const loopState = state.playerState.loopState;
      const songlist = state.songlist;

      const decision = getPlaybackEndedDecision({
        loopState,
        songlist,
      });

      if (state.songlist.currentSong) {
        manageMediaSession.setMediaSession(state.songlist.currentSong);
      }

      if (decision.type === "restart-current") {
        logger.info(
          `[onEnded:NATIVE → LoopRestartSync] songId=${songId} | currentTime→0 | calling safePlay`,
        );
        sessionRef.current.markLoopRestarting();
        sessionRef.current.markLoopRestartSyncHandled();
        seekAudio(audio, 0);
        setStoreProgress(0, true);
        safePlay(audio, "LoopRestartSync");
      }

      (onEnded as (() => void) | undefined)?.();
    });
    const unsubscribeError = backendEntry.backend.subscribe(
      "error",
      handleNativeBackendError,
    );
    return () => {
      unsubscribeProgress();
      unsubscribeDuration();
      unsubscribeBuffering();
      unsubscribePlay();
      unsubscribePause();
      unsubscribeEnded();
      unsubscribeError();
    };
  }, [
    applyPendingResume,
    audioRef,
    getPlaybackBackendEntry,
    handleNativeBackendError,
    onEnded,
    safePlay,
    seekAudio,
    setStoreBufferedProgress,
    setStoreCurrentDuration,
    setStoreIsBuffering,
    setStoreProgress,
    songId,
  ]);

  useEffect(() => {
    if (!isPlaying) {
      cancelRetry();
    }
  }, [cancelRetry, isPlaying]);

  useEffect(() => {
    const unsubscribe = useCacheStore.subscribe(
      (s) => s.status.isOnline,
      (isOnline, prevIsOnline) => {
        if (!prevIsOnline && isOnline) {
          const audio = audioRef.current;
          if (!audio || sessionRef.current.retryCount === 0) return;

          logger.info("Server reachable again, retrying audio playback");
          sessionRef.current.resetRetries();
          loadAudio(audio);
          safePlay(audio, "Reconnect");
        }
      },
    );
    return unsubscribe;
  }, [audioRef, loadAudio, safePlay]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio || !isSong) return;
    if (shouldUseDetachedPlayback) return;

    if (!audioSrc && !songId) {
      pauseAudio(audio);
    }
  }, [
    audioRef,
    audioSrc,
    songId,
    isSong,
    pauseAudio,
    shouldUseDetachedPlayback,
  ]);

  useEffect(() => {
    async function handleSongPlayback() {
      const audio = audioRef.current;
      if (!audio || !isSong) return;

      if (!audioSrc) return;

      logger.info(
        `[PlayEffect] isPlaying=${isPlaying} | seekToStart=${seekToStart} | audio.paused=${audio.paused} | audio.ended=${audio.ended} | audio.currentTime=${audio.currentTime.toFixed(2)} | audio.readyState=${audio.readyState} | syncPlayHandled=${sessionRef.current.syncPlayHandled} | srcChanging=${sessionRef.current.sourceChanging} | src=${audio.src?.slice(-60)}`,
      );

      try {
        if (isPlaying) {
          if (!sessionRef.current.hasLoadedSource(songId)) {
            logger.info(
              `[PlayEffect:SKIP] reason=songIdMismatch | songId=${songId} | loadedSongId=${sessionRef.current.loadedSourceId}`,
            );
            return;
          }
          if (seekToStart) {
            logger.info(
              `[PlayEffect:seekToStart] songId=${songId} | setting currentTime=0`,
            );
            sessionRef.current.markLoopRestarting();
            seekAudio(audio, 0);
            setStoreProgress(0, true);
            usePlayerStore.setState((state) => {
              state.playerState.seekToStart = false;
            });
          } else if (
            audio.ended &&
            sessionRef.current.hasLoadedSource(songId)
          ) {
            logger.info(
              `[PlayEffect:endedRestart] songId=${songId} | setting currentTime=0`,
            );
            sessionRef.current.markLoopRestarting();
            seekAudio(audio, 0);
          }
          if (shouldUseWebAudioReplayGain) {
            await resumeContext();
          }

          if (sessionRef.current.consumeSyncPlayHandled()) {
            logger.info(
              "[PlayEffect:SKIP] reason=syncPlayHandledAlready | clearing flag",
            );
            return;
          }

          if (isDetachedPlaybackBackendKind(backendRef.current?.kind)) {
            logger.info(
              "[PlayEffect:SKIP] reason=nativeBackend | native player handles its own playback",
            );
            return;
          }

          logger.info('[PlayEffect:play] → calling safePlay("Song")');
          safePlay(audio, "Song");
        } else {
          sessionRef.current.consumeSyncPlayHandled();

          if (isDetachedPlaybackBackendKind(backendRef.current?.kind)) {
            logger.info(
              "[PlayEffect:SKIP] reason=nativeBackend | native player handles its own playback",
            );
            return;
          }

          logger.info("[PlayEffect:pause] → calling pauseAudio");
          pauseAudio(audio);
        }
      } catch (error) {
        logger.error("[PlayEffect:ERROR]", error);
        handleAudioErrorRef.current();
      }
    }
    handleSongPlayback();
  }, [
    audioRef,
    audioSrc,
    isPlaying,
    isSong,
    pauseAudio,
    resumeContext,
    safePlay,
    seekToStart,
    seekAudio,
    setStoreProgress,
    shouldUseWebAudioReplayGain,
    songId,
  ]);

  useEffect(() => {
    async function handleRadio() {
      const audio = audioRef.current;
      if (!audio) return;

      if (isPlaying) {
        loadAudio(audio);
        safePlay(audio, "Radio");
      } else {
        pauseAudio(audio);
      }
    }
    if (isRadio) handleRadio();
  }, [audioRef, isPlaying, isRadio, loadAudio, pauseAudio, safePlay]);

  const handleLoadedMetadata = useCallback(
    (e: React.SyntheticEvent<HTMLAudioElement>) => {
      onLoadedMetadata?.(e);
    },
    [onLoadedMetadata],
  );

  const handleCanPlay = useCallback(
    (e: React.SyntheticEvent<HTMLAudioElement>) => {
      const audio = e.currentTarget;
      if (sessionRef.current.pendingResumePosition !== null) {
        applyPendingResume(audio);
      }
      sessionRef.current.finishCanPlay();
      onCanPlay?.(e);
    },
    [applyPendingResume, onCanPlay],
  );

  const handleTimeUpdate = useCallback(
    (e: React.SyntheticEvent<HTMLAudioElement>) => {
      if (sessionRef.current.shouldSuppressProgressUpdate()) {
        return;
      }
      onTimeUpdate?.(e);
    },
    [onTimeUpdate],
  );

  const crossOrigin = useMemo(() => {
    if (!shouldUseWebAudioReplayGain) return undefined;
    if (audioSrc?.startsWith("blob:")) return undefined;

    return "anonymous";
  }, [shouldUseWebAudioReplayGain, audioSrc]);

  return (
    <audio
      ref={audioRef}
      {...props}
      src={shouldUseDetachedPlayback ? undefined : audioSrc}
      crossOrigin={crossOrigin}
      onError={handleError}
      onTimeUpdate={handleTimeUpdate}
      onProgress={onProgress}
      onLoadedMetadata={handleLoadedMetadata}
      onDurationChange={(e) => props.onDurationChange?.(e)}
      onCanPlay={handleCanPlay}
      onPlay={(e) => {
        logger.info(
          `[onPlay] currentTime=${e.currentTarget.currentTime.toFixed(2)} | duration=${e.currentTarget.duration?.toFixed(2)} | loopRestarting=${sessionRef.current.loopRestarting} | syncPlayHandled=${sessionRef.current.syncPlayHandled}`,
        );
        sessionRef.current.handlePlayEvent();
        onPlay?.(e);
      }}
      onPause={(e) => {
        const audio = e.currentTarget;
        const storeState = usePlayerStore.getState();
        logger.info(
          `[onPause] currentTime=${audio.currentTime.toFixed(2)} | duration=${audio.duration?.toFixed(2)} | paused=${audio.paused} | ended=${audio.ended} | loopRestarting=${sessionRef.current.loopRestarting} | srcChanging=${sessionRef.current.sourceChanging} | isPlaying_store=${storeState.playerState.isPlaying} | audioError=${!!audio.error} | error=${audio.error?.code}`,
        );

        const decision = sessionRef.current.handlePauseEvent({
          ended: audio.ended,
          storeIsPlaying: storeState.playerState.isPlaying,
          hasAudioError: !!audio.error,
        });

        if (decision.type === "skip") {
          if (decision.reason === "srcChanging") {
            const state = usePlayerStore.getState();
            if (state.playerState.isPlaying && !state.remoteControl.active) {
              manageMediaSession.ensurePlaybackStatePlaying();
            }
            logger.info(
              `[onPause:SKIP] reason=srcChanging | ⚠️mediaSessionKeptPlaying=${state.playerState.isPlaying && !state.remoteControl.active}`,
            );
            return;
          }
          if (decision.reason === "effectPausing") {
            logger.info(
              `[onPause:SKIP] reason=effectPausing | currentTime=${audio.currentTime.toFixed(2)}`,
            );
            return;
          }
          if (decision.reason === "audioError") {
            logger.info(
              `[onPause:SKIP] reason=audioError | errorCode=${audio.error?.code}`,
            );
            return;
          }
          logger.info(
            `[onPause:SKIP] reason=${decision.reason} | currentTime=${audio.currentTime.toFixed(2)}`,
          );
          return;
        }

        logger.info(
          `[onPause:FORWARD] currentTime=${audio.currentTime.toFixed(2)} | duration=${audio.duration?.toFixed(2)} | isPlaying_store=${usePlayerStore.getState().playerState.isPlaying}`,
        );
        onPause?.(e);
      }}
      onEnded={(e) => {
        const state = usePlayerStore.getState();
        const loopState = state.playerState.loopState;
        const songlist = state.songlist;

        const decision = getPlaybackEndedDecision({
          loopState,
          songlist,
        });
        const hasNext =
          decision.type === "forward-ended"
            ? decision.action === "playNext"
            : false;

        logger.info(
          `[onEnded] loopState=${loopState} | hasNext=${hasNext} | songId=${songId} | currentTime=${e.currentTarget.currentTime.toFixed(2)} | duration=${e.currentTarget.duration?.toFixed(2)}`,
        );

        if (state.songlist.currentSong) {
          manageMediaSession.setMediaSession(state.songlist.currentSong);
        }

        if (decision.type === "restart-current") {
          logger.info(
            `[onEnded → LoopRestartSync] songId=${songId} | loopRestartingRef=true | syncPlayHandledRef=true | currentTime→0 | calling safePlay`,
          );
          sessionRef.current.markLoopRestarting();
          sessionRef.current.markLoopRestartSyncHandled();
          seekAudio(e.currentTarget, 0);
          setStoreProgress(0, true);
          safePlay(e.currentTarget, "LoopRestartSync");
        } else {
          logger.info(
            `[onEnded → forward] reason=${hasNext ? "hasNext" : "notLoopOne"} | calling handleSongEnded`,
          );
        }

        onEnded?.(e);
      }}
      playsInline
      preload="auto"
    />
  );
}

function isDetachedPlaybackBackendKind(kind?: PlaybackBackendKind) {
  return kind === "native" || kind === "sidecar";
}
