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
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";
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
}

export function DevicePlaybackCard({
  model,
  onControl,
  onContinue,
  isOffline = false,
}: DevicePlaybackCardProps) {
  const { t } = useTranslation();
  const { device, snapshot, isOnline, projectedProgressSeconds, durationSeconds, lastSeenText } = model;
  const { data: song, isLoading } = useSongInfo(snapshot?.songId);

  const progressPercent = durationSeconds > 0
    ? (projectedProgressSeconds / durationSeconds) * 100
    : 0;

  return (
    <div
      className={cn(
        "group relative flex flex-col gap-3 p-4 rounded-xl border transition-all duration-300",
        "bg-card/30 backdrop-blur-md border-border/40 hover:border-border/80 hover:bg-card/50 shadow-sm"
      )}
    >
      {/* Top row: Device Info & Status Indicator */}
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <div className="flex items-center gap-1.5 font-medium text-foreground/80">
          {getDeviceIcon(device.platform)}
          <span className="truncate max-w-[150px]">{device.name}</span>
        </div>
        <div className="flex items-center gap-1.5">
          {isOnline ? (
            <span className="flex items-center gap-1">
              <span className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                <span className="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
              </span>
              <span className="text-[10px] text-emerald-500 uppercase tracking-wider font-semibold">
                {t("settings.crossDevice.connectionState.connected", { defaultValue: "Online" })}
              </span>
            </span>
          ) : (
            <span className="text-[10px] uppercase tracking-wider font-medium text-muted-foreground/70">
              {lastSeenText ? t("settings.crossDevice.device.lastOnline", { defaultValue: "Last online {{time}}", time: lastSeenText }) : t("settings.crossDevice.connectionState.disconnected", { defaultValue: "Offline" })}
            </span>
          )}
        </div>
      </div>

      {/* Middle row: Album Art & Track details */}
      <div className="flex items-center gap-3">
        <div className="relative w-12 h-12 rounded-lg overflow-hidden aspect-square bg-muted flex-shrink-0 shadow-sm border border-border/20">
          {song ? (
            <CachedImage
              coverArtId={song.coverArt}
              coverArtType="song"
              albumId={song.albumId}
              width="100%"
              height="100%"
              className="w-full h-full object-cover"
              alt={song.title}
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

          {/* Playing overlay indicator */}
          {snapshot?.isPlaying && isOnline && (
            <div className="absolute inset-0 bg-black/40 flex items-center justify-center backdrop-blur-[1px]">
              <div className="flex items-end gap-0.5 h-3">
                <span className="w-0.5 bg-primary animate-[bounce_0.8s_infinite_100ms]"></span>
                <span className="w-0.5 bg-primary animate-[bounce_0.8s_infinite_300ms] h-2"></span>
                <span className="w-0.5 bg-primary animate-[bounce_0.8s_infinite_200ms] h-1.5"></span>
              </div>
            </div>
          )}
        </div>

        <div className="flex flex-col min-w-0 flex-1">
          <span className="text-sm font-semibold truncate text-foreground leading-tight">
            {isLoading
              ? t("settings.crossDevice.playback.fetchingSong", { defaultValue: "Fetching song..." })
              : song?.title || t("settings.crossDevice.playback.unknownTrack", { defaultValue: "Unknown track" })}
          </span>
          <span className="text-xs text-muted-foreground truncate leading-normal mt-0.5">
            {song?.artist || t("settings.crossDevice.playback.unknownArtist", { defaultValue: "Unknown artist" })}
          </span>
        </div>
      </div>

      {/* Progress timeline */}
      {snapshot && durationSeconds > 0 && (
        <div className="flex flex-col gap-1 w-full mt-1">
          <div className="relative w-full h-1 bg-muted/60 rounded-full overflow-hidden">
            <div
              className="absolute left-0 top-0 h-full bg-primary/80 transition-all duration-300 rounded-full"
              style={{ width: `${progressPercent}%` }}
            />
          </div>
          <div className="flex items-center justify-between text-[10px] text-muted-foreground/80 font-mono">
            <span>{convertSecondsToTime(projectedProgressSeconds)}</span>
            <span>{convertSecondsToTime(durationSeconds)}</span>
          </div>
        </div>
      )}

      {/* Bottom row: Primary action buttons */}
      <div className="flex items-center gap-2 mt-1">
        {!isOffline && onControl && (
          <Button
            variant="outline"
            size="sm"
            onClick={onControl}
            className="flex-1 h-8 text-xs gap-1.5 font-medium border-border/60 hover:bg-accent/40 active:bg-accent/60 transition-all"
          >
            <MousePointerClick className="w-3.5 h-3.5 text-muted-foreground group-hover:text-foreground transition-colors" />
            {t("settings.crossDevice.playback.remoteControl", { defaultValue: "Control" })}
          </Button>
        )}
        {onContinue && (
          <Button
            variant="secondary"
            size="sm"
            onClick={onContinue}
            className="flex-1 h-8 text-xs gap-1.5 font-semibold bg-primary/10 text-primary hover:bg-primary/20 active:bg-primary/30 border border-primary/20 transition-all"
          >
            <ArrowRightLeft className="w-3.5 h-3.5" />
            {isOffline
              ? t("settings.crossDevice.playback.continue", { defaultValue: "Continue" })
              : t("settings.crossDevice.playback.relay", { defaultValue: "Continue here" })}
          </Button>
        )}
      </div>
    </div>
  );
}
