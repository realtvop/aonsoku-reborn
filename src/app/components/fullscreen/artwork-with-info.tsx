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
  compact = false,
  className,
}: {
  compact?: boolean;
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
          <SongInfo compact={compact} />
        </div>
        <div
          className={clsx(
            "flex shrink-0 items-center gap-1",
            compact ? "pt-0.5" : "pt-1",
          )}
        >
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
  compact = false,
  showTouchDragSurface = false,
  showInfo = true,
  fitArtworkContent = false,
  largeArtwork = false,
}: {
  className?: string;
  compact?: boolean;
  showTouchDragSurface?: boolean;
  showInfo?: boolean;
  fitArtworkContent?: boolean;
  largeArtwork?: boolean;
}) {
  return (
    <div
      className={clsx(
        "flex w-full min-h-0 min-w-0 flex-col items-center transition-all duration-300 ease-in-out",
        showInfo ? "flex-1 justify-between" : "justify-center",
        fitArtworkContent && "h-fit flex-none",
        className,
      )}
    >
      <div
        className={clsx(
          "w-full min-h-0 flex flex-col items-center justify-center",
          showInfo
            ? "flex-1"
            : fitArtworkContent
              ? "flex-none h-fit"
              : "flex-1 min-h-0",
        )}
      >
        <div
          className={clsx(
            "mx-auto w-full min-w-0 shrink-0 justify-self-center",
            CONTENT_MAX_WIDTH,
            compact ? "pb-1" : "pb-2",
          )}
        >
          <AlbumName
            compact={compact}
            className={clsx(
              "[&>div]:py-0.5 [&_p]:leading-normal",
              compact ? "pb-0.5" : "pb-1",
            )}
          />
        </div>

        <div
          className={clsx(
            "min-h-0 w-full flex items-center justify-center overflow-hidden",
            fitArtworkContent ? "flex-none h-fit" : "flex-1",
          )}
        >
          <FullscreenSongArtwork
            compact={compact}
            large={largeArtwork}
            showTouchDragSurface={showTouchDragSurface}
          />
        </div>
      </div>

      {showInfo && (
        <FullscreenSongInfoRow
          compact={compact}
          className={clsx(compact ? "pt-2" : "pt-4")}
        />
      )}
    </div>
  );
});
