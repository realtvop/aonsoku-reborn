import { getCoverArtUrl } from "@/api/httpClient";
import { usePlayerStore } from "@/store/player.store";
import { EpisodeWithPodcast } from "@/types/responses/podcasts";
import { ISong } from "@/types/responses/song";
import { LanControlMessageType } from "@/types/lanControl";

const artworkSizes = ["96", "128", "192", "256", "384", "512"];

/**
 * Check if MediaSession API is supported and available
 */
function isMediaSessionSupported(): boolean {
  return (
    typeof navigator !== "undefined" &&
    "mediaSession" in navigator &&
    navigator.mediaSession !== null
  );
}

/**
 * Log MediaSession related information for debugging
 */
function logMediaSessionInfo(action: string, data?: unknown): void {
  if (!isMediaSessionSupported()) {
    console.warn(`[MediaSession] ${action}: API not supported`);
    return;
  }
  console.log(`[MediaSession] ${action}:`, data);
}

function removeMediaSession() {
  if (!isMediaSessionSupported()) return;

  try {
    navigator.mediaSession.metadata = null;
    logMediaSessionInfo("Removed metadata");
  } catch (error) {
    console.error("[MediaSession] Failed to remove metadata:", error);
  }
}

function setMediaSession(
  song:
    | ISong
    | {
        title: string;
        artist: string;
        album: string;
        coverArt?: string;
        duration?: number;
      },
) {
  if (!isMediaSessionSupported()) {
    console.warn("[MediaSession] navigator.mediaSession not available");
    return;
  }

  try {
    const artwork = song.coverArt
      ? artworkSizes.map((size): MediaImage => {
          return {
            src: getCoverArtUrl(song.coverArt, "song", size),
            sizes: [size, size].join("x"),
            type: "image/jpeg",
          };
        })
      : [];

    const metadata = {
      title: song.title || "Unknown Title",
      artist: song.artist || "Unknown Artist",
      album: song.album || "Unknown Album",
      artwork,
    };

    logMediaSessionInfo("Setting metadata", {
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      hasArtwork: artwork.length > 0,
    });

    navigator.mediaSession.metadata = new MediaMetadata(metadata);

    // Verify that metadata was actually set
    if (navigator.mediaSession.metadata === null) {
      console.warn("[MediaSession] Metadata was set to null unexpectedly");
    }
  } catch (error) {
    console.error("[MediaSession] Failed to set metadata:", error);
  }
}

function setPodcastMediaSession(episode: EpisodeWithPodcast) {
  if (!isMediaSessionSupported()) return;

  try {
    const metadata = {
      title: episode.title || "Unknown Episode",
      album: episode.podcast?.title || "Unknown Podcast",
      artist: episode.podcast?.author || "Unknown Author",
      artwork: episode.image_url
        ? [
            {
              src: episode.image_url,
              sizes: "",
              type: "image/jpeg",
            },
          ]
        : [],
    };

    logMediaSessionInfo("Setting podcast metadata", metadata);
    navigator.mediaSession.metadata = new MediaMetadata(metadata);
  } catch (error) {
    console.error("[MediaSession] Failed to set podcast metadata:", error);
  }
}

async function setRadioMediaSession(label: string, radioName: string) {
  if (!isMediaSessionSupported()) return;

  try {
    const metadata = {
      title: radioName || "Unknown Radio",
      artist: label || "Radio",
      album: "",
      artwork: [],
    };

    logMediaSessionInfo("Setting radio metadata", metadata);
    navigator.mediaSession.metadata = new MediaMetadata(metadata);
  } catch (error) {
    console.error("[MediaSession] Failed to set radio metadata:", error);
  }
}

function setPlaybackState(state: boolean | null) {
  if (!isMediaSessionSupported()) return;

  try {
    let newState: MediaSessionPlaybackState = "none";
    if (state === null) {
      newState = "none";
    } else if (state) {
      newState = "playing";
    } else {
      newState = "paused";
    }

    logMediaSessionInfo("Setting playback state", newState);
    navigator.mediaSession.playbackState = newState;

    // Verify that playback state was actually set
    if (navigator.mediaSession.playbackState !== newState) {
      console.warn(
        "[MediaSession] Playback state mismatch:",
        "expected",
        newState,
        "got",
        navigator.mediaSession.playbackState,
      );
    }
  } catch (error) {
    console.error("[MediaSession] Failed to set playback state:", error);
  }
}

function setPositionState(
  duration: number,
  position: number,
  playbackRate = 1.0,
) {
  if (!isMediaSessionSupported()) return;

  // Validate inputs
  if (typeof duration !== "number" || duration < 0) {
    console.warn("[MediaSession] Invalid duration:", duration);
    return;
  }
  if (typeof position !== "number" || position < 0) {
    console.warn("[MediaSession] Invalid position:", position);
    return;
  }
  if (position > duration) {
    console.warn(
      "[MediaSession] Position exceeds duration:",
      position,
      ">",
      duration,
    );
    position = duration;
  }

  try {
    navigator.mediaSession.setPositionState({
      duration: duration,
      playbackRate: playbackRate,
      position: position,
    });
    logMediaSessionInfo("Set position state", {
      duration,
      position,
      playbackRate,
    });
  } catch (error) {
    // Position state might not be supported on all browsers
    console.warn("[MediaSession] Failed to set position state:", error);
  }
}

