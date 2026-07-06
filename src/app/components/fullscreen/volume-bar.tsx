import { useCallback, useRef, type WheelEvent } from "react";
import { useTranslation } from "react-i18next";
import { VolumeIcon } from "@/app/components/icons/volume-icon";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { Button } from "@/app/components/ui/button";
import { Slider } from "@/app/components/ui/slider";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { useMuteToggle } from "@/app/hooks/use-mute-toggle";
import { useSystemVolume } from "@/app/hooks/use-system-volume";
import { usePlayerVolume, useVolumeSettings } from "@/store/player.store";
import { getPlaybackCapabilities } from "@/utils/capabilities";

export function VolumeBar() {
  const { volume: playerVolume, handleMuteClick } = useMuteToggle();
  const { setVolume: setPlayerVolume, handleVolumeWheel: handlePlayerWheel } =
    usePlayerVolume();
  const { min, max, step } = useVolumeSettings();
  const remoteProjection = useRemotePlaybackProjection();
  const {
    volume: systemVolume,
    setSystemVolume,
    commitSystemVolume,
    handleVolumeWheel: handleSystemWheel,
    supportsSystemVolumeControl,
  } = useSystemVolume();
  const wheelRafRef = useRef<number | null>(null);
  const { t } = useTranslation();
  const { requiresSystemVolume } = getPlaybackCapabilities();
  const { hoverBg10 } = useFullscreenContrast();
  const remoteVolume = remoteProjection.volume ?? playerVolume;

  const displayVolume = remoteProjection.active
    ? remoteVolume
    : supportsSystemVolumeControl
      ? systemVolume
      : playerVolume;
  const isDisabled =
    !remoteProjection.active &&
    requiresSystemVolume &&
    !supportsSystemVolumeControl;

  const handleWheel = useCallback(
    (e: WheelEvent<HTMLDivElement>) => {
      if (isDisabled || wheelRafRef.current !== null) return;
      wheelRafRef.current = requestAnimationFrame(() => {
        if (remoteProjection.active) {
          const delta = e.deltaY > 0 ? -step : step;
          setPlayerVolume(Math.min(max, Math.max(min, remoteVolume + delta)));
        } else if (supportsSystemVolumeControl) {
          handleSystemWheel(e.deltaY > 0);
        } else {
          handlePlayerWheel(e.deltaY > 0);
        }
        wheelRafRef.current = null;
      });
    },
    [
      handlePlayerWheel,
      handleSystemWheel,
      isDisabled,
      max,
      min,
      remoteProjection.active,
      remoteVolume,
      setPlayerVolume,
      step,
      supportsSystemVolumeControl,
    ],
  );

  const handleSliderChange = useCallback(
    ([value]: number[]) => {
      if (remoteProjection.active) {
        setPlayerVolume(value);
      } else if (supportsSystemVolumeControl) {
        setSystemVolume(value);
      } else {
        setPlayerVolume(value);
      }
    },
    [
      remoteProjection.active,
      supportsSystemVolumeControl,
      setSystemVolume,
      setPlayerVolume,
    ],
  );

  const handleSliderCommit = useCallback(
    ([value]: number[]) => {
      if (remoteProjection.active) {
        setPlayerVolume(value);
      } else if (supportsSystemVolumeControl) {
        commitSystemVolume(value);
      }
    },
    [
      commitSystemVolume,
      remoteProjection.active,
      setPlayerVolume,
      supportsSystemVolumeControl,
    ],
  );

  const handleMuteButtonClick = useCallback(() => {
    if (!remoteProjection.active) {
      handleMuteClick();
      return;
    }

    setPlayerVolume(displayVolume === 0 ? 100 : 0);
  }, [
    displayVolume,
    handleMuteClick,
    remoteProjection.active,
    setPlayerVolume,
  ]);

  return (
    <div
      className="flex w-full min-w-0 items-center gap-2"
      data-testid="fullscreen-volume-bar"
      onWheel={handleWheel}
    >
      <Button
        variant="ghost"
        size="icon"
        className={`size-8 p-0 shrink-0 ${hoverBg10}`}
        onClick={handleMuteButtonClick}
        disabled={isDisabled}
        aria-label={
          displayVolume === 0
            ? t("player.tooltips.volume.unmute")
            : t("player.tooltips.volume.mute")
        }
      >
        <VolumeIcon
          volume={displayVolume}
          size={16}
          className="text-foreground/70"
        />
      </Button>
      <Slider
        variant="secondary"
        value={[displayVolume]}
        min={min}
        max={max}
        step={step}
        className="h-3 w-full min-w-0"
        onValueChange={handleSliderChange}
        onValueCommit={handleSliderCommit}
        disabled={isDisabled}
        aria-label={t("player.tooltips.volume.mute")}
      />
      <VolumeIcon
        volume={100}
        size={16}
        className="text-foreground/70 shrink-0"
      />
    </div>
  );
}
