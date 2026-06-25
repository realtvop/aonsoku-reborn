import { clsx } from "clsx";
import { Heart } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { Button } from "@/app/components/ui/button";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import {
  usePlayerActions,
  usePlayerSongStarred,
  usePlayerStore,
} from "@/store/player.store";
import { LanControlMessageType } from "@/types/lanControl";

interface LikeButtonProps {
  className?: string;
  iconClassName?: string;
  onClick?: React.MouseEventHandler<HTMLButtonElement>;
}

export function LikeButton({
  className,
  iconClassName,
  onClick,
}: LikeButtonProps) {
  const { starCurrentSong } = usePlayerActions();
  const isSongStarred = usePlayerSongStarred();
  const remoteProjection = useRemotePlaybackProjection();
  const { t } = useTranslation();
  const { hoverBg } = useFullscreenContrast();

  const isOverride = className?.includes("size-");
  const effectiveIsStarred = remoteProjection.active
    ? typeof remoteProjection.song?.starred === "string"
    : isSongStarred;
  const handleClick =
    onClick ??
    (() => {
      if (remoteProjection.active) {
        usePlayerStore
          .getState()
          .remoteControl.sendCommand?.(LanControlMessageType.TOGGLE_LIKE);
        return;
      }
      starCurrentSong();
    });

  return (
    <Button
      size="icon"
      variant="ghost"
      className={clsx(
        !isOverride && "relative w-11 h-11 md:w-12 md:h-12 rounded-full",
        !isOverride && hoverBg,
        !isOverride && "text-foreground",
        className,
      )}
      onClick={handleClick}
      style={isOverride ? undefined : { backfaceVisibility: "hidden" }}
      aria-label={
        effectiveIsStarred
          ? t("player.tooltips.unstar")
          : t("player.tooltips.star")
      }
    >
      <Heart
        className={clsx(
          isOverride ? "w-4 h-4" : "w-6 h-6",
          iconClassName,
          effectiveIsStarred
            ? "text-red-500 fill-red-500"
            : "text-foreground/70",
        )}
      />
    </Button>
  );
}
