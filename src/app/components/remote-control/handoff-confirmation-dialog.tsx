import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { ArrowDown, Radio } from "lucide-react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/app/components/ui/alert-dialog";
import { subsonic } from "@/service/subsonic";
import { usePlayerCurrentSong, usePlayerMediaType, usePlayerSonglist } from "@/store/player.store";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import type { DevicePlaybackModel } from "./types";

interface HandoffConfirmationDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  pendingDevice: DevicePlaybackModel | null;
  onConfirm: () => void;
  onCancel: () => void;
}

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

export function HandoffConfirmationDialog({
  open,
  onOpenChange,
  pendingDevice,
  onConfirm,
  onCancel,
}: HandoffConfirmationDialogProps) {
  const { t } = useTranslation();

  // Local song hooks
  const localSong = usePlayerCurrentSong();
  const { isSong: localIsSong, isRadio: localIsRadio } = usePlayerMediaType();
  const { currentSongIndex, radioList } = usePlayerSonglist();
  const localRadio = radioList[currentSongIndex];

  // Target song info
  const targetSongId = pendingDevice?.snapshot?.songId;
  const { data: targetSong, isLoading: targetLoading } = useSongInfo(targetSongId);

  // local details
  let localTitle = t("player.noSongPlaying", { defaultValue: "No song playing" });
  let localArtist = "";
  let localCover = "";
  let localAlbumId = "";

  if (localIsSong && localSong) {
    localTitle = localSong.title;
    localArtist = localSong.artist;
    localCover = localSong.coverArt;
    localAlbumId = localSong.albumId;
  } else if (localIsRadio && localRadio) {
    localTitle = localRadio.name;
    localArtist = t("radios.label", { defaultValue: "Radio" });
  }

  // target details
  const targetTitle = targetLoading
    ? t("settings.crossDevice.playback.fetchingSong", { defaultValue: "Fetching song..." })
    : targetSong?.title || t("settings.crossDevice.playback.unknownTrack", { defaultValue: "Unknown track" });
  const targetArtist = targetSong?.artist || "";
  const targetCover = targetSong?.coverArt || "";
  const targetAlbumId = targetSong?.albumId || "";
  const targetProgress = pendingDevice?.snapshot?.progressSeconds ?? 0;

  return (
    <AlertDialog
      open={open}
      onOpenChange={onOpenChange}
      backButtonPriority={20}
    >
      <AlertDialogContent className="max-w-md p-6 rounded-2xl border border-border/40 bg-background/95 backdrop-blur-xl shadow-2xl">
        <AlertDialogHeader className="text-left gap-1">
          <AlertDialogTitle className="text-base font-bold text-foreground">
            {t("settings.crossDevice.playback.continueConfirmTitle", {
              defaultValue: "Continue playback here?",
            })}
          </AlertDialogTitle>
          <AlertDialogDescription className="text-xs text-muted-foreground">
            {t("settings.crossDevice.playback.continueConfirmDesc", {
              defaultValue: "This will replace the active local playback on this device.",
            })}
          </AlertDialogDescription>
        </AlertDialogHeader>

        {/* Local Playing Info */}
        <div className="flex flex-col gap-4 my-4">
          <div className="rounded-xl border border-border/20 p-3 bg-muted/30 flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg overflow-hidden aspect-square bg-muted flex-shrink-0 border border-border/20">
              {localCover ? (
                <CachedImage
                  coverArtId={localCover}
                  coverArtType="song"
                  albumId={localAlbumId}
                  width="100%"
                  height="100%"
                  className="w-full h-full object-cover"
                  alt={localTitle}
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center bg-muted text-muted-foreground">
                  <Radio className="w-4 h-4 text-muted-foreground/60" />
                </div>
              )}
            </div>
            <div className="flex flex-col min-w-0 text-left">
              <span className="text-[10px] font-bold text-muted-foreground uppercase tracking-wider">
                {t("settings.crossDevice.playback.currentLocal", { defaultValue: "Current on this device" })}
              </span>
              <span className="text-xs font-semibold truncate text-foreground leading-snug mt-0.5">
                {localTitle}
              </span>
              {localArtist && (
                <span className="text-[10px] text-muted-foreground truncate leading-normal">
                  {localArtist}
                </span>
              )}
            </div>
          </div>

          <div className="flex justify-center text-muted-foreground/40 -my-1">
            <ArrowDown className="w-4 h-4" />
          </div>

          {/* Target Playing Info */}
          <div className="rounded-xl border border-primary/20 p-3 bg-primary/5 flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg overflow-hidden aspect-square bg-muted flex-shrink-0 border border-border/20">
              {targetCover ? (
                <CachedImage
                  coverArtId={targetCover}
                  coverArtType="song"
                  albumId={targetAlbumId}
                  width="100%"
                  height="100%"
                  className="w-full h-full object-cover"
                  alt={targetTitle}
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center bg-muted text-muted-foreground">
                  <Radio className="w-4 h-4 text-muted-foreground/60" />
                </div>
              )}
            </div>
            <div className="flex flex-col min-w-0 text-left flex-1">
              <span className="text-[10px] font-bold text-primary uppercase tracking-wider">
                {t("settings.crossDevice.playback.willContinue", {
                  defaultValue: `Will continue from ${pendingDevice?.device.name || "peer device"}`,
                })}
              </span>
              <span className="text-xs font-semibold truncate text-foreground leading-snug mt-0.5">
                {targetTitle}
              </span>
              <span className="text-[10px] text-muted-foreground truncate leading-normal flex items-center justify-between">
                <span>{targetArtist}</span>
                {targetProgress > 0 && (
                  <span className="font-mono text-primary font-medium">
                    {convertSecondsToTime(targetProgress)}
                  </span>
                )}
              </span>
            </div>
          </div>
        </div>

        <AlertDialogFooter className="gap-2 sm:gap-0">
          <AlertDialogCancel onClick={onCancel} className="h-9 text-xs rounded-xl font-semibold border-border/60 hover:bg-accent/40">
            {t("generic.cancel", { defaultValue: "Cancel" })}
          </AlertDialogCancel>
          <AlertDialogAction onClick={onConfirm} className="h-9 text-xs rounded-xl font-semibold bg-primary hover:bg-primary/95 text-primary-foreground shadow-sm">
            {t("settings.crossDevice.playback.relay", { defaultValue: "Continue here" })}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
