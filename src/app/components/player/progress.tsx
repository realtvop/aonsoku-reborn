import clsx from "clsx";
import {
  RefObject,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { ProgressSlider } from "@/app/components/ui/slider";
import { podcasts } from "@/service/podcasts";
import { subsonic } from "@/service/subsonic";
import {
  usePlayerActions,
  usePlayerDuration,
  usePlayerIsPlaying,
  usePlayerMediaType,
  usePlayerProgress,
  usePlayerSonglist,
  useIsRemoteControlActive,
} from "@/store/player.store";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";
import { logger } from "@/utils/logger";

interface PlayerProgressProps {
  audioRef: RefObject<HTMLAudioElement>;
}

export function PlayerProgress({ audioRef }: PlayerProgressProps) {
  const progress = usePlayerProgress();
  const [localProgress, setLocalProgress] = useState(progress);
  const [isLocalSeeking, setIsLocalSeeking] = useState(false);
  const currentDuration = usePlayerDuration();
  const isPlaying = usePlayerIsPlaying();
  const { currentSong, currentList, podcastList, currentSongIndex } =
    usePlayerSonglist();
  const { isSong, isPodcast } = usePlayerMediaType();
  const { setProgress, setUpdatePodcastProgress, getCurrentPodcastProgress } =
    usePlayerActions();
  const isRemoteControlActive = useIsRemoteControlActive();
  const isScrobbleSentRef = useRef(false);
  const isNowPlayingSentRef = useRef(false);

  const isEmpty = isSong && currentList.length === 0;

  // Sync local progress with global progress when not seeking
  useEffect(() => {
    if (!isLocalSeeking) {
      setLocalProgress(progress);
    }
  }, [progress, isLocalSeeking]);

  const updateAudioCurrentTime = useCallback(
    (value: number) => {
      if (isRemoteControlActive) return;
      if (audioRef.current) {
        logger.info("Seeking to:", value);
        audioRef.current.currentTime = value;
      }
    },
    [audioRef, isRemoteControlActive],
  );

  const handleSeeking = useCallback((amount: number) => {
    setIsLocalSeeking(true);
    setLocalProgress(amount);
  }, []);

  const handleSeeked = useCallback(
    (amount: number) => {
      logger.info("Seek completed:", amount);
      setIsLocalSeeking(false);
      if (!isRemoteControlActive) {
        updateAudioCurrentTime(amount);
      }
      setProgress(amount);
      setLocalProgress(amount);
    },
    [isRemoteControlActive, setProgress, updateAudioCurrentTime],
  );

  const handleSeekedFallback = useCallback(() => {
    if (isLocalSeeking) {
      logger.info("Seek fallback triggered:", localProgress);
      setIsLocalSeeking(false);
      if (localProgress !== progress) {
        if (!isRemoteControlActive) {
          updateAudioCurrentTime(localProgress);
        }
        setProgress(localProgress);
      }
    }
  }, [
    isLocalSeeking,
    isRemoteControlActive,
    localProgress,
    progress,
    setProgress,
    updateAudioCurrentTime,
  ]);

  const songDuration = useMemo(
    () => convertSecondsToTime(currentDuration ?? 0),
    [currentDuration],
  );

  const sendScrobble = useCallback(async (songId: string) => {
    await subsonic.scrobble.send(songId);
  }, []);

  const progressTicks = useRef(0);

  useEffect(() => {
    if (isRemoteControlActive || !isSong || !isPlaying || !currentSong?.id)
      return;

    // Send now playing notification when song starts
    if (progress === 0 && !isNowPlayingSentRef.current) {
      subsonic.scrobble.send(currentSong.id, false);
      isNowPlayingSentRef.current = true;
    }

    // Reset flag when song changes or stops
    if (progress === 0 && !isPlaying) {
      isNowPlayingSentRef.current = false;
    }
  }, [isSong, isPlaying, currentSong?.id, progress, isRemoteControlActive]);

  // Reset the flag when the song changes
  useEffect(() => {
    isNowPlayingSentRef.current = false;
  }, []);

  useEffect(() => {
    if (isLocalSeeking || !isPlaying) {
      return;
    }
    if (isRemoteControlActive || !isSong) return;
    if (isSong) {
      const progressPercentage = (progress / currentDuration) * 100;

      if (progressPercentage === 0) {
        isScrobbleSentRef.current = false;
        progressTicks.current = 0;
      } else {
        progressTicks.current += 1;

        if (
          (progressTicks.current >= currentDuration / 2 ||
            progressTicks.current >= 60 * 4) &&
          !isScrobbleSentRef.current
        ) {
          sendScrobble(currentSong.id);
          isScrobbleSentRef.current = true;
        }
      }
    }
  }, [
    progress,
    currentDuration,
    isSong,
    sendScrobble,
    currentSong.id,
    isPlaying,
    isRemoteControlActive,
    isLocalSeeking,
  ]);

  // Used to save listening progress to backend every 30 seconds
  useEffect(() => {
    if (isRemoteControlActive || !isPodcast || !podcastList) return;
    if (progress === 0) return;

    const send = (progress / 30) % 1 === 0;
    if (!send) return;

    const podcast = podcastList[currentSongIndex] ?? null;
    if (!podcast) return;

    const podcastProgress = getCurrentPodcastProgress();
    if (progress === podcastProgress) return;

    setUpdatePodcastProgress(progress);

    podcasts
      .saveEpisodeProgress(podcast.id, progress)
      .then(() => {
        logger.info("Progress sent:", progress);
      })
      .catch((error) => {
        logger.error("Error sending progress", error);
      });
  }, [
    currentSongIndex,
    getCurrentPodcastProgress,
    isPodcast,
    podcastList,
    progress,
    setUpdatePodcastProgress,
    isRemoteControlActive,
  ]);

  const currentTime = convertSecondsToTime(
    isLocalSeeking ? localProgress : progress,
  );

  const isProgressLarge = useMemo(() => {
    return localProgress >= 3600 || progress >= 3600;
  }, [localProgress, progress]);

  const isDurationLarge = useMemo(() => {
    return currentDuration >= 3600;
  }, [currentDuration]);

  return (
    <div
      className={clsx(
        "flex w-full justify-center items-center gap-2",
        isEmpty && "opacity-50",
      )}
    >
      <small
        className={clsx(
          "text-xs text-muted-foreground text-right",
          isProgressLarge ? "min-w-14" : "min-w-10",
        )}
        data-testid="player-current-time"
      >
        {currentTime}
      </small>
      {!isEmpty || isPodcast ? (
        <ProgressSlider
          defaultValue={[0]}
          value={isLocalSeeking ? [localProgress] : [progress]}
          tooltipTransformer={convertSecondsToTime}
          max={currentDuration}
          step={1}
          className="cursor-pointer w-[32rem]"
          onValueChange={([value]) => handleSeeking(value)}
          onValueCommit={([value]) => handleSeeked(value)}
          // Sometimes onValueCommit doesn't work properly
          // so we also have to set the value on pointer/mouse up events
          // see https://github.com/radix-ui/primitives/issues/1760
          onPointerUp={handleSeekedFallback}
          onMouseUp={handleSeekedFallback}
          onTouchEnd={handleSeekedFallback}
          data-testid="player-progress-slider"
        />
      ) : (
        <ProgressSlider
          defaultValue={[0]}
          max={100}
          step={1}
          disabled={true}
          className="cursor-pointer w-[32rem] pointer-events-none"
        />
      )}
      <small
        className={clsx(
          "text-xs text-muted-foreground text-left",
          isDurationLarge ? "min-w-14" : "min-w-10",
        )}
        data-testid="player-duration-time"
      >
        {songDuration}
      </small>
    </div>
  );
}
