import {
  useRemotePlaybackProjection,
} from "@/app/components/remote-control/use-remote-playback-projection";
import {
  usePlayerActions,
  usePlayerIsBuffering,
  usePlayerIsPlaying,
  usePlayerIsTransitioning,
  usePlayerLoop,
  usePlayerPrevAndNext,
  usePlayerShuffle,
} from "@/store/player.store";
import { LoopState } from "@/types/playerContext";

export function usePlaybackControls() {
  const remoteProjection = useRemotePlaybackProjection();
  const isPlaying = usePlayerIsPlaying();
  const isBuffering = usePlayerIsBuffering();
  const isTransitioning = usePlayerIsTransitioning();
  const isShuffleActive = usePlayerShuffle();
  const loopState = usePlayerLoop();
  const { hasPrev, hasNext } = usePlayerPrevAndNext();
  const {
    isPlayingOneSong,
    toggleShuffle,
    playNextSong,
    playPrevSong,
    togglePlayPause,
    toggleLoop,
  } = usePlayerActions();

  const effectiveIsPlaying = remoteProjection.active
    ? remoteProjection.isPlaying
    : isPlaying;
  const effectiveShuffle = remoteProjection.active
    ? remoteProjection.isShuffleActive
    : isShuffleActive;
  const effectiveLoopState = remoteProjection.active
    ? remoteProjection.loopState
    : loopState;
  const effectiveHasPrev = remoteProjection.active
    ? remoteProjection.hasPrev
    : hasPrev;
  const effectiveHasNext = remoteProjection.active
    ? remoteProjection.hasNext
    : hasNext;

  const cannotSkipNext =
    !effectiveHasNext && effectiveLoopState !== LoopState.All;
  const cannotSkipPrev = !effectiveHasPrev;
  const isLoopOff = effectiveLoopState === LoopState.Off;
  const isLoopAll = effectiveLoopState === LoopState.All;
  const isLoopOne = effectiveLoopState === LoopState.One;

  return {
    isPlaying: effectiveIsPlaying,
    isBuffering,
    isTransitioning,
    isShuffleActive: effectiveShuffle,
    loopState: effectiveLoopState,
    hasPrev: effectiveHasPrev,
    hasNext: effectiveHasNext,
    cannotSkipNext,
    cannotSkipPrev,
    isLoopOff,
    isLoopAll,
    isLoopOne,
    isPlayingOneSong: remoteProjection.active ? () => false : isPlayingOneSong,
    toggleShuffle,
    playNextSong,
    playPrevSong,
    togglePlayPause,
    toggleLoop,
  };
}
