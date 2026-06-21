import type { Draft } from "immer";
import clamp from "lodash/clamp";
import { LanControlMessageType } from "@/types/lanControl";
import type { IPlayerActions, IPlayerContext } from "@/types/playerContext";
import { getPlaybackCapabilities } from "@/utils/capabilities";
import { logger } from "@/utils/logger";
import { setSystemVolume } from "@/utils/system-volume";
import { getNativeQueueController } from "@/player/queue-controller";
import { rebuildContextQueueForLoopState } from "./queue-utils";

interface SharedDeps {
  set: (fn: (state: Draft<IPlayerContext>) => void) => void;
  get: () => IPlayerContext;
  isRemoteActive: () => boolean;
  remoteSend: (type: LanControlMessageType, data?: unknown) => boolean;
}

export function createPlaybackActions(shared: SharedDeps) {
  const { set, get, isRemoteActive, remoteSend } = shared;

  return {
    setPlayingState: (status: boolean) => {
      const nativeController = getNativeQueueController();
      if (nativeController) {
        if (status) {
          nativeController.play();
        } else {
          nativeController.pause();
        }
        return;
      }

      const prev = get().playerState.isPlaying;
      logger.info(
        `[setPlayingState] ${prev} → ${status} | isRemote=${!!isRemoteActive()}`,
      );
      if (isRemoteActive()) {
        remoteSend(
          status ? LanControlMessageType.PLAY : LanControlMessageType.PAUSE,
        );
      }
      set((state) => {
        state.playerState.isPlaying = status;
      });
    },

    togglePlayPause: () => {
      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.togglePlayPause();
        return;
      }

      const prev = get().playerState.isPlaying;
      logger.info(`[togglePlayPause] isPlaying: ${prev} → ${!prev}`);
      remoteSend(LanControlMessageType.PLAY_PAUSE);
      set((state) => {
        state.playerState.isPlaying = !prev;
      });
    },

    toggleLoop: () => {
      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.toggleLoop();
        return;
      }

      const { loopState } = get().playerState;
      const newState = (loopState + 1) % (2 + 1);

      remoteSend(LanControlMessageType.TOGGLE_REPEAT);
      set((state) => {
        state.playerState.loopState = newState as 0 | 1 | 2;
        rebuildContextQueueForLoopState(
          state.songlist,
          state.playerState.loopState,
        );
      });
    },

    resetProgress: () => {
      if (isRemoteActive()) return;
      set((state) => {
        state.playerProgress.progress = 0;
        state.playerProgress.bufferedProgress = 0;
      });
    },

    setProgress: (progress: number, isSeek?: boolean) => {
      const nativeController = getNativeQueueController();
      if (nativeController) {
        nativeController.seek(progress);
        return;
      }

      remoteSend(LanControlMessageType.SEEK, {
        seconds: progress,
      });
      set((state) => {
        state.playerProgress.progress = progress;
        if (isSeek) {
          state.playerProgress.seekCount = (state.playerProgress.seekCount ?? 0) + 1;
        }
      });
    },

    setIsScrubbing: (value: boolean) => {
      if (get().playerProgress.isScrubbing === value) return;
      set((state) => {
        state.playerProgress.isScrubbing = value;
      });
    },

    setScrubbingProgress: (value: number) => {
      if (get().playerProgress.scrubbingProgress === value) return;
      set((state) => {
        state.playerProgress.scrubbingProgress = value;
      });
    },

    setVolume: (volume: number) => {
      const caps = getPlaybackCapabilities();
      if (!caps.canSetVolume) return;
      remoteSend(LanControlMessageType.SET_VOLUME, {
        volume,
      });
      set((state) => {
        state.playerState.volume = volume;
      });
      if (caps.requiresSystemVolume && caps.supportsSystemVolumeControl) {
        setSystemVolume(volume);
      }
    },

    handleVolumeWheel: (isScrollingDown: boolean) => {
      if (!getPlaybackCapabilities().canSetVolume) return;
      if (isRemoteActive()) return;
      const { min, max, wheelStep } = get().settings.volume;
      const { volume } = get().playerState;

      if (isScrollingDown && volume === min) return;
      if (!isScrollingDown && volume === max) return;

      const volumeAdjustment = isScrollingDown ? -wheelStep : wheelStep;
      const adjustedVolume = volume + volumeAdjustment;
      const finalVolume = clamp(adjustedVolume, min, max);

      set((state) => {
        state.playerState.volume = finalVolume;
      });
    },

    setCurrentDuration: (duration: number) => {
      if (isRemoteActive()) return;
      set((state) => {
        state.playerState.currentDuration = duration;
      });
    },

    setIsBuffering: (value: boolean) => {
      if (get().playerState.isBuffering === value) return;
      set((state) => {
        state.playerState.isBuffering = value;
      });
    },

    setBufferedProgress: (value: number) => {
      if (isRemoteActive()) return;
      const prev = get().playerProgress.bufferedProgress;
      if (prev === value) return;
      set((state) => {
        state.playerProgress.bufferedProgress = value;
      });
    },

    setAudioPlayerRef: (audioPlayer: HTMLAudioElement | null) => {
      set((state) => {
        state.playerState.audioPlayerRef = audioPlayer;
      });
    },

    setRadioPlayerRef: (radioPlayer: HTMLAudioElement | null) => {
      set((state) => {
        state.playerState.radioPlayerRef = radioPlayer;
      });
    },

    setIsTransitioning: (value: boolean) => {
      const prev = get().playerState.isTransitioning;
      logger.info(`[setIsTransitioning] ${prev} → ${value}`);
      set((state) => {
        state.playerState.isTransitioning = value;
      });
    },

    getCurrentProgress: () => {
      return get().playerProgress.progress;
    },
  } satisfies Partial<IPlayerActions>;
}
