import { Pause, Play, SkipForward } from "lucide-react";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { PlayerDeviceButton } from "@/app/components/remote-control/device-button";
import { DevicePanel } from "@/app/components/remote-control/device-panel";
import { useDevicePlaybackActions } from "@/app/components/remote-control/use-device-playback-actions";
import { HandoffConfirmationDialog } from "@/app/components/remote-control/handoff-confirmation-dialog";
import { RemoteModePlayerStatus } from "@/app/components/remote-control/remote-mode-player-status";
import { MiniPlayerButton } from "@/app/components/mini-player/button";
import { RadioInfo } from "@/app/components/player/radio-info";
import { TrackInfo } from "@/app/components/player/track-info";
import { Button } from "@/app/components/ui/button";
import { useAudioSource } from "@/app/hooks/use-audio-source";
import { usePlayHistory } from "@/app/hooks/use-play-history";
import { usePlayerBreakpoint } from "@/app/hooks/use-player-breakpoint";
import { usePreloadAudio } from "@/app/hooks/use-preload-audio";
import { useScrobble } from "@/app/hooks/use-scrobble";
import { useSleepTimer } from "@/app/hooks/use-sleep-timer";
import { useNativeForegroundSync } from "@/app/hooks/use-native-foreground-sync";
import {
  getAudioDurationSeconds,
  getAudioProgressSnapshot,
  getBufferedTime,
  type PlaybackMetadata,
} from "@/player/playback";
import { openFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";
import {
  useIsRemoteControlActive,
  usePlayerActions,
  usePlayerIsPlaying,
  usePlayerIsTransitioning,
  usePlayerLoop,
  usePlayerMediaType,
  usePlayerPrevAndNext,
  usePlayerSonglist,
  usePlayerStore,
  useReplayGainState,
} from "@/store/player.store";
import { LoopState } from "@/types/playerContext";
import { hasMiniPlayerSupport } from "@/utils/browser";
import { logger } from "@/utils/logger";
import { getCoverArtUrlFromSongPreference } from "@/utils/coverArt";
import {
  type ReplayGainParams,
  resolveReplayGainParams,
} from "@/utils/replayGain";
import {
  audioSourceResolver,
  getAudioSourceUrl,
  type AudioSourceDescriptor,
} from "@/service/cache";
import { AudioPlayer } from "./audio";
import { PlayerClearQueueButton } from "./clear-queue-button";
import { PlayerControls } from "./controls";
import { PlayerLikeButton } from "./like-button";
import { PlayerLyricsButton } from "./lyrics-button";
import { PlayerProgress } from "./progress";
import { PlayerQueueButton } from "./queue-button";
import { PlayerVolume } from "./volume";

const MemoTrackInfo = memo(TrackInfo);
const MemoRadioInfo = memo(RadioInfo);
const MemoPlayerControls = memo(PlayerControls);
const MemoPlayerProgress = memo(PlayerProgress);
const MemoPlayerLikeButton = memo(PlayerLikeButton);
const MemoPlayerQueueButton = memo(PlayerQueueButton);
const MemoPlayerClearQueueButton = memo(PlayerClearQueueButton);
const MemoPlayerVolume = memo(PlayerVolume);
const MemoLyricsButton = memo(PlayerLyricsButton);
const MemoMiniPlayerButton = memo(MiniPlayerButton);
const MemoAudioPlayer = memo(AudioPlayer);

export function Player() {
  const { t } = useTranslation();
  const [panelOpen, setPanelOpen] = useState(false);
  const deviceActions = useDevicePlaybackActions();

  useEffect(() => {
    const handleOpen = () => setPanelOpen(true);
    window.addEventListener("open-device-panel", handleOpen);
    return () => window.removeEventListener("open-device-panel", handleOpen);
  }, []);

  const radioLabel = t("radios.label");
  const audioRef = useRef<HTMLAudioElement>(null);
  const radioRef = useRef<HTMLAudioElement>(null);
  const isMobile = usePlayerBreakpoint();
  const {
    setAudioPlayerRef,
    setRadioPlayerRef,
    setCurrentDuration,
    setIsBuffering: setStoreIsBuffering,
    setBufferedProgress,
    setProgress,
    setPlayingState,
    setIsScrubbing,
    setIsTransitioning,
    handleSongEnded,
    getCurrentProgress,
    togglePlayPause,
    playNextSong,
  } = usePlayerActions();
  const { currentList, currentSongIndex, radioList } = usePlayerSonglist();
  const isPlaying = usePlayerIsPlaying();
  const { isSong, isRadio } = usePlayerMediaType();
  const loopState = usePlayerLoop();
  const isRemoteControlActive = useIsRemoteControlActive();
  const { replayGainType, replayGainPreAmp, replayGainDefaultGain } =
    useReplayGainState();
  const { hasNext } = usePlayerPrevAndNext();

  usePlayHistory();
  useScrobble();
  usePreloadAudio();
  useNativeForegroundSync();
  useSleepTimer();

  const isTransitioning = usePlayerIsTransitioning();

  useEffect(() => {
    if (!isTransitioning) return;
    const timeout = setTimeout(() => {
      const current = usePlayerStore.getState().playerState.isTransitioning;
      if (current) {
        logger.info(
          `[isTransitioning] timeout fallback, clearing isTransitioning`,
        );
        setIsTransitioning(false);
      }
    }, 5000);
    return () => clearTimeout(timeout);
  }, [isTransitioning, setIsTransitioning]);

  const song = currentList[currentSongIndex] ?? null;
  const radio = radioList[currentSongIndex];
  const songId = song?.id;
  const { source: audioSource, resolvedSongId } = useAudioSource(song?.id);
  const audioSrc = audioSource ? getAudioSourceUrl(audioSource) : "";
  const radioSource = useMemo<AudioSourceDescriptor | null>(() => {
    if (!radio) return null;

    return audioSourceResolver.resolveRadioSource(radio.streamUrl, radio.id);
  }, [radio]);
  const songMetadata = useMemo<PlaybackMetadata | null>(() => {
    if (!song) return null;

    return {
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      artworkUrl: getCoverArtUrlFromSongPreference({
        coverArt: song.coverArt,
        coverArtType: "song",
        albumId: song.albumId,
        size: "300",
      }),
    };
  }, [song]);
  const radioMetadata = useMemo<PlaybackMetadata | null>(() => {
    if (!radio) return null;

    return {
      title: radio.name,
      artist: radioLabel,
      album: "",
    };
  }, [radio, radioLabel]);

  const getAudioRef = useCallback(() => {
    if (isRadio) return radioRef;

    return audioRef;
  }, [isRadio]);

  useEffect(() => {
    if (!isSong || !songId) return;
    if (isRemoteControlActive) return;
    setBufferedProgress(0);

    const currentAudio = audioRef.current;
    if (
      currentAudio &&
      currentAudio !== usePlayerStore.getState().playerState.audioPlayerRef
    ) {
      setAudioPlayerRef(currentAudio);
    }
  }, [
    isRemoteControlActive,
    isSong,
    setAudioPlayerRef,
    songId,
    setBufferedProgress,
  ]);

  useEffect(() => {
    if (!isSong || isRemoteControlActive) return;

    const currentAudio = audioRef.current;
    if (
      currentAudio &&
      currentAudio !== usePlayerStore.getState().playerState.audioPlayerRef
    ) {
      setAudioPlayerRef(currentAudio);
    }

    return () => {
      const storedRef = usePlayerStore.getState().playerState.audioPlayerRef;
      if (storedRef === currentAudio) {
        setAudioPlayerRef(null);
      }
    };
  }, [isRemoteControlActive, isSong, setAudioPlayerRef]);

  useEffect(() => {
    if (!isRadio || isRemoteControlActive) return;

    const currentRadio = radioRef.current;
    if (
      currentRadio &&
      currentRadio !== usePlayerStore.getState().playerState.radioPlayerRef
    ) {
      setRadioPlayerRef(currentRadio);
    }

    return () => {
      const storedRef = usePlayerStore.getState().playerState.radioPlayerRef;
      if (storedRef === currentRadio) {
        setRadioPlayerRef(null);
      }
    };
  }, [isRemoteControlActive, isRadio, setRadioPlayerRef]);

  const updateAudioDuration = useCallback(() => {
    const audio = getAudioRef().current;
    if (!audio) return;

    const roundedDuration = getAudioDurationSeconds(audio);
    if (roundedDuration !== null) {
      const currentDur = usePlayerStore.getState().playerState.currentDuration;
      if (currentDur !== roundedDuration) {
        setCurrentDuration(roundedDuration);
      }
    }
  }, [getAudioRef, setCurrentDuration]);

  const setupDuration = useCallback(() => {
    const audio = getAudioRef().current;
    if (!audio) return;

    if (isSong) {
      updateAudioDuration();
    }

    const progress = getCurrentProgress();
    audio.currentTime = progress;
  }, [getAudioRef, isSong, updateAudioDuration, getCurrentProgress]);

  const setupProgress = useCallback(() => {
    const audio = getAudioRef().current;
    if (!audio) return;

    if (usePlayerStore.getState().playerProgress.isScrubbing) return;

    const { progress, bufferedProgress } = getAudioProgressSnapshot(audio);
    setProgress(progress);

    if (audio.buffered.length > 0) {
      setBufferedProgress(bufferedProgress);
    }
  }, [getAudioRef, setProgress, setBufferedProgress]);

  const trackReplayGain = useMemo(
    (): ReplayGainParams =>
      resolveReplayGainParams(
        song?.replayGain,
        replayGainType,
        replayGainPreAmp,
        replayGainDefaultGain,
      ),
    [song, replayGainType, replayGainPreAmp, replayGainDefaultGain],
  );

  const handleFooterClick = useCallback(
    (event: React.MouseEvent) => {
      if (!isMobile || window.innerWidth >= 768) return;

      // Check if the click target is a control button or interactive element
      const target = event.target as HTMLElement;
      const isControlButton = target.closest("button") !== null;
      const isSlider = target.closest('[role="slider"]') !== null;
      const isInteractive = isControlButton || isSlider;

      if (!isInteractive) {
        openFullscreenPlayerWithHistory("playing");
      }
    },
    [isMobile],
  );

  const handleAudioPlay = useCallback(
    () => setPlayingState(true),
    [setPlayingState],
  );
  const handleAudioPause = useCallback(
    () => setPlayingState(false),
    [setPlayingState],
  );
  const handleAudioWaiting = useCallback(
    () => setStoreIsBuffering(true),
    [setStoreIsBuffering],
  );
  const handleAudioPlaying = useCallback(
    () => setStoreIsBuffering(false),
    [setStoreIsBuffering],
  );
  const handleAudioCanPlay = useCallback(() => {
    setStoreIsBuffering(false);
    updateAudioDuration();
  }, [setStoreIsBuffering, updateAudioDuration]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: songId and audioRef needed for debug logging
  const handleSongCanPlay = useCallback(() => {
    const audio = audioRef.current;
    logger.info(
      `[onCanPlay] songId=${songId} | duration=${audio?.duration?.toFixed(2)} | isTransitioning=${usePlayerStore.getState().playerState.isTransitioning} | isPlaying=${usePlayerStore.getState().playerState.isPlaying} | audio.paused=${audio?.paused}`,
    );
    setStoreIsBuffering(false);
    updateAudioDuration();
    setIsTransitioning(false);
  }, [
    setStoreIsBuffering,
    updateAudioDuration,
    setIsTransitioning,
    songId,
    audioRef,
  ]);

  const handleAudioSeeked = useCallback(() => {
    if (usePlayerStore.getState().playerProgress.isScrubbing) {
      setIsScrubbing(false);
    }
  }, [setIsScrubbing]);

  const handleAudioProgress = useCallback(
    (e: React.SyntheticEvent<HTMLAudioElement>) => {
      const audio = e.currentTarget;
      if (audio.buffered.length > 0) {
        setBufferedProgress(getBufferedTime(audio));
      }
    },
    [setBufferedProgress],
  );

  const handlePlaybackError = useCallback(() => {
    setBufferedProgress(0);
    setIsTransitioning(false);
    toast.error(t("warnings.songError"));
  }, [t, setBufferedProgress, setIsTransitioning]);

  const handleReplayGainError = useCallback(() => {
    toast.error(t("warnings.songError"));
  }, [t]);

  return (
    <footer
      className="border-t h-[--player-height] w-full flex items-center fixed bottom-[--bottom-nav-height] left-0 right-0 z-40 bg-background"
      style={{
        paddingLeft: "var(--safe-area-left)",
        paddingRight: "var(--safe-area-right)",
      }}
      onClick={handleFooterClick}
    >
      <div className="w-full h-full grid grid-cols-[1fr_auto] gap-3 px-3 md:grid-cols-player md:gap-2 md:px-4">
        {/* Track Info */}
        <div className="flex items-center gap-1 w-full min-w-0 md:gap-2">
          {isSong && <MemoTrackInfo song={song} />}
          {isRadio && <MemoRadioInfo radio={radio} />}
          {isRemoteControlActive && (
            <RemoteModePlayerStatus
              onExit={deviceActions.exitRemoteControl}
              compact={isMobile}
            />
          )}
        </div>
        {/* Main Controls */}
        <div className="hidden md:col-span-2 md:flex flex-col justify-center items-center px-4 gap-1">
          <MemoPlayerControls song={song} radio={radio} />

          {isSong && <MemoPlayerProgress audioRef={getAudioRef()} />}
        </div>
        {/* Mobile Controls - Only Play/Pause and Next */}
        <div className="flex md:hidden items-center gap-0.5">
          <Button
            variant="ghost"
            disabled={!song && !radio}
            onClick={togglePlayPause}
            data-testid={`player-button-${isPlaying ? "pause" : "play"}`}
            className="size-11 p-0"
          >
            {isPlaying ? (
              <Pause className="text-foreground fill-foreground size-5" />
            ) : (
              <Play className="text-foreground fill-foreground size-5" />
            )}
          </Button>
          <Button
            variant="ghost"
            disabled={
              (!song && !radio) || (!hasNext && loopState !== LoopState.All)
            }
            onClick={playNextSong}
            data-testid="player-button-next-mobile"
            className="size-11 p-0"
            unfocusable
          >
            <SkipForward className="text-foreground fill-foreground size-5" />
          </Button>
        </div>
        {/* Remain Controls and Volume */}
        <div className="hidden md:flex items-center w-full justify-end">
          <div className="flex items-center gap-1">
            {isSong && (
              <>
                <MemoPlayerLikeButton disabled={!song} />
                <MemoLyricsButton disabled={!song} />
                <MemoPlayerQueueButton disabled={!song} />
              </>
            )}
            {isRadio && <MemoPlayerClearQueueButton disabled={!radio} />}

            <MemoPlayerVolume
              audioRef={getAudioRef()}
              disabled={!song && !radio}
            />

            {!isMobile && (
              <DevicePanel
                open={panelOpen}
                onOpenChange={setPanelOpen}
                actions={deviceActions}
                trigger={
                  <PlayerDeviceButton
                    isActive={deviceActions.isControlling}
                  />
                }
              />
            )}

            {isSong && hasMiniPlayerSupport && <MemoMiniPlayerButton />}
          </div>
        </div>
      </div>

      {isSong && song && !isRemoteControlActive && (
        <MemoAudioPlayer
          audioSource={audioSource}
          replayGain={trackReplayGain}
          metadata={songMetadata}
          src={audioSrc}
          songId={resolvedSongId}
          autoPlay={isPlaying}
          audioRef={audioRef}
          onPlay={handleAudioPlay}
          onPause={handleAudioPause}
          onLoadedMetadata={setupDuration}
          onDurationChange={updateAudioDuration}
          onTimeUpdate={setupProgress}
          onProgress={handleAudioProgress}
          onEnded={handleSongEnded}
          onWaiting={handleAudioWaiting}
          onPlaying={handleAudioPlaying}
          onCanPlay={handleSongCanPlay}
          onSeeked={handleAudioSeeked}
          onPlaybackError={handlePlaybackError}
          onReplayGainError={handleReplayGainError}
          data-testid="player-song-audio"
        />
      )}

      {isRadio && radio && !isRemoteControlActive && (
        <MemoAudioPlayer
          audioSource={radioSource}
          metadata={radioMetadata}
          src={radio.streamUrl}
          autoPlay={isPlaying}
          audioRef={radioRef}
          onPlay={handleAudioPlay}
          onPause={handleAudioPause}
          onWaiting={handleAudioWaiting}
          onPlaying={handleAudioPlaying}
          onCanPlay={handleAudioCanPlay}
          data-testid="player-radio-audio"
        />
      )}

      <HandoffConfirmationDialog
        open={deviceActions.isConfirmationOpen}
        onOpenChange={deviceActions.setIsConfirmationOpen}
        pendingDevice={deviceActions.pendingDevice}
        onConfirm={deviceActions.confirmLocalReplacement}
        onCancel={deviceActions.cancelPendingHandoff}
      />
    </footer>
  );
}
