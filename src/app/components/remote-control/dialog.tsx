import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/app/components/ui/dialog";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { Label } from "@/app/components/ui/label";
import { Badge } from "@/app/components/ui/badge";
import { useLanControlClientStore } from "@/store/lanControlClient.store";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";
import { subsonic } from "@/service/subsonic";
import { ISong } from "@/types/responses/song";
import { getCoverArtUrl } from "@/api/httpClient";

interface RemoteControlDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function RemoteControlDialog({
  open,
  onOpenChange,
}: RemoteControlDialogProps) {
  const { t } = useTranslation();
  const {
    status,
    address,
    password,
    error,
    remoteDevice,
    playerState,
    currentSong,
  } = useLanControlClientStore((state) => ({
    status: state.status,
    address: state.address,
    password: state.password,
    error: state.error,
    remoteDevice: state.remoteDevice,
    playerState: state.playerState,
    currentSong: state.currentSong,
  }));
  const actions = useLanControlClientStore((state) => state.actions);

  const [fullSongInfo, setFullSongInfo] = useState<ISong | null>(null);
  const [isLoadingSong, setIsLoadingSong] = useState(false);

  const isConnecting = status === "connecting" || status === "authenticating";
  const isConnected = status === "connected";

  // Fetch full song information when currentSong changes
  useEffect(() => {
    if (!currentSong?.id) {
      setFullSongInfo(null);
      return;
    }

    const fetchSongInfo = async () => {
      setIsLoadingSong(true);
      try {
        const song = await subsonic.songs.getSong(currentSong.id);
        if (song) {
          setFullSongInfo(song);
        }
      } catch (error) {
        console.error("Failed to fetch song info:", error);
      } finally {
        setIsLoadingSong(false);
      }
    };

    fetchSongInfo();
  }, [currentSong?.id]);

  const statusLabel = useMemo(() => {
    switch (status) {
      case "connected":
        return t("lanControl.remote.status.connected");
      case "connecting":
        return t("lanControl.remote.status.connecting");
      case "authenticating":
        return t("lanControl.remote.status.authenticating");
      case "error":
        return t("lanControl.remote.status.error");
      default:
        return t("lanControl.remote.status.disconnected");
    }
  }, [status, t]);

  const handleConnect = () => {
    actions.clearError();
    actions.connect();
  };

  const handleDisconnect = () => {
    actions.disconnect();
  };

  const displayTitle =
    fullSongInfo?.title ||
    currentSong?.title ||
    t("lanControl.remote.emptyTitle");
  const displayArtist =
    fullSongInfo?.artist ||
    currentSong?.artist ||
    t("lanControl.remote.emptyArtist");
  const displayAlbum = fullSongInfo?.album || currentSong?.album || "";
  const coverArtUrl = fullSongInfo?.coverArt
    ? getCoverArtUrl(fullSongInfo.coverArt)
    : null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t("lanControl.remote.title")}</DialogTitle>
          <DialogDescription>
            {t("lanControl.remote.description")}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-6 mt-6">
          <section className="grid gap-4 sm:grid-cols-[1fr_auto] sm:items-end">
            <div className="grid gap-4">
              <div className="grid gap-2">
                <Label htmlFor="remote-address">
                  {t("lanControl.remote.address")}
                </Label>
                <Input
                  id="remote-address"
                  value={address}
                  placeholder="ws://host:5299"
                  onChange={(event) => actions.setAddress(event.target.value)}
                  disabled={isConnecting}
                  spellCheck={false}
                  autoComplete="off"
                />
              </div>
              <div className="grid gap-2 sm:grid-cols-2 sm:items-center">
                <div className="grid gap-2">
                  <Label htmlFor="remote-password">
                    {t("lanControl.remote.password")}
                  </Label>
                  <Input
                    id="remote-password"
                    value={password}
                    maxLength={6}
                    placeholder="ABC123"
                    onChange={(event) =>
                      actions.setPassword(event.target.value)
                    }
                    disabled={isConnecting}
                    autoComplete="off"
                  />
                </div>
                <div className="flex flex-col gap-2 sm:items-end">
                  <Label className="text-xs uppercase tracking-wide">
                    {t("lanControl.remote.status.label")}
                  </Label>
                  <Badge
                    variant={
                      isConnected
                        ? "default"
                        : status === "error"
                        ? "destructive"
                        : "secondary"
                    }
                    className="capitalize"
                  >
                    {statusLabel}
                  </Badge>
                </div>
              </div>
              {remoteDevice && isConnected && (
                <div className="rounded-md border border-border/60 bg-muted/40 px-4 py-3 text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">
                    {remoteDevice.name ?? t("lanControl.remote.unknownDevice")}
                  </span>
                  {remoteDevice.version && (
                    <span className="ml-2 text-xs">
                      {t("lanControl.remote.version", {
                        version: remoteDevice.version,
                      })}
                    </span>
                  )}
                </div>
              )}
              {error && (
                <div className="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
                  {error}
                </div>
              )}
            </div>

            <div className="flex gap-2 sm:flex-col">
              <Button
                variant="default"
                onClick={handleConnect}
                disabled={isConnecting}
              >
                {isConnecting
                  ? t("lanControl.remote.actions.connecting")
                  : t("lanControl.remote.actions.connect")}
              </Button>
              <Button
                variant="outline"
                onClick={handleDisconnect}
                disabled={!isConnected && status !== "error"}
              >
                {t("lanControl.remote.actions.disconnect")}
              </Button>
            </div>
          </section>

          <section className="grid gap-4 rounded-lg border border-border/60 bg-muted/40 p-4">
            <header className="flex items-center justify-between">
              <h3 className="font-semibold text-sm">
                {t("lanControl.remote.nowPlaying")}
              </h3>
              {playerState && (
                <div className="text-xs text-muted-foreground">
                  {t("lanControl.remote.volume", {
                    volume: playerState.volume,
                  })}
                </div>
              )}
            </header>
            <div className="flex gap-3">
              {coverArtUrl && (
                <div className="shrink-0">
                  <img
                    src={coverArtUrl}
                    alt={displayTitle}
                    className="h-20 w-20 rounded object-cover"
                  />
                </div>
              )}
              <div className="grid gap-1 flex-1 min-w-0">
                <span className="text-base font-medium truncate">
                  {isLoadingSong ? (
                    <span className="text-muted-foreground">
                      {t("lanControl.remote.loadingSong")}
                    </span>
                  ) : (
                    displayTitle
                  )}
                </span>
                <span className="text-sm text-muted-foreground truncate">
                  {displayArtist}
                </span>
                {displayAlbum && (
                  <span className="text-xs text-muted-foreground truncate">
                    {displayAlbum}
                  </span>
                )}
              </div>
            </div>
            {playerState && (
              <div className="flex items-center justify-between text-xs text-muted-foreground">
                <span>
                  {convertSecondsToTime(playerState.currentTime ?? 0)}
                </span>
                <span>{convertSecondsToTime(playerState.duration ?? 0)}</span>
              </div>
            )}
          </section>
        </div>
      </DialogContent>
    </Dialog>
  );
}
