import { getCoverArtUrl } from "@/api/httpClient";
import { usePlayerStore } from "@/store/player.store";
import { EpisodeWithPodcast } from "@/types/responses/podcasts";
import { ISong } from "@/types/responses/song";

const artworkSizes = ["96", "128", "192", "256", "384", "512"];

function removeMediaSession() {
  if (!navigator.mediaSession) return;

  navigator.mediaSession.metadata = null;
}

function setMediaSession(song: ISong) {
  if (!navigator.mediaSession) return;

  navigator.mediaSession.metadata = new MediaMetadata({
    title: song.title,
    artist: song.artist,
    album: song.album,
    artwork: artworkSizes.map((size): MediaImage => {
      return {
        src: getCoverArtUrl(song.coverArt, "song", size),
        sizes: [size, size].join("x"),
        type: "image/jpeg",
      };
    }),
  });
}

function setPodcastMediaSession(episode: EpisodeWithPodcast) {
  if (!navigator.mediaSession) return;

  navigator.mediaSession.metadata = new MediaMetadata({
    title: episode.title,
    album: episode.podcast.title,
    artist: episode.podcast.author,
    artwork: [
      {
        src: episode.image_url,
        sizes: "",
        type: "image/jpeg",
      },
    ],
  });
}

async function setRadioMediaSession(label: string, radioName: string) {
  if (!navigator.mediaSession) return;

  navigator.mediaSession.metadata = new MediaMetadata({
    title: radioName,
    artist: label,
    album: "",
    artwork: [
      {
        src: "",
        sizes: "",
        type: "",
      },
    ],
  });
}

function setPlaybackState(state: boolean | null) {
  if (!navigator.mediaSession) return;

  if (state === null) navigator.mediaSession.playbackState = "none";

  if (state) {
    navigator.mediaSession.playbackState = "playing";
  } else {
    navigator.mediaSession.playbackState = "paused";
  }
}

function setPositionState(duration: number, position: number, playbackRate = 1.0) {
  if (!navigator.mediaSession) return;
  
  try {
    navigator.mediaSession.setPositionState({
      duration: duration,
      playbackRate: playbackRate,
      position: position,
    });
  } catch (error) {
    // Position state might not be supported on all browsers
    console.error("Failed to set position state:", error);
  }
}

function setHandlers() {
  const { mediaSession } = navigator;
  if (!mediaSession) return;

  const state = usePlayerStore.getState();
  const { togglePlayPause, playNextSong, playPrevSong, setProgress } = state.actions;

  mediaSession.setActionHandler("seekbackward", null);
  mediaSession.setActionHandler("seekforward", null);

  mediaSession.setActionHandler("play", () => togglePlayPause());
  mediaSession.setActionHandler("pause", () => togglePlayPause());
  mediaSession.setActionHandler("previoustrack", () => playPrevSong());
  mediaSession.setActionHandler("nexttrack", () => playNextSong());
  
  // Support seekto for iOS and other platforms
  mediaSession.setActionHandler("seekto", (details) => {
    if (details.seekTime !== undefined) {
      const audioPlayerRef = state.playerState.audioPlayerRef;
      if (audioPlayerRef) {
        audioPlayerRef.currentTime = details.seekTime;
        setProgress(Math.floor(details.seekTime));
      }
    }
  });
}

interface SetPodcastHandlerParams {
  handleSeekAction: (value: number) => void;
}

function setPodcastHandlers({ handleSeekAction }: SetPodcastHandlerParams) {
  const { mediaSession } = navigator;
  if (!mediaSession) return;

  const state = usePlayerStore.getState();
  const { setPlayingState, setProgress } = state.actions;

  mediaSession.setActionHandler("previoustrack", null);
  mediaSession.setActionHandler("nexttrack", null);

  mediaSession.setActionHandler("play", () => setPlayingState(true));
  mediaSession.setActionHandler("pause", () => setPlayingState(false));
  mediaSession.setActionHandler("seekbackward", () => handleSeekAction(-15));
  mediaSession.setActionHandler("seekforward", () => handleSeekAction(30));
  
  // Support seekto for iOS and other platforms
  mediaSession.setActionHandler("seekto", (details) => {
    if (details.seekTime !== undefined) {
      const audioPlayerRef = state.playerState.audioPlayerRef;
      if (audioPlayerRef) {
        audioPlayerRef.currentTime = details.seekTime;
        setProgress(Math.floor(details.seekTime));
      }
    }
  });
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
