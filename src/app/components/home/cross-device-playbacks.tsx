import { useQuery } from "@tanstack/react-query";
import {
  ArrowRightLeft,
  Cast,
  Laptop,
  Loader2,
  MousePointerClick,
  Radio,
  Smartphone,
  Tv,
} from "lucide-react";
import { useDeferredValue, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { Button } from "@/app/components/ui/button";
import { SimpleTooltip } from "@/app/components/ui/simple-tooltip";
import { useCoordinationStore } from "@/coordination/store";
import type {
  DeviceDto,
  PlaybackSnapshot,
  RemoteCommand,
} from "@/coordination/types";
import { subsonic } from "@/service/subsonic";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import { LanControlMessageType } from "@/types/lanControl";
import { cn } from "@/lib/utils";

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
        ? { type: "play_song", song_id: d.songId }
        : null;
    case LanControlMessageType.PLAY_ALBUM:
      return typeof d?.albumId === "string"
        ? {
            type: "play_album",
            album_id: d.albumId,
            index: d.songIndex,
            shuffle: false,
          }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST:
      return typeof d?.playlistId === "string"
        ? {
            type: "play_playlist",
            playlist_id: d.playlistId,
            index: d.songIndex,
            shuffle: false,
          }
        : null;
    case LanControlMessageType.PLAY_ALBUM_SHUFFLE:
      return typeof d?.albumId === "string"
        ? {
            type: "play_album",
            album_id: d.albumId,
            index: d.songIndex,
            shuffle: true,
          }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST_SHUFFLE:
      return typeof d?.playlistId === "string"
        ? {
            type: "play_playlist",
            playlist_id: d.playlistId,
            index: d.songIndex,
            shuffle: true,
          }
        : null;
    case LanControlMessageType.ADD_TO_QUEUE:
      return Array.isArray(d?.songIds)
        ? { type: "add_to_queue_last", song_ids: d.songIds }
        : null;
    case LanControlMessageType.CLEAR_QUEUE:
      return { type: "clear_queue" };
    case LanControlMessageType.PLAY_AT_INDEX:
      return Array.isArray(d?.songIds) && typeof d?.index === "number"
        ? { type: "play_at_index", song_ids: d.songIds, index: d.index }
        : null;
    case LanControlMessageType.TOGGLE_SHUFFLE:
      return {
        type: "set_shuffle",
        enabled: !usePlayerStore.getState().songlist.isShuffleActive,
      };
    case LanControlMessageType.SET_SHUFFLE:
      return typeof d?.enabled === "boolean"
        ? { type: "set_shuffle", enabled: d.enabled }
        : null;
    case LanControlMessageType.TOGGLE_REPEAT: {
      const ls = usePlayerStore.getState().playerState.loopState;
      const nextMode = ls === 0 ? "all" : ls === 1 ? "one" : "off";
      return { type: "set_repeat", mode: nextMode };
    }
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
  const manager = useCoordinationStore((state) => state.manager);
  const setControlledDevice = useCoordinationStore(
    (state) => state.setControlledDevice,
  );
  const playerActions = usePlayerActions();
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const isControlling = controlledDeviceId === device.id;
  const [isRelaying, setIsRelaying] = useState(false);
  const { t } = useTranslation();
  /// source_changed retry counter (design §11.2). Each `source_changed` error
  /// refreshes the snapshot revision from the latest `snapshot_projection`
  /// and resends `handoff_candidate_request`, up to this limit.
  const SOURCE_CHANGED_MAX_RETRIES = 2;
  const sourceChangedRetriesRef = useRef(0);

  const { data: song, isLoading } = useSongInfo(snapshotData.snapshot.songId);

  // Monitor relay/handoff status
  useEffect(() => {
    if (!isRelaying) return;
    const originalCommitted = manager.callbacks.onHandoffCommitted;
    const originalFailed = manager.callbacks.onHandoffFailed;
    const originalError = manager.callbacks.onError;

    manager.callbacks.onHandoffCommitted = (snapshot, newGeneration) => {
      originalCommitted(snapshot, newGeneration);
      setIsRelaying(false);
      toast.success(
        t("settings.crossDevice.toast.relaySuccess", {
          defaultValue: "Handoff successful!",
        }),
      );
    };

    manager.callbacks.onHandoffFailed = (transactionId, code) => {
      originalFailed(transactionId, code);
      setIsRelaying(false);
      toast.error(
        t("settings.crossDevice.toast.relayFailed", {
          defaultValue: "Handoff failed: {{code}}",
          code,
        }),
      );
    };

    // Server-side handoff validation errors (source_changed / stale_epoch /
    // bad_message / target_offline) arrive as generic `error` envelopes, not
    // handoff_failed. Surface them as relay failures while a relay is active.
    //
    // source_changed (design §11.2): the source device's snapshot revision
    // advanced during the handoff window. Instead of immediately failing,
    // refresh the latest snapshot projection from the manager and resend the
    // `handoff_candidate_request`, up to SOURCE_CHANGED_MAX_RETRIES times.
    manager.callbacks.onError = (code, reason) => {
      if (
        code === "source_changed" &&
        sourceChangedRetriesRef.current < SOURCE_CHANGED_MAX_RETRIES
      ) {
        sourceChangedRetriesRef.current += 1;
        // Wait for the source device's newest snapshot_projection (the source
        // keeps publishing on every change), then resend with the fresh
        // generation/snapshotRevision. Keep the loading spinner active.
        manager
          .waitForDeviceSnapshotUpdate(device.id)
          .then(({ generation, snapshotRevision }) => {
            manager.requestHandoffCandidate(device.id, generation, snapshotRevision);
          })
          .catch(() => {
            // Timed out waiting for a fresh projection — give up.
            originalError(code, reason);
            setIsRelaying(false);
            toast.error(
              t("settings.crossDevice.toast.relayFailed", {
                defaultValue: "Handoff failed: {{code}}",
                code,
              }),
            );
          });
        return;
      }
      originalError(code, reason);
      setIsRelaying(false);
      toast.error(
        t("settings.crossDevice.toast.relayFailed", {
          defaultValue: "Handoff failed: {{code}}",
          code,
        }),
      );
    };

    return () => {
      manager.callbacks.onHandoffCommitted = originalCommitted;
      manager.callbacks.onHandoffFailed = originalFailed;
      manager.callbacks.onError = originalError;
    };
  }, [isRelaying, manager, t, device.id]);

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
      usePlayerStore.getState().actions.setPlayingState(false);
      setControlledDevice(null);
      manager.sendControlSessionEnd();
      toast.info(
        t("settings.crossDevice.toast.exitRemoteControl", {
          defaultValue: "Exited remote control",
        }),
      );
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
      setControlledDevice(device.id);
      // §10 exclusivity: mark this device as an active controller so other
      // devices cannot remote control or handoff-take it while it is
      // controlling A.
      manager.sendControlSessionBegin(device.id);
      toast.success(
        t("settings.crossDevice.toast.remoteControlSuccess", {
          defaultValue: "Remote controlling: {{name}}",
          name: device.name,
        }),
      );
    }
  };

  const handleRelay = () => {
    // If currently remote controlling, exit remote control first
    const isRemoteActive = usePlayerStore.getState().remoteControl.active;
    if (isRemoteActive) {
      usePlayerStore.setState({
        remoteControl: {
          active: false,
          device: null,
          sendCommand: null,
        },
      });
      usePlayerStore.getState().actions.setPlayingState(false);
      setControlledDevice(null);
      manager.sendControlSessionEnd();
      toast.info(
        t("settings.crossDevice.toast.exitRemoteControl", {
          defaultValue: "Exited remote control",
        }),
      );
    }

    setIsRelaying(true);
    sourceChangedRetriesRef.current = 0;
    manager.requestHandoffCandidate(
      device.id,
      snapshotData.generation,
      snapshotData.snapshotRevision,
    );
    toast.info(
      t("settings.crossDevice.toast.preparingRelay", {
        defaultValue: "Preparing handoff...",
      }),
    );
    // Safety timeout to clear loading state in case of connection drop
    setTimeout(() => {
      setIsRelaying(false);
    }, 15000);
  };

  return (
    <div
      className={cn(
        "bg-card/40 backdrop-blur border rounded-lg p-3 flex items-center justify-between gap-4 transition-all duration-300",
        isControlling
          ? "border-primary/50 bg-primary/5"
          : "border-border/50 hover:bg-card/60",
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
            {isLoading
              ? t("settings.crossDevice.playback.fetchingSong", {
                  defaultValue: "Fetching song...",
                })
              : song?.title ||
                t("settings.crossDevice.playback.unknownTrack", {
                  defaultValue: "Unknown track",
                })}
          </span>
          <div className="text-xs text-muted-foreground flex items-center gap-1.5 mt-0.5">
            <span className="flex items-center gap-1 font-medium text-foreground/80">
              {getDeviceIcon(device.platform)}
              {device.name}
            </span>
          </div>
        </div>
      </div>

      {/* Buttons (Right) */}
      <div className="flex items-center gap-2 flex-shrink-0">
        {snapshotData.isOnline && (
          <SimpleTooltip
            text={
              isControlling
                ? t("settings.crossDevice.playback.exitControl", {
                    defaultValue: "Exit control",
                  })
                : t("settings.crossDevice.playback.remoteControl", {
                    defaultValue: "Remote control",
                  })
            }
          >
            <Button
              variant={isControlling ? "default" : "ghost"}
              onClick={handleRemoteControl}
              className="size-11 p-0 rounded-lg transition-all duration-200"
            >
              <MousePointerClick className="w-5 h-5" />
            </Button>
          </SimpleTooltip>
        )}
        <SimpleTooltip
          text={
            isRelaying
              ? t("settings.crossDevice.toast.preparingRelay", {
                  defaultValue: "Preparing handoff...",
                })
              : t("settings.crossDevice.playback.relay", {
                  defaultValue: "Handoff",
                })
          }
        >
          <Button
            variant="ghost"
            onClick={handleRelay}
            disabled={isRelaying}
            className="size-11 p-0 rounded-lg transition-all duration-200"
          >
            {isRelaying ? (
              <Loader2 className="w-5 h-5 animate-spin" />
            ) : (
              <ArrowRightLeft className="w-5 h-5" />
            )}
          </Button>
        </SimpleTooltip>
      </div>
    </div>
  );
}

export function CrossDevicePlaybacks() {
  const isConnected = useCoordinationStore((state) => state.isConnected);
  const currentDeviceId = useCoordinationStore((state) => state.deviceId);
  const devices = useCoordinationStore((state) => state.devices);
  const deviceSnapshots = useCoordinationStore(
    (state) => state.deviceSnapshots,
  );

  // WebSocket projections update the external Zustand store synchronously.
  // Defer the snapshot used to mount cards so the card's asynchronous song
  // metadata lookup cannot suspend the current UI during that sync update.
  const deferredDeviceSnapshots = useDeferredValue(deviceSnapshots);

  if (!isConnected) return null;

  // Filter other devices that have recent playing snapshots
  const activeDeviceCards = devices
    .filter((device) => {
      // Exclude self
      if (device.id === currentDeviceId) return false;

      // Hide devices that are currently acting as a remote controller
      // (design §10 exclusivity) — they cannot be controlled or handoff-taken.
      if (device.isControlling) return false;

      const snapshotData = deferredDeviceSnapshots[device.id];
      if (!snapshotData || !snapshotData.snapshot?.songId) return false;

      // Ensure online or recent (within 8 hours)
      const isRecent =
        snapshotData.isOnline ||
        Date.now() - snapshotData.lastUpdatedAt < 8 * 60 * 60 * 1000;
      return isRecent;
    })
    .map((device) => {
      const snapshotData = deferredDeviceSnapshots[device.id]!;
      return (
        <DevicePlaybackCard
          key={device.id}
          device={device}
          snapshotData={snapshotData}
        />
      );
    });

  if (activeDeviceCards.length === 0) return null;

  return (
    <div className="flex flex-col gap-2.5 mb-4 w-full">{activeDeviceCards}</div>
  );
}
