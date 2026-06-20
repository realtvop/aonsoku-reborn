import { useState, useEffect } from "react";
import { toast } from "react-toastify";
import { Smartphone, Laptop, Tv, Cast, ArrowRightLeft, Loader2, Radio } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { useCoordinationStore } from "@/coordination/store";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { subsonic } from "@/service/subsonic";
import type { DeviceDto, PlaybackSnapshot } from "@/coordination/types";
import { LanControlMessageType } from "@/types/lanControl";
import type { RemoteCommand } from "@/coordination/types";
import { Button } from "@/app/components/ui/button";

function mapLanControlToRemoteCommand(
  type: LanControlMessageType,
  data?: unknown,
): RemoteCommand | null {
  // biome-ignore lint/suspicious/noExplicitAny: data carries untyped dynamic parameters for controls
  const d = data as any;
  switch (type) {
    case LanControlMessageType.PLAY:
      return { type: "play" };
    case LanControlMessageType.PAUSE:
      return { type: "pause" };
    case LanControlMessageType.PLAY_PAUSE:
      return { type: "toggle_play_pause" };
    case LanControlMessageType.PREVIOUS:
      return { type: "previous" };
    case LanControlMessageType.NEXT:
      return { type: "next" };
    case LanControlMessageType.SEEK:
      return typeof d?.seconds === "number"
        ? { type: "seek", seconds: d.seconds }
        : null;
    case LanControlMessageType.SET_VOLUME:
      return typeof d?.volume === "number"
        ? { type: "set_volume", volume: d.volume / 100 }
        : null;
    case LanControlMessageType.PLAY_SONG:
      return typeof d?.songId === "string"
        ? { type: "play_song", songId: d.songId }
        : null;
    case LanControlMessageType.PLAY_ALBUM:
      return typeof d?.albumId === "string"
        ? { type: "play_album", albumId: d.albumId, index: d.songIndex }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST:
      return typeof d?.playlistId === "string"
        ? { type: "play_playlist", playlistId: d.playlistId, index: d.songIndex }
        : null;
    case LanControlMessageType.PLAY_ALBUM_SHUFFLE:
      return typeof d?.albumId === "string"
        ? { type: "play_album", albumId: d.albumId }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST_SHUFFLE:
      return typeof d?.playlistId === "string"
        ? { type: "play_playlist", playlistId: d.playlistId }
        : null;
    case LanControlMessageType.ADD_TO_QUEUE:
      return Array.isArray(d?.songIds)
        ? { type: "add_to_queue_last", songIds: d.songIds }
        : null;
    case LanControlMessageType.CLEAR_QUEUE:
      return { type: "clear_queue" };
    case LanControlMessageType.TOGGLE_SHUFFLE:
      return { type: "set_shuffle", enabled: !usePlayerStore.getState().songlist.isShuffleActive };
    case LanControlMessageType.SET_SHUFFLE:
      return typeof d?.enabled === "boolean"
        ? { type: "set_shuffle", enabled: d.enabled }
        : null;
    case LanControlMessageType.SET_REPEAT:
      return typeof d?.mode === "string"
        ? { type: "set_repeat", mode: d.mode }
        : null;
    default:
      return null;
  }
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

function getDeviceIcon(platform: string) {
  const p = platform.toLowerCase();
  if (p.includes("ios") || p.includes("android") || p.includes("phone") || p.includes("mobile")) {
    return <Smartphone className="w-3.5 h-3.5" />;
  }
  if (p.includes("electron") || p.includes("desktop") || p.includes("mac") || p.includes("windows") || p.includes("linux")) {
    return <Laptop className="w-3.5 h-3.5" />;
  }
  if (p.includes("tv")) {
    return <Tv className="w-3.5 h-3.5" />;
  }
  return <Cast className="w-3.5 h-3.5" />;
}

function DevicePlaybackCard({
  device,
  snapshotData,
}: {
  device: DeviceDto;
  snapshotData: {
    snapshot: PlaybackSnapshot;
    isOnline: boolean;
    generation: number;
    snapshotRevision: number;
  };
}) {
  const coordStore = useCoordinationStore();
  const playerActions = usePlayerActions();
  const controlledDeviceId = useCoordinationStore((state) => state.controlledDeviceId);
  const isControlling = controlledDeviceId === device.id;
  const [isRelaying, setIsRelaying] = useState(false);

  const { data: song, isLoading } = useSongInfo(snapshotData.snapshot.songId);

  // Monitor relay/handoff status
  useEffect(() => {
    if (!isRelaying) return;
    const originalCommitted = coordStore.manager.callbacks.onHandoffCommitted;
    const originalFailed = coordStore.manager.callbacks.onHandoffFailed;

    coordStore.manager.callbacks.onHandoffCommitted = (snapshot, newGeneration) => {
      originalCommitted(snapshot, newGeneration);
      setIsRelaying(false);
      toast.success("接力成功！");
    };

    coordStore.manager.callbacks.onHandoffFailed = (transactionId, code) => {
      originalFailed(transactionId, code);
      setIsRelaying(false);
    };

    return () => {
      coordStore.manager.callbacks.onHandoffCommitted = originalCommitted;
      coordStore.manager.callbacks.onHandoffFailed = originalFailed;
    };
  }, [isRelaying, coordStore.manager]);

  const handleRemoteControl = () => {
    if (isControlling) {
      // Disconnect Remote Control
      usePlayerStore.setState({
        remoteControl: {
          active: false,
          device: null,
          sendCommand: null,
        },
      });
      coordStore.setControlledDevice(null);
      toast.info("已退出远程控制");
    } else {
      // Pause local playback
      playerActions.setPlayingState(false);

      // Connect Remote Control
      usePlayerStore.setState({
        remoteControl: {
          active: true,
          device: { name: device.name, version: device.clientVersion ?? "" },
          sendCommand: (type, data) => {
            const command = mapLanControlToRemoteCommand(type, data);
            if (command) {
              const state = useCoordinationStore.getState();
              const snap = state.deviceSnapshots[device.id];
              if (snap) {
                state.manager.sendCommand(device.id, snap.generation, command);
              }
            }
          },
        },
      });
      coordStore.setControlledDevice(device.id);
      toast.success(`正在远程控制: ${device.name}`);
    }
  };

  const handleRelay = () => {
    setIsRelaying(true);
    coordStore.manager.requestHandoffCandidate(
      device.id,
      snapshotData.generation,
      snapshotData.snapshotRevision,
    );
    toast.info("正在准备接力...");
    // Safety timeout to clear loading state in case of connection drop
    setTimeout(() => {
      setIsRelaying(false);
    }, 15000);
  };

  return (
    <div
      className={cn(
        "bg-card/40 backdrop-blur border rounded-xl p-3 flex items-center justify-between shadow-md gap-4 transition-all duration-300",
        isControlling ? "border-primary/50 bg-primary/5" : "border-border/50 hover:bg-card/60"
      )}
    >
      {/* Track Info (Left) */}
      <div className="flex items-center gap-3 min-w-0 flex-1">
        <div className="w-12 h-12 rounded overflow-hidden aspect-square bg-muted flex-shrink-0 relative shadow-sm">
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
                <Radio className="w-4 h-4" />
              )}
            </div>
          )}
        </div>

        <div className="flex flex-col min-w-0">
          <span className="text-sm font-semibold truncate text-foreground">
            {isLoading ? "正在获取歌曲..." : song?.title || "未知曲目"}
          </span>
          <div className="text-xs text-muted-foreground flex items-center gap-1.5 mt-0.5">
            <span className="flex items-center gap-1 font-medium text-foreground/80">
              {getDeviceIcon(device.platform)}
              {device.name}
            </span>
            <span>·</span>
            <span className="flex items-center gap-1">
              <span
                className={cn(
                  "w-1.5 h-1.5 rounded-full",
                  snapshotData.isOnline ? "bg-green-500" : "bg-neutral-400"
                )}
              />
              {snapshotData.isOnline ? "在线" : "离线"}
            </span>
          </div>
        </div>
      </div>

      {/* Buttons (Right) */}
      <div className="flex items-center gap-2 flex-shrink-0">
        <Button
          variant={isControlling ? "default" : "outline"}
          size="sm"
          onClick={handleRemoteControl}
          className={cn(
            "h-8 px-3 text-xs font-medium",
            isControlling && "bg-green-600 hover:bg-green-700 text-white"
          )}
        >
          {isControlling ? "退出控制" : "远程控制"}
        </Button>
        <Button
          variant="outline"
          size="sm"
          onClick={handleRelay}
          disabled={isRelaying}
          className="h-8 px-3 text-xs font-medium gap-1"
        >
          {isRelaying ? (
            <Loader2 className="w-3 h-3 animate-spin" />
          ) : (
            <ArrowRightLeft className="w-3 h-3" />
          )}
          接力
        </Button>
      </div>
    </div>
  );
}

export function CrossDevicePlaybacks() {
  const coordStore = useCoordinationStore();
  const isConnected = coordStore.isConnected;
  const currentDeviceId = coordStore.deviceId;

  if (!isConnected) return null;

  // Filter other devices that have recent playing snapshots
  const activeDeviceCards = coordStore.devices
    .filter((device) => {
      // Exclude self
      if (device.id === currentDeviceId) return false;

      const snapshotData = coordStore.deviceSnapshots[device.id];
      if (!snapshotData || !snapshotData.snapshot?.songId) return false;

      // Ensure online or recent (within 8 hours)
      const isRecent =
        snapshotData.isOnline || Date.now() - snapshotData.lastUpdatedAt < 8 * 60 * 60 * 1000;
      return isRecent;
    })
    .map((device) => {
      const snapshotData = coordStore.deviceSnapshots[device.id]!;
      return (
        <DevicePlaybackCard
          key={device.id}
          device={device}
          snapshotData={snapshotData}
        />
      );
    });

  if (activeDeviceCards.length === 0) return null;

  return <div className="flex flex-col gap-2.5 mb-4 w-full">{activeDeviceCards}</div>;
}