function setHandlers() {
  if (!isMediaSessionSupported()) {
    console.warn("[MediaSession] Cannot set handlers: API not supported");
    return;
  }

  const { mediaSession } = navigator;

  try {
    const state = usePlayerStore.getState();
    const { togglePlayPause, playNextSong, playPrevSong, setProgress } =
      state.actions;
    const isRemoteActive = state.remoteControl.active;
    const remoteSender = state.remoteControl.sendCommand;

    logMediaSessionInfo("Setting up action handlers", {
      isRemoteActive,
      hasRemoteSender: !!remoteSender,
    });

    // Clear previous handlers
    mediaSession.setActionHandler("seekbackward", null);
    mediaSession.setActionHandler("seekforward", null);

    // Play/Pause handler
    mediaSession.setActionHandler("play", () => {
      console.log("[MediaSession] Play action triggered");
      if (isRemoteActive && remoteSender) {
        remoteSender(LanControlMessageType.PLAY);
      } else {
        togglePlayPause();
      }
    });

    mediaSession.setActionHandler("pause", () => {
      console.log("[MediaSession] Pause action triggered");
      if (isRemoteActive && remoteSender) {
        remoteSender(LanControlMessageType.PAUSE);
      } else {
        togglePlayPause();
      }
    });

    // Previous track handler
    mediaSession.setActionHandler("previoustrack", () => {
      console.log("[MediaSession] Previous track action triggered");
      if (isRemoteActive && remoteSender) {
        remoteSender(LanControlMessageType.PREVIOUS);
      } else {
        playPrevSong();
      }
    });

    // Next track handler
    mediaSession.setActionHandler("nexttrack", () => {
      console.log("[MediaSession] Next track action triggered");
      if (isRemoteActive && remoteSender) {
        remoteSender(LanControlMessageType.NEXT);
      } else {
        playNextSong();
      }
    });

    // Seek handler
    mediaSession.setActionHandler("seekto", (details) => {
      console.log("[MediaSession] Seek action triggered:", details);
      if (details.seekTime !== undefined) {
        if (isRemoteActive && remoteSender) {
          remoteSender(LanControlMessageType.SEEK, { time: details.seekTime });
        } else {
          const audioPlayerRef = state.playerState.audioPlayerRef;
          if (audioPlayerRef) {
            audioPlayerRef.currentTime = details.seekTime;
            setProgress(Math.floor(details.seekTime));
          }
        }
      }
    });

    console.log("[MediaSession] All action handlers set successfully");
  } catch (error) {
    console.error("[MediaSession] Failed to set action handlers:", error);
  }
}

interface SetPodcastHandlerParams {
  handleSeekAction: (value: number) => void;
}

function setPodcastHandlers({ handleSeekAction }: SetPodcastHandlerParams) {
  if (!isMediaSessionSupported()) {
    console.warn(
      "[MediaSession] Cannot set podcast handlers: API not supported",
    );
    return;
  }

  const { mediaSession } = navigator;

  try {
    const state = usePlayerStore.getState();
    const { setPlayingState, setProgress } = state.actions;

    logMediaSessionInfo("Setting up podcast action handlers");

    mediaSession.setActionHandler("previoustrack", null);
    mediaSession.setActionHandler("nexttrack", null);

    mediaSession.setActionHandler("play", () => {
      console.log("[MediaSession] Podcast play action triggered");
      setPlayingState(true);
    });

    mediaSession.setActionHandler("pause", () => {
      console.log("[MediaSession] Podcast pause action triggered");
      setPlayingState(false);
    });

    mediaSession.setActionHandler("seekbackward", () => {
      console.log("[MediaSession] Podcast seek backward action triggered");
      handleSeekAction(-15);
    });

    mediaSession.setActionHandler("seekforward", () => {
      console.log("[MediaSession] Podcast seek forward action triggered");
      handleSeekAction(30);
    });

    // Support seekto for iOS and other platforms
    mediaSession.setActionHandler("seekto", (details) => {
      console.log("[MediaSession] Podcast seek to action triggered:", details);
      if (details.seekTime !== undefined) {
        const audioPlayerRef = state.playerState.audioPlayerRef;
        if (audioPlayerRef) {
          audioPlayerRef.currentTime = details.seekTime;
          setProgress(Math.floor(details.seekTime));
        }
      }
    });

    console.log("[MediaSession] Podcast action handlers set successfully");
  } catch (error) {
    console.error(
      "[MediaSession] Failed to set podcast action handlers:",
      error,
    );
  }
}

export const manageMediaSession = {
  removeMediaSession,
  setMediaSession,
  setRadioMediaSession,
  setPodcastMediaSession,
  setPlaybackState,
  setPositionState,
  setHandlers,
  setPodcastHandlers,
};
