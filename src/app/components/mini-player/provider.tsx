import { PropsWithChildren, useEffect, useMemo, useState } from "react";
import {
  useRemotePlaybackProjection,
  useSmoothRemoteProgress,
} from "@/app/components/remote-control/use-remote-playback-projection";
import { useCurrentLyricLine } from "@/app/hooks/use-current-lyric-line";
import { usePlaybackControls } from "@/app/hooks/use-playback-controls";
import { useSystemVolume } from "@/app/hooks/use-system-volume";
import {
  usePlayerActions,
  usePlayerProgress,
  usePlayerStore,
  useSongColor,
} from "@/store/player.store";
import {
  listenMiniPlayerUpdates,
  MiniPlayerState,
  requestState,
  sendControlAction,
} from "@/utils/mini-player-sync";
import { MiniPlayerContext, MiniPlayerContextValue } from "./context";

/**
 * Internal provider for Web PiP mode.
 * Directly maps Zustand store and hooks to the MiniPlayerContext.
 */
export function InternalMiniPlayerProvider({ children }: PropsWithChildren) {
  const {
    isPlaying,
    isBuffering,
    isTransitioning,
    isShuffleActive,
    cannotSkipNext,
    canUsePreviousControl,
    loopState,
    toggleShuffle,
    playPrevSong,
    togglePlayPause,
    playNextSong,
    toggleLoop,
  } = usePlaybackControls();

  const { starCurrentSong, setProgress, setVolume } = usePlayerActions();
  const { currentSongColor } = useSongColor();
  const currentSong = usePlayerStore((s) => s.songlist.currentSong);
  const playerState = usePlayerStore((s) => s.playerState);
  const progress = usePlayerProgress();
  const remoteProjection = useRemotePlaybackProjection();
  const smoothRemoteProgress = useSmoothRemoteProgress({
    active: remoteProjection.active,
    isPlaying: remoteProjection.isPlaying,
    progress: remoteProjection.progress,
    duration: remoteProjection.duration,
  });
  const { currentLine } = useCurrentLyricLine();
  const { volume: systemVolume, supportsSystemVolumeControl } =
    useSystemVolume();

  const displaySong = remoteProjection.song ?? currentSong;
  const displayProgress = remoteProjection.active
    ? smoothRemoteProgress
    : progress;
  const displayDuration = remoteProjection.active
    ? remoteProjection.duration
    : (playerState.currentDuration ?? 0);
  const displayVolume = remoteProjection.active
    ? (remoteProjection.volume ?? playerState.volume)
    : supportsSystemVolumeControl
      ? systemVolume
      : playerState.volume;
  const isSongStarred = remoteProjection.active
    ? typeof remoteProjection.song?.starred === "string"
    : playerState.isSongStarred;

  const value = useMemo<MiniPlayerContextValue>(
    () => ({
      state: {
        isPlaying,
        isTransitioning,
        isBuffering,
        shuffleActive: isShuffleActive,
        loopState,
        hasPrev: canUsePreviousControl,
        hasNext: !cannotSkipNext,
        isSongStarred,
        currentSong: displaySong
          ? {
              id: displaySong.id,
              title: displaySong.title,
              artist: displaySong.artist,
              artists: displaySong.artists?.map((a) => ({
                id: a.id,
                name: a.name,
              })),
              coverArt: displaySong.coverArt,
              albumId: displaySong.albumId,
            }
          : null,
        progress: displayProgress,
        duration: displayDuration,
        volume: displayVolume,
        mediaType: playerState.mediaType as "song" | "radio",
        currentSongColor,
        currentLine: remoteProjection.active ? null : currentLine,
      },
      actions: {
        togglePlayPause,
        playNextSong,
        playPrevSong,
        toggleShuffle: () => toggleShuffle(),
        toggleLoop: () => toggleLoop(),
        seek: (time) => setProgress(time, true),
        setVolume: (v) => setVolume(v),
        starCurrentSong,
      },
    }),
    [
      isPlaying,
      isBuffering,
      isTransitioning,
      playerState,
      isSongStarred,
      isShuffleActive,
      loopState,
      cannotSkipNext,
      canUsePreviousControl,
      displaySong,
      displayProgress,
      displayDuration,
      currentSongColor,
      currentLine,
      displayVolume,
      remoteProjection.active,
      togglePlayPause,
      playNextSong,
      playPrevSong,
      toggleShuffle,
      toggleLoop,
      setProgress,
      setVolume,
      starCurrentSong,
    ],
  );

  return (
    <MiniPlayerContext.Provider value={value}>
      {children}
    </MiniPlayerContext.Provider>
  );
}

/**
 * External provider for Electron independent window.
 * Maps BroadcastChannel messages and control actions to the MiniPlayerContext.
 */
export function ExternalMiniPlayerProvider({ children }: PropsWithChildren) {
  const [state, setState] = useState<MiniPlayerState | null>(null);

  useEffect(() => {
    const unsubscribe = listenMiniPlayerUpdates(setState);
    requestState();
    return unsubscribe;
  }, []);

  const value = useMemo<MiniPlayerContextValue>(
    () => ({
      state,
      actions: {
        togglePlayPause: () => sendControlAction("togglePlayPause"),
        playNextSong: () => sendControlAction("playNextSong"),
        playPrevSong: () => sendControlAction("playPrevSong"),
        toggleShuffle: () => sendControlAction("toggleShuffle"),
        toggleLoop: () => sendControlAction("toggleLoop"),
        seek: (time) => sendControlAction("seek", time),
        setVolume: (v) => sendControlAction("setVolume", v),
        starCurrentSong: () => sendControlAction("starCurrentSong"),
      },
    }),
    [state],
  );

  return (
    <MiniPlayerContext.Provider value={value}>
      {children}
    </MiniPlayerContext.Provider>
  );
}
