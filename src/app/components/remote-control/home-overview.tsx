import { useTranslation } from "react-i18next";
import {
  MonitorSpeaker,
  Laptop,
  Smartphone,
  Tv,
  Cast,
  ArrowRight,
  Radio,
} from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { subsonic } from "@/service/subsonic";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { useDevicePlaybackModels } from "./use-device-playback-models";
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
    return <Smartphone className="w-3.5 h-3.5" />;
  }
  if (
    p.includes("electron") ||
    p.includes("desktop") ||
    p.includes("mac") ||
    p.includes("windows") ||
    p.includes("linux")
  ) {
    return <Laptop className="w-3.5 h-3.5" />;
  }
  if (p.includes("tv")) {
    return <Tv className="w-3.5 h-3.5" />;
  }
  return <Cast className="w-3.5 h-3.5" />;
}

export function HomeDevicePlaybackOverview() {
  const { t } = useTranslation();
  const { liveDevices, offlineSnapshots } = useDevicePlaybackModels();

  const allDevices = [...liveDevices, ...offlineSnapshots];

  if (allDevices.length === 0) return null;

  const handleOpenPanel = () => {
    window.dispatchEvent(new CustomEvent("open-device-panel"));
  };

  return (
    <div className="flex flex-col gap-3 mb-6 w-full animate-in fade-in duration-300">
      <div className="flex items-center justify-between px-1">
        <div className="flex items-center gap-2">
          <MonitorSpeaker className="w-4 h-4 text-primary" />
          <h3 className="text-xs font-bold text-muted-foreground uppercase tracking-wider">
            {t("settings.crossDevice.playback.otherDevices", {
              defaultValue: "Other devices playing",
            })}
          </h3>
        </div>
        <button
          type="button"
          onClick={handleOpenPanel}
          className="text-xs text-primary hover:text-primary/80 font-semibold flex items-center gap-1 transition-colors group"
        >
          {t("settings.crossDevice.playback.showDevices", {
            defaultValue: "Show Devices",
          })}
          <ArrowRight className="w-3 h-3 transition-transform group-hover:translate-x-0.5" />
        </button>
      </div>

      <div className="grid gap-2.5 sm:grid-cols-2 lg:grid-cols-3">
        {allDevices.map((model) => (
          <OverviewCard
            key={model.device.id}
            model={model}
            onClick={handleOpenPanel}
          />
        ))}
      </div>
    </div>
  );
}

interface OverviewCardProps {
  model: DevicePlaybackModel;
  onClick: () => void;
}

function OverviewCard({ model, onClick }: OverviewCardProps) {
  const { t } = useTranslation();
  const { device, snapshot, isOnline, lastSeenText } = model;

  const { data: song, isLoading } = useSongInfo(snapshot?.songId);

  return (
    <div
      onClick={onClick}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => e.key === "Enter" && onClick()}
      className="bg-card/40 hover:bg-card/60 backdrop-blur-md border border-border/40 hover:border-border/80 rounded-xl p-3 flex items-center justify-between gap-3 transition-all duration-300 cursor-pointer shadow-sm text-left group"
    >
      <div className="flex items-center gap-3 min-w-0 flex-1">
        {/* Cover Art */}
        <div className="relative w-10 h-10 rounded-lg overflow-hidden aspect-square bg-muted flex-shrink-0 border border-border/20 shadow-sm">
          {song?.coverArt ? (
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
                <Radio className="w-4 h-4 animate-pulse" />
              ) : (
                <Radio className="w-4 h-4" />
              )}
            </div>
          )}
        </div>

        {/* Track Title, Device Name */}
        <div className="flex flex-col min-w-0">
          <span className="text-xs font-semibold truncate text-foreground leading-tight">
            {isLoading
              ? t("settings.crossDevice.playback.fetchingSong", {
                  defaultValue: "Fetching song...",
                })
              : song?.title ||
                t("settings.crossDevice.playback.unknownTrack", {
                  defaultValue: "Unknown track",
                })}
          </span>
          <span className="text-[10px] text-muted-foreground truncate leading-normal mt-0.5 flex items-center gap-1">
            <span className="flex items-center gap-1 font-semibold text-foreground/80">
              {getDeviceIcon(device.platform)}
              {device.name}
            </span>
            <span>·</span>
            <span
              className={cn(
                "font-medium",
                isOnline ? "text-primary" : "text-muted-foreground",
              )}
            >
              {isOnline
                ? t("settings.crossDevice.connectionState.connected", {
                    defaultValue: "Online",
                  })
                : lastSeenText ||
                  t("settings.crossDevice.never", { defaultValue: "Offline" })}
            </span>
          </span>
        </div>
      </div>

      <div className="text-muted-foreground/30 group-hover:text-muted-foreground/60 transition-colors flex-shrink-0">
        <ArrowRight className="w-4 h-4" />
      </div>
    </div>
  );
}
