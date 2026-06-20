import type { Draft } from "immer";
import type { IPlayerContext, IPlayerState } from "@/types/playerContext";
import { LoopState } from "@/types/playerContext";
import { logger } from "@/utils/logger";
import { initSonglistState } from "./queue-utils";

export const initialPlayerState: IPlayerState = {
  isPlaying: false,
  loopState: LoopState.Off,
  isSongStarred: false,
  volume: 100,
  currentDuration: 0,
  mediaType: "song",
  audioPlayerRef: null,
  radioPlayerRef: null,
  mainDrawerState: false,
  queueState: false,
  lyricsState: false,
  fullscreenPlayerOpen: false,
  fullscreenPlayerTab: "playing",
  desktopFullscreenPanelView: "queue",
  hasPrev: false,
  hasNext: false,
  isBuffering: false,
  areLyricsAligned: true,
  seekToStart: false,
  isTransitioning: false,
  pipWindowOpen: false,
};

export const initialSonglist = initSonglistState();

export const initialPlayerProgress = {
  progress: 0,
  bufferedProgress: 0,
  isScrubbing: false,
  scrubbingProgress: 0,
};

type SetFn = (fn: (state: Draft<IPlayerContext>) => void) => void;

export function createInitialSettings(set: SetFn): IPlayerContext["settings"] {
  return {
    privacy: {
      lrcLibEnabled: true,
      setLrcLibEnabled(value: boolean) {
        set((state) => {
          state.settings.privacy.lrcLibEnabled = value;
        });
      },
    },
    volume: {
      min: 0,
      max: 100,
      step: 1,
      wheelStep: 5,
    },
    fullscreen: {
      autoFullscreenEnabled: false,
      setAutoFullscreenEnabled: (value: boolean) => {
        set((state) => {
          state.settings.fullscreen.autoFullscreenEnabled = value;
        });
      },
    },
    coverArt: {
      useAlbumCoverForSongs: false,
      setUseAlbumCoverForSongs: (value: boolean) => {
        set((state) => {
          state.settings.coverArt.useAlbumCoverForSongs = value;
        });
      },
    },
    lyrics: {
      preferSyncedLyrics: false,
      setPreferSyncedLyrics: (value: boolean) => {
        set((state) => {
          state.settings.lyrics.preferSyncedLyrics = value;
        });
      },
      showTranslation: true,
      setShowTranslation: (value: boolean) => {
        set((state) => {
          state.settings.lyrics.showTranslation = value;
        });
      },
      sourcePriority: ["navidrome", "lrclib", "custom"],
      setSourcePriority: (value) => {
        set((state) => {
          state.settings.lyrics.sourcePriority = value;
        });
      },
      customServerEnabled: false,
      setCustomServerEnabled: (value: boolean) => {
        set((state) => {
          state.settings.lyrics.customServerEnabled = value;
        });
      },
      customServerUrl: "",
      setCustomServerUrl: (value: string) => {
        set((state) => {
          state.settings.lyrics.customServerUrl = value;
        });
      },
      customServerPassword: "",
      setCustomServerPassword: (value: string) => {
        set((state) => {
          state.settings.lyrics.customServerPassword = value;
        });
      },
      selectedCustomLyrics: {},
      setSelectedCustomLyrics: async (songKey, selection) => {
        const { lyrics: body, ...meta } = selection;
        if (body) {
          try {
            const { setCustomLyricsBody } = await import("@/service/lyrics");
            await setCustomLyricsBody(songKey, body);
          } catch (err) {
            logger.warn("[player] Failed to persist custom lyrics body:", err);
            throw err;
          }
        }
        set((state) => {
          state.settings.lyrics.selectedCustomLyrics ||= {};
          state.settings.lyrics.selectedCustomLyrics[songKey] = meta;
        });
      },
    },
    replayGain: {
      values: {
        enabled: false,
        type: "track",
        preAmp: 0,
        error: false,
        defaultGain: -6,
      },
      actions: {
        setReplayGainEnabled: (value: boolean) => {
          set((state) => {
            state.settings.replayGain.values.enabled = value;
          });
        },
        setReplayGainType: (value: "track" | "album") => {
          set((state) => {
            state.settings.replayGain.values.type = value;
          });
        },
        setReplayGainPreAmp: (value: number) => {
          set((state) => {
            state.settings.replayGain.values.preAmp = value;
          });
        },
        setReplayGainError: (value: boolean) => {
          set((state) => {
            state.settings.replayGain.values.error = value;
          });
        },
        setReplayGainDefaultGain: (value: number) => {
          set((state) => {
            state.settings.replayGain.values.defaultGain = value;
          });
        },
      },
    },
    colors: {
      currentSongColor: null,
      currentSongColorIntensity: 0.65,
    },
    hapticFeedback: {
      hapticFeedbackEnabled: true,
      setHapticFeedbackEnabled: (value: boolean) => {
        set((state) => {
          state.settings.hapticFeedback.hapticFeedbackEnabled = value;
        });
      },
    },
    pip: {
      acceptBrowserPipRequest: false,
      setAcceptBrowserPipRequest: (value: boolean) => {
        set((state) => {
          state.settings.pip.acceptBrowserPipRequest = value;
        });
      },
    },
  };
}

export const initialRemoteControl: IPlayerContext["remoteControl"] = {
  active: false,
  device: null,
  sendCommand: null,
};
