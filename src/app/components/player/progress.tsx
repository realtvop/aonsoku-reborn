import clsx from "clsx";
import { RefObject, useMemo } from "react";
import { ProgressSlider } from "@/app/components/ui/slider";
import { useAudioSeeking } from "@/app/hooks/use-audio-seeking";
import {
  useHasQueueSongs,
  useIsRemoteControlActive,
  usePlayerBufferedProgress,
  usePlayerDuration,
  usePlayerIsBuffering,
  usePlayerMediaType,
  usePlayerProgress,
} from "@/store/player.store";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";

interface PlayerProgressProps {
  audioRef: RefObject<HTMLAudioElement>;
}

export function PlayerProgress({ audioRef }: PlayerProgressProps) {
  const progress = usePlayerProgress();
  const bufferedProgress = usePlayerBufferedProgress();
  const currentDuration = usePlayerDuration();
  const isBuffering = usePlayerIsBuffering();
  const hasQueueSongs = useHasQueueSongs();
  const { isSong } = usePlayerMediaType();
  const isRemoteActive = useIsRemoteControlActive();

  const isEmpty = isSong && !hasQueueSongs;

  const { localProgress, isLocalSeeking, handleSeeking, handleSeeked } =
    useAudioSeeking({ audioRef });

  const currentTime = convertSecondsToTime(
    isLocalSeeking ? localProgress : progress,
  );

  const songDuration = useMemo(
    () => convertSecondsToTime(currentDuration ?? 0),
    [currentDuration],
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
      {!isEmpty ? (
        <ProgressSlider
          defaultValue={[0]}
          value={isLocalSeeking ? [localProgress] : [progress]}
          max={currentDuration ?? 0}
          step={1}
          className="cursor-pointer w-[32rem]"
          isBuffering={isBuffering}
          bufferedProgress={isRemoteActive ? 0 : bufferedProgress}
          onValueChange={([value]) => handleSeeking(value)}
          onValueCommit={([value]) => handleSeeked(value)}
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
