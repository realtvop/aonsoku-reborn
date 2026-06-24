import { useTranslation } from "react-i18next";
import { MonitorSpeaker, AudioLines } from "lucide-react";
import { Button } from "@/app/components/ui/button";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import type { ISong } from "@/types/responses/song";

interface RemoteModePlayerStatusProps {
  song: ISong | null;
  deviceName: string | null;
  onExit: () => void;
}

export function RemoteModePlayerStatus({
  song,
  deviceName,
  onExit,
}: RemoteModePlayerStatusProps) {
  const { t } = useTranslation();

  return (
    <div className="flex items-center gap-2.5 w-full min-w-0">
      {/* Cover Art */}
      <div className="w-10 h-10 md:w-12 md:h-12 md:min-w-[48px] md:max-w-[48px] aspect-square rounded-lg overflow-hidden shadow-sm border border-border/20 flex-shrink-0">
        {song?.coverArt ? (
          <CachedImage
            key={song.id}
            id="track-song-image-remote"
            coverArtId={song.coverArt}
            coverArtType="song"
            albumId={song.albumId}
            width="100%"
            height="100%"
            crossOrigin="anonymous"
            className="aspect-square object-cover w-full h-full bg-skeleton text-transparent"
            alt={song.title}
          />
        ) : (
          <div className="w-full h-full flex items-center justify-center bg-muted text-muted-foreground">
            <AudioLines className="size-4 md:size-5" />
          </div>
        )}
      </div>

      {/* Song details + status info */}
      <div className="flex flex-col justify-center min-w-0 flex-1 ml-0.5 text-left">
        <span className="text-xs md:text-sm font-semibold truncate text-foreground leading-tight">
          {song?.title || t("settings.crossDevice.playback.unknownTrack", { defaultValue: "Unknown track" })}
        </span>
        <span className="text-[10px] md:text-xs text-primary font-medium flex items-center gap-1 mt-0.5 truncate">
          <MonitorSpeaker className="w-3.5 h-3.5 flex-shrink-0 animate-pulse" />
          <span className="truncate">
            {t("settings.crossDevice.playback.controlling", {
              defaultValue: "Controlling {{device}}",
              device: deviceName || "Device",
            })}
          </span>
        </span>
      </div>

      {/* Exit Button */}
      <Button
        variant="outline"
        size="sm"
        onClick={onExit}
        className="h-7 px-2.5 text-[10px] md:text-xs font-semibold rounded-lg border-destructive/20 hover:bg-destructive/5 hover:text-destructive text-destructive transition-colors flex-shrink-0"
      >
        {t("generic.exit", { defaultValue: "Exit" })}
      </Button>
    </div>
  );
}
