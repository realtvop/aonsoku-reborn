import clsx from "clsx";
import { useMemo } from "react";
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
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { useLanControlClientStore } from "@/store/lanControlClient.store";
import { LanControlMessageType } from "@/types/lanControl";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";

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
    queue,
  } = useLanControlClientStore((state) => ({
    status: state.status,
    address: state.address,
    password: state.password,
    error: state.error,
    remoteDevice: state.remoteDevice,
    playerState: state.playerState,
    currentSong: state.currentSong,
    queue: state.queue,
  }));
  const actions = useLanControlClientStore((state) => state.actions);

  const isConnecting = status === "connecting" || status === "authenticating";
  const isConnected = status === "connected";

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

  const handleSend = (type: LanControlMessageType) => {
    if (!isConnected) return;
    actions.send({ type });
  };

  const handleRefreshState = () => {
    if (!isConnected) return;
    actions.send({ type: LanControlMessageType.GET_STATE });
    actions.send({ type: LanControlMessageType.GET_CURRENT_SONG });
    actions.send({ type: LanControlMessageType.GET_QUEUE });
  };

  const queueItems = queue?.songs ?? [];

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>{t("lanControl.remote.title")}</DialogTitle>
          <DialogDescription>
            {t("lanControl.remote.description")}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-6">
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
              <Button
                variant="ghost"
                onClick={handleRefreshState}
                disabled={!isConnected}
              >
                {t("lanControl.remote.actions.refresh")}
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
            <div className="grid gap-1">
              <span className="text-base font-medium">
                {currentSong?.title ?? t("lanControl.remote.emptyTitle")}
              </span>
              <span className="text-sm text-muted-foreground">
                {currentSong?.artist ?? t("lanControl.remote.emptyArtist")}
              </span>
              <span className="text-xs text-muted-foreground">
                {currentSong?.album ?? ""}
              </span>
            </div>
            {playerState && (
              <div className="flex items-center justify-between text-xs text-muted-foreground">
                <span>
                  {convertSecondsToTime(playerState.currentTime ?? 0)}
                </span>
                <span>{convertSecondsToTime(playerState.duration ?? 0)}</span>
              </div>
            )}

            <div className="grid gap-2 sm:grid-cols-3 md:grid-cols-6">
              <Button
                variant="secondary"
                onClick={() => handleSend(LanControlMessageType.PREVIOUS)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.previous")}
              </Button>
              <Button
                variant="default"
                onClick={() => handleSend(LanControlMessageType.PLAY)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.play")}
              </Button>
              <Button
                variant="outline"
                onClick={() => handleSend(LanControlMessageType.PAUSE)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.pause")}
              </Button>
              <Button
                variant="secondary"
                onClick={() => handleSend(LanControlMessageType.NEXT)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.next")}
              </Button>
              <Button
                variant="ghost"
                onClick={() => handleSend(LanControlMessageType.TOGGLE_SHUFFLE)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.shuffle")}
              </Button>
              <Button
                variant="ghost"
                onClick={() => handleSend(LanControlMessageType.TOGGLE_REPEAT)}
                disabled={!isConnected}
              >
                {t("lanControl.remote.controls.repeat")}
              </Button>
            </div>
          </section>

          <section className="grid gap-3 rounded-lg border border-border/60 bg-muted/40 p-4">
            <header className="flex items-center justify-between">
              <h3 className="font-semibold text-sm">
                {t("lanControl.remote.queue")}
              </h3>
              <span className="text-xs text-muted-foreground">
                {queueItems.length} {t("lanControl.remote.items")}
              </span>
            </header>
            <ScrollArea className="max-h-56">
              <ul className="space-y-2">
                {queueItems.length === 0 && (
                  <li className="text-sm text-muted-foreground">
                    {t("lanControl.remote.queueEmpty")}
                  </li>
                )}
                {queueItems.map((song, index) => (
                  <li
                    key={`${song.id}-${index}`}
                    className={clsx(
                      "rounded-md border border-transparent bg-background/40 px-3 py-2 text-sm shadow-sm",
                      queue?.currentIndex === index &&
                        "border-primary/50 bg-primary/10 text-primary",
                    )}
                  >
                    <div className="font-medium">{song.title}</div>
                    <div className="text-xs text-muted-foreground">
                      {song.artist}
                    </div>
                    <div className="text-xs text-muted-foreground">
                      {convertSecondsToTime(song.duration ?? 0)}
                    </div>
                  </li>
                ))}
              </ul>
            </ScrollArea>
          </section>
        </div>
      </DialogContent>
    </Dialog>
  );
}
