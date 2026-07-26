import { clsx } from "clsx";
import { EllipsisVertical } from "lucide-react";
import { memo } from "react";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { Button } from "@/app/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/app/components/ui/dropdown-menu";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { useTouchMenuGuard } from "@/app/hooks/use-touch-menu-guard";
import { usePlayerStore } from "@/store/player.store";
import { CONTENT_MAX_WIDTH } from "./constants";
import { CurrentSongMenuOptions } from "./current-song-menu-options";
import { LikeButton } from "./like-button";
import { FullscreenSongArtwork } from "./song-artwork";
import { AlbumName, SongInfo } from "./song-info";

export const FullscreenSongInfoRow = memo(function FullscreenSongInfoRow({
  className,
}: {
  className?: string;
}) {
  const currentSong = usePlayerStore(
    (state) => state.songlist.currentSong,
    (a, b) => a?.id === b?.id,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;
  const { hoverBg } = useFullscreenContrast();
  const { open, setOpen, triggerProps } = useTouchMenuGuard();

  return (
    <div
      className={clsx(
        "mx-auto w-full min-w-0 shrink-0 justify-self-center",
        CONTENT_MAX_WIDTH,
        className,
      )}
    >
      <div className="flex min-w-0 items-center justify-between gap-4">
        <div className="min-w-0 flex-1">
          <SongInfo />
        </div>
        <div className="flex shrink-0 items-center gap-1 pt-1">
          <LikeButton
            className="size-11 rounded-full"
            iconClassName="w-6 h-6"
          />
          {displaySong && (
            <DropdownMenu open={open} onOpenChange={setOpen}>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  className={clsx(
                    "relative size-11 rounded-full text-foreground",
                    hoverBg,
                    triggerProps.className,
                  )}
                  onPointerDown={triggerProps.onPointerDown}
                  onPointerMove={triggerProps.onPointerMove}
                  onPointerUp={triggerProps.onPointerUp}
                  onPointerCancel={triggerProps.onPointerCancel}
                  onClick={triggerProps.onClick}
                  onContextMenu={triggerProps.onContextMenu}
                  style={{ backfaceVisibility: "hidden" }}
                >
                  <EllipsisVertical className="w-6 h-6 text-foreground/70" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <CurrentSongMenuOptions song={displaySong} />
              </DropdownMenuContent>
            </DropdownMenu>
          )}
        </div>
      </div>
    </div>
  );
});

export const ArtworkWithInfo = memo(function ArtworkWithInfo({
  className,
  showTouchDragSurface = false,
  showInfo = true,
}: {
  className?: string;
  showTouchDragSurface?: boolean;
  showInfo?: boolean;
}) {
  return (
    <div
      className={clsx(
        "flex w-full min-h-0 min-w-0 flex-col items-center",
        showInfo ? "flex-1 justify-between" : "justify-center",
        className,
      )}
    >
      <div className="flex w-full min-h-0 flex-col items-center justify-center flex-1">
        <div
          className={clsx(
            "mx-auto w-full min-w-0 shrink-0 justify-self-center pb-2",
            CONTENT_MAX_WIDTH,
          )}
        >
          <AlbumName className="pb-1 [&>div]:py-0.5 [&_p]:leading-normal" />
        </div>

        <div className="flex min-h-0 w-full flex-1 items-center justify-center overflow-hidden [container-type:size]">
          <div className="aspect-square flex-none w-[min(100cqw,100cqh,clamp(280px,85vw,480px))]">
            <FullscreenSongArtwork
              showTouchDragSurface={showTouchDragSurface}
            />
          </div>
        </div>
      </div>

      {showInfo && <FullscreenSongInfoRow className="pt-4" />}
    </div>
  );
});
