import { useQuery } from "@tanstack/react-query";
import {
  Laptop,
  Smartphone,
  Tv,
  Cast,
  Loader2,
  Radio,
  MousePointerClick,
  ArrowRightLeft,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { Button } from "@/app/components/ui/button";
import { subsonic } from "@/service/subsonic";
import { useCoordinationStore } from "@/coordination/store";
import {
  usePlayerCurrentSong,
  usePlayerMediaType,
  usePlayerSonglist,
} from "@/store/player.store";
import type { DevicePlaybackModel } from "./types";
import { cn } from "@/lib/utils";

function useSongInfo(songId: string | undefined) {
  return useQuery({
    queryKey: ["song-info", songId],
    queryFn: async () => {
      if (!songId) return null;
      return subsonic.songs.getSong(songId);
    },
    enabled: !!songId,
    staleTime: Infinity,
  });
}

function getDeviceIcon(platform: string) {
  const p = platform.toLowerCase();
  if (
    p.includes("ios") ||
    p.includes("android") ||
    p.includes("phone") ||
    p.includes("mobile")
  ) {
    return <Smartphone className="w-4 h-4" />;
  }
  if (
    p.includes("electron") ||
    p.includes("desktop") ||
    p.includes("mac") ||
    p.includes("windows") ||
    p.includes("linux")
  ) {
    return <Laptop className="w-4 h-4" />;
  }
  if (p.includes("tv")) {
    return <Tv className="w-4 h-4" />;
  }
  return <Cast className="w-4 h-4" />;
}

interface DevicePlaybackCardProps {
  model: DevicePlaybackModel;
  onControl?: () => void;
  onContinue?: () => void;
  isOffline?: boolean;
  isActive?: boolean;
}

export function DevicePlaybackCard({
  model,
  onControl,
  onContinue,
  isOffline = false,
  isActive = false,
}: DevicePlaybackCardProps) {
  const { t } = useTranslation();
  const { device, snapshot } = model;

  const currentDeviceId = useCoordinationStore((state) => state.deviceId);
  const isSelf = device.id === currentDeviceId;

  // Local song hooks
  const localSong = usePlayerCurrentSong();
  const { isSong: localIsSong, isRadio: localIsRadio } = usePlayerMediaType();
  const { currentSongIndex, radioList } = usePlayerSonglist();
  const localRadio = radioList[currentSongIndex];

  // Remote song query
  const { data: remoteSong, isLoading: isRemoteLoading } = useSongInfo(
    !isSelf ? snapshot?.songId : undefined,
  );

  // Resolved values based on local vs remote
  const isLoading = !isSelf ? isRemoteLoading : false;

  let songTitle = "";
  let coverArt = "";
  let coverArtType: "song" | "album" = "song";
  let albumId = "";

  if (isSelf) {
    if (localIsSong && localSong) {
      songTitle = localSong.title;
      coverArt = localSong.coverArt;
      coverArtType = "song";
      albumId = localSong.albumId;
    } else if (localIsRadio && localRadio) {
      songTitle = localRadio.name;
      coverArt = "";
    }
  } else {
    if (remoteSong) {
      songTitle = remoteSong.title;
      coverArt = remoteSong.coverArt;
      coverArtType = "song";
      albumId = remoteSong.albumId;
    }
  }

  return (
    <div
      className={cn(
        "bg-card/40 backdrop-blur-md border rounded-xl p-3 flex items-center justify-between gap-4 transition-all duration-300",
        isActive
          ? "border-primary/50 bg-primary/5"
          : "border-border/40 hover:border-border/80 hover:bg-card/50 shadow-sm",
      )}
    >
      {/* Track Info & Device Info (Left) */}
      <div className="flex items-center gap-3 min-w-0 flex-1">
        <div className="relative w-12 h-12 rounded-lg overflow-hidden aspect-square bg-muted flex-shrink-0 shadow-sm border border-border/20">
          {coverArt ? (
            <CachedImage
              coverArtId={coverArt}
              coverArtType={coverArtType}
              albumId={albumId}
              width="100%"
              height="100%"
              className="w-full h-full object-cover"
              alt={songTitle}
            />
          ) : (
            <div className="w-full h-full flex items-center justify-center bg-muted text-muted-foreground">
              {isLoading ? (
                <Loader2 className="w-4 h-4 animate-spin text-primary" />
              ) : (
                <Radio className="w-5 h-5 text-muted-foreground/60" />
              )}
            </div>
          )}
        </div>

        <div className="flex flex-col min-w-0 text-left">
          <span className="text-sm font-semibold truncate text-foreground leading-tight">
            {isLoading
              ? t("settings.crossDevice.playback.fetchingSong", {
                  defaultValue: "Fetching song...",
                })
              : songTitle ||
                t("settings.crossDevice.playback.unknownTrack", {
                  defaultValue: "Unknown track",
                })}
          </span>
          <span className="text-xs text-muted-foreground truncate leading-normal mt-1 flex items-center gap-1.5">
            <span className="flex items-center gap-1 font-medium text-foreground/80">
              {getDeviceIcon(device.platform)}
              {device.name}
            </span>
          </span>
        </div>
      </div>

      {/* Action Buttons (Right) */}
      <div className="flex items-center gap-1 flex-shrink-0">
        {!isOffline && (onControl || isActive) && (
          <Button
            variant={isActive ? "default" : "ghost"}
            size="icon"
            onClick={onControl}
            className={cn(
              "h-9 w-9 rounded-lg transition-all",
              isActive
                ? "text-primary-foreground bg-primary hover:bg-primary/90"
                : "text-muted-foreground hover:text-foreground hover:bg-accent/50",
              isActive && !onControl && "pointer-events-none",
            )}
            title={t("settings.crossDevice.playback.remoteControl", {
              defaultValue: "Control",
            })}
          >
            <MousePointerClick className="w-4.5 h-4.5" />
          </Button>
        )}
        {onContinue && (
          <Button
            variant="ghost"
            size="icon"
            onClick={onContinue}
            className="h-9 w-9 rounded-lg hover:bg-accent/50 text-muted-foreground hover:text-foreground transition-all"
            title={
              isOffline
                ? t("settings.crossDevice.playback.continue", {
                    defaultValue: "Continue",
                  })
                : t("settings.crossDevice.playback.relay", {
                    defaultValue: "Continue here",
                  })
            }
          >
            <ArrowRightLeft className="w-4.5 h-4.5" />
          </Button>
        )}
      </div>
    </div>
  );
}
