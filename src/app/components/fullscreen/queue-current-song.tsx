import { clsx } from "clsx";
import { EllipsisVertical, Repeat, Shuffle } from "lucide-react";
import { memo } from "react";
import { useTranslation } from "react-i18next";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { LikeButton } from "@/app/components/fullscreen/like-button";
import RepeatOne from "@/app/components/icons/repeat-one";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { Button } from "@/app/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/app/components/ui/dropdown-menu";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { useTouchMenuGuard } from "@/app/hooks/use-touch-menu-guard";
import {
  usePlayerActions,
  usePlayerLoop,
  usePlayerShuffle,
  usePlayerStore,
} from "@/store/player.store";
import { LoopState } from "@/types/playerContext";
import { CurrentSongMenuOptions } from "./current-song-menu-options";

export const QueueCurrentSong = memo(function QueueCurrentSong({
  onClick,
}: {
  onClick?: () => void;
}) {
  const currentSong = usePlayerStore(
    (state) => state.songlist.currentSong,
    (a, b) => a?.id === b?.id,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;
  const { hoverBg10 } = useFullscreenContrast();
  const { open, setOpen, triggerProps } = useTouchMenuGuard();

  if (!displaySong) return null;

  return (
    <div className={clsx("pt-2 pb-0.5 px-2 rounded-lg")} onClick={onClick}>
      <div className="flex items-center gap-3">
        <div className="w-12 h-12 rounded overflow-hidden shrink-0 bg-accent">
          <CachedImage
            coverArtId={displaySong.coverArt}
            coverArtType="song"
            albumId={displaySong.albumId}
            className="w-12 h-12 object-cover"
            alt={`${displaySong.title} - ${displaySong.artist}`}
          />
        </div>
        <div className="flex flex-col min-w-0 flex-1">
          <span className="font-semibold text-sm truncate">
            {displaySong.title}
          </span>
          <span className="text-xs text-foreground/70 truncate">
            {displaySong.artist}
          </span>
        </div>
        <div
          className="flex items-center gap-3 shrink-0"
          onClick={(e) => e.stopPropagation()}
          onTouchStart={(e) => e.stopPropagation()}
          onTouchMove={(e) => e.stopPropagation()}
          onTouchEnd={(e) => e.stopPropagation()}
        >
          <LikeButton className="shrink-0 size-8 rounded-full" />
          <DropdownMenu open={open} onOpenChange={setOpen}>
            <DropdownMenuTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                className={clsx(
                  "shrink-0 size-8 rounded-full",
                  hoverBg10,
                  triggerProps.className,
                )}
                onPointerDown={triggerProps.onPointerDown}
                onPointerMove={triggerProps.onPointerMove}
                onPointerUp={triggerProps.onPointerUp}
                onPointerCancel={triggerProps.onPointerCancel}
                onClick={triggerProps.onClick}
                onContextMenu={triggerProps.onContextMenu}
              >
                <EllipsisVertical className="w-4 h-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <CurrentSongMenuOptions song={displaySong} />
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
    </div>
  );
});

export const QueueModeButtons = memo(function QueueModeButtons() {
  const isShuffleActive = usePlayerShuffle();
  const loopState = usePlayerLoop();
  const remoteProjection = useRemotePlaybackProjection();
  const { toggleShuffle, toggleLoop } = usePlayerActions();
  const { t } = useTranslation();
  const { isBackdropDark } = useFullscreenContrast();

  const effectiveShuffleActive = remoteProjection.active
    ? remoteProjection.isShuffleActive
    : isShuffleActive;
  const effectiveLoopState = remoteProjection.active
    ? remoteProjection.loopState
    : loopState;
  const isRepeatActive = effectiveLoopState !== LoopState.Off;

  const activeBtn = clsx(
    "flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium",
    isBackdropDark
      ? "bg-white/15 text-white"
      : "bg-foreground/15 text-foreground",
  );

  const inactiveBtn = clsx(
    "flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium",
    isBackdropDark
      ? "text-white/60 border border-white/30 hover-supported:text-white hover-supported:bg-white/10"
      : "text-foreground/60 border border-foreground/30 hover-supported:text-foreground hover-supported:bg-foreground/10",
  );

  return (
    <div className="flex items-center justify-center gap-2">
      <button
        type="button"
        onClick={toggleShuffle}
        aria-pressed={effectiveShuffleActive}
        className={effectiveShuffleActive ? activeBtn : inactiveBtn}
      >
        <Shuffle className="w-3 h-3" />
        {effectiveShuffleActive
          ? t("player.tooltips.shuffle.disable")
          : t("player.tooltips.shuffle.enable")}
      </button>
      <button
        type="button"
        onClick={toggleLoop}
        aria-pressed={isRepeatActive}
        className={isRepeatActive ? activeBtn : inactiveBtn}
      >
        {effectiveLoopState === LoopState.One ? (
          <RepeatOne size={12} />
        ) : (
          <Repeat className="w-3 h-3" />
        )}
        {isRepeatActive
          ? t("player.tooltips.repeat.disable")
          : effectiveLoopState === LoopState.One
            ? t("player.tooltips.repeat.enableOne")
            : t("player.tooltips.repeat.enable")}
      </button>
    </div>
  );
});
