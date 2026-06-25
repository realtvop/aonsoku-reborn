import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { ProgressSlider } from "@/app/components/ui/slider";
import { useAudioSeeking } from "@/app/hooks/use-audio-seeking";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import {
  useIsRemoteControlActive,
  usePlayerBufferedProgress,
  usePlayerDuration,
  usePlayerIsBuffering,
  usePlayerProgress,
  usePlayerRef,
} from "@/store/player.store";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";
import { clampProgress } from "@/utils/duration";

function useSmoothRemoteProgress({
  active,
  isPlaying,
  progress,
  duration,
}: {
  active: boolean;
  isPlaying: boolean;
  progress: number;
  duration: number;
}) {
  const [displayProgress, setDisplayProgress] = useState(progress);

  useEffect(() => {
    setDisplayProgress(progress);
  }, [progress]);

  useEffect(() => {
    if (!active || !isPlaying) return;

    let lastTick = performance.now();
    const interval = window.setInterval(() => {
      const now = performance.now();
      const elapsedSeconds = (now - lastTick) / 1000;
      lastTick = now;
      setDisplayProgress((current) =>
        clampProgress(current + elapsedSeconds, duration),
      );
    }, 250);

    return () => window.clearInterval(interval);
  }, [active, duration, isPlaying]);

  return displayProgress;
}

export function FullscreenProgress({
  thin = false,
  stacked = false,
}: {
  thin?: boolean;
  stacked?: boolean;
}) {
  const progress = usePlayerProgress();
  const bufferedProgress = usePlayerBufferedProgress();
  const audioPlayerRef = usePlayerRef();
  const currentDuration = usePlayerDuration();
  const isBuffering = usePlayerIsBuffering();
  const isRemoteActive = useIsRemoteControlActive();
  const remoteProjection = useRemotePlaybackProjection();
  const { t } = useTranslation();
  const contrast = useFullscreenContrast();

  const audioRef = useMemo(
    () => ({ current: audioPlayerRef }),
    [audioPlayerRef],
  );
  const {
    localProgress,
    isLocalSeeking: isSeeking,
    handleSeeking,
    handleSeeked,
  } = useAudioSeeking({ audioRef });

  const smoothRemoteProgress = useSmoothRemoteProgress({
    active: remoteProjection.active,
    isPlaying: remoteProjection.isPlaying,
    progress: remoteProjection.progress,
    duration: remoteProjection.duration,
  });

  const effectiveProgress = remoteProjection.active
    ? smoothRemoteProgress
    : progress;
  const effectiveDuration = remoteProjection.active
    ? remoteProjection.duration
    : currentDuration;
  const currentTime = convertSecondsToTime(
    isSeeking ? localProgress : effectiveProgress,
  );

  const songDuration = useMemo(
    () => convertSecondsToTime(effectiveDuration ?? 0),
    [effectiveDuration],
  );

  const sliderProps = {
    variant: "secondary" as const,
    defaultValue: [0] as [number],
    value: (isSeeking ? [localProgress] : [effectiveProgress]) as [number],
    max: effectiveDuration ?? 0,
    step: 1,
    isBuffering,
    bufferedProgress: isRemoteActive ? 0 : bufferedProgress,
    className: "w-full h-2 md:h-3",
    onValueChange: ([value]: [number]) => handleSeeking(value),
    onValueCommit: ([value]: [number]) => handleSeeked(value),
    "data-vaul-no-drag": true,
    "aria-label": t("player.tooltips.progress"),
    contrast,
  };

  if (stacked) {
    return (
      <div className="w-full">
        <ProgressSlider {...sliderProps} />
        <div className="flex justify-between mt-1">
          <div className="tabular-nums text-foreground/50 text-xs">
            {currentTime}
          </div>
          <div className="tabular-nums text-foreground/50 text-xs">
            {songDuration}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 md:gap-3 w-full">
      <div
        className={`min-w-[36px] md:min-w-[42px] text-right tabular-nums text-foreground/70 ${
          thin ? "text-xs" : "text-xs md:text-sm"
        }`}
      >
        {currentTime}
      </div>

      <ProgressSlider {...sliderProps} />

      <div
        className={`min-w-[36px] md:min-w-[42px] text-left tabular-nums text-foreground/70 ${
          thin ? "text-xs" : "text-xs md:text-sm"
        }`}
      >
        {songDuration}
      </div>
    </div>
  );
}
