import clsx from "clsx";
import {
  Loader2,
  Pause,
  Play,
  Repeat,
  Shuffle,
  SkipBack,
  SkipForward,
} from "lucide-react";
import { ComponentPropsWithoutRef } from "react";
import { useTranslation } from "react-i18next";
import RepeatOne from "@/app/components/icons/repeat-one";
import { Button } from "@/app/components/ui/button";
import { SimpleTooltip } from "@/app/components/ui/simple-tooltip";
import { usePlayerHotkeys } from "@/app/hooks/use-audio-hotkeys";
import { usePlaybackControls } from "@/app/hooks/use-playback-controls";
import { cn } from "@/lib/utils";
import { usePlayerMediaType } from "@/store/player.store";
import { Radio } from "@/types/responses/radios";
import { ISong } from "@/types/responses/song";

interface PlayerControlsProps {
  song: ISong;
  radio: Radio;
}

export function PlayerControls({ song, radio }: PlayerControlsProps) {
  const { t } = useTranslation();
  const { isSong } = usePlayerMediaType();
  const {
    isPlaying,
    isBuffering,
    isTransitioning,
    isShuffleActive,
    loopState,
    cannotSkipNext,
    canUsePreviousControl,
    isLoopOff,
    isLoopAll,
    isLoopOne,
    isPlayingOneSong,
    toggleShuffle,
    playPrevSong,
    togglePlayPause,
    playNextSong,
    toggleLoop,
    hasNext,
  } = usePlaybackControls();
  const { useAudioHotkeys } = usePlayerHotkeys();

  useAudioHotkeys("space", togglePlayPause);
  useAudioHotkeys("mod+left", playPrevSong);
  useAudioHotkeys("mod+right", playNextSong);
  useAudioHotkeys("mod+s", toggleShuffle);
  useAudioHotkeys("mod+r", toggleLoop);

  const shuffleTooltip = isShuffleActive
    ? t("player.tooltips.shuffle.disable")
    : t("player.tooltips.shuffle.enable");

  const previousTooltip = t("player.tooltips.previous");
  const nextTooltip = t("player.tooltips.next");

  const isLoading = isBuffering || isTransitioning;

  const playTooltip = isLoading
    ? t("player.tooltips.loading")
    : isPlaying
      ? t("player.tooltips.pause")
      : t("player.tooltips.play");

  const repeatTooltips = {
    0: t("player.tooltips.repeat.enable"),
    1: t("player.tooltips.repeat.enableOne"),
    2: t("player.tooltips.repeat.disable"),
  };
  const repeatTooltip =
    repeatTooltips[loopState as keyof typeof repeatTooltips];

  const disableButtons = !song && !radio;

  return (
    <div className="flex w-full gap-1 justify-center items-center mb-1">
      {isSong && (
        <PlayerButton
          className={clsx(isShuffleActive && "player-button-active")}
          disabled={!song || isPlayingOneSong() || !hasNext}
          onClick={toggleShuffle}
          data-testid="player-button-shuffle"
          tooltip={shuffleTooltip}
          unfocusable
        >
          <Shuffle
            className={clsx(
              isShuffleActive ? "text-primary" : "text-secondary-foreground",
            )}
          />
        </PlayerButton>
      )}

      <PlayerButton
        disabled={disableButtons || !canUsePreviousControl}
        onClick={playPrevSong}
        data-testid="player-button-prev"
        tooltip={previousTooltip}
        unfocusable
      >
        <SkipBack className="text-secondary-foreground fill-secondary-foreground" />
      </PlayerButton>

      <PlayerButton
        variant="default"
        disabled={!song && !radio}
        onClick={togglePlayPause}
        data-testid={`player-button-${isPlaying ? "pause" : "play"}`}
        tooltip={playTooltip}
      >
        {isLoading ? (
          <Loader2 className="animate-spin text-primary-foreground" />
        ) : isPlaying ? (
          <Pause className="fill-primary-foreground" />
        ) : (
          <Play className="fill-primary-foreground" />
        )}
      </PlayerButton>

      <PlayerButton
        disabled={disableButtons || cannotSkipNext}
        onClick={playNextSong}
        data-testid="player-button-next"
        tooltip={nextTooltip}
        unfocusable
      >
        <SkipForward className="text-secondary-foreground fill-secondary-foreground" />
      </PlayerButton>

      {isSong && (
        <PlayerButton
          className={clsx(!isLoopOff && "player-button-active")}
          disabled={!song}
          onClick={toggleLoop}
          data-testid="player-button-loop"
          tooltip={repeatTooltip}
          unfocusable
        >
          {isLoopOff && <Repeat className="text-secondary-foreground" />}
          {isLoopAll && <Repeat className="text-primary" />}
          {isLoopOne && <RepeatOne className="text-primary" />}
        </PlayerButton>
      )}
    </div>
  );
}

type PlayerButtonProps = ComponentPropsWithoutRef<typeof Button> & {
  tooltip: string;
};

function PlayerButton({ className, tooltip, ...props }: PlayerButtonProps) {
  return (
    <SimpleTooltip text={tooltip}>
      <Button
        variant="ghost"
        className={cn(
          "relative rounded-full size-10 p-0 [&_svg]:pointer-events-none [&_svg]:size-[18px] [&_svg]:shrink-0",
          className,
        )}
        {...props}
      />
    </SimpleTooltip>
  );
}
