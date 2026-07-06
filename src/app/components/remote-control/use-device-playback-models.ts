import { useEffect, useState } from "react";
import { projectPlaybackProgress } from "@/coordination/progress";
import { useCoordinationStore } from "@/coordination/store";
import type {
  DeviceDto,
  DeviceId,
  PlaybackSnapshot,
} from "@/coordination/types";
import dateTime from "@/utils/dateTime";
import type { DerivedDevicesGroup, DevicePlaybackModel } from "./types";

const OFFLINE_EXPIRY_MS = 8 * 60 * 60 * 1000;

type DeviceSnapshotState = {
  snapshot: PlaybackSnapshot;
  isOnline: boolean;
  generation: number;
  snapshotRevision: number;
  lastUpdatedAt: number;
  serverTime: number;
  lastConfirmedAt: number;
  receivedAtPerformance: number;
};

interface DeriveDevicePlaybackModelsOptions {
  devices: DeviceDto[];
  deviceSnapshots: Record<DeviceId, DeviceSnapshotState>;
  currentDeviceId: DeviceId | null;
  controlledDeviceId: DeviceId | null;
  now: number;
  nowPerformance: number;
}

function hasSongSnapshot(
  snapshot: PlaybackSnapshot | null,
): snapshot is PlaybackSnapshot {
  return !!snapshot?.songId;
}

function isOfflineSnapshotFresh(
  snapshotData: DeviceSnapshotState | undefined,
  now: number,
): boolean {
  if (!snapshotData || snapshotData.isOnline) return false;
  return now - snapshotData.lastUpdatedAt < OFFLINE_EXPIRY_MS;
}

function fallbackCurrentDevice(id: DeviceId): DeviceDto {
  return {
    id,
    name: "This device",
    platform: "local",
    clientVersion: null,
    capabilities: 0,
    createdAt: new Date(0).toISOString(),
    lastOnlineAt: null,
    revokedAt: null,
    historySyncCursor: 0,
    legacyHistoryImported: false,
  };
}

export function deriveDevicePlaybackModels({
  devices,
  deviceSnapshots,
  currentDeviceId,
  controlledDeviceId,
  now,
  nowPerformance,
}: DeriveDevicePlaybackModelsOptions): DerivedDevicesGroup {
  let thisDevice: DevicePlaybackModel | null = null;
  const liveDevices: DevicePlaybackModel[] = [];
  const offlineSnapshots: DevicePlaybackModel[] = [];
  const hiddenDevices: DevicePlaybackModel[] = [];
  const modelDevices =
    currentDeviceId && !devices.some((device) => device.id === currentDeviceId)
      ? [fallbackCurrentDevice(currentDeviceId), ...devices]
      : !currentDeviceId
        ? [fallbackCurrentDevice("local-device"), ...devices]
        : devices;

  for (const device of modelDevices) {
    const isSelf = device.id === currentDeviceId || device.platform === "local";
    const snapshotData = deviceSnapshots[device.id];
    const snapshot = snapshotData?.snapshot ?? null;
    const isOnline = snapshotData?.isOnline ?? false;
    const durationSeconds = snapshot?.durationSeconds ?? 0;
    const projectedProgressSeconds = snapshotData
      ? projectPlaybackProgress(
          {
            snapshot: snapshotData.snapshot,
            serverTime: snapshotData.serverTime,
            lastConfirmedAt: snapshotData.lastConfirmedAt,
            receivedAtPerformance: snapshotData.receivedAtPerformance,
          },
          nowPerformance,
        )
      : 0;
    const isControllingOthers = device.isControlling === true;
    const hasSupportedSnapshot = hasSongSnapshot(snapshot);
    const isFreshOfflineSnapshot = isOfflineSnapshotFresh(snapshotData, now);
    const canBeControlled =
      !isSelf &&
      isOnline &&
      hasSupportedSnapshot &&
      !isControllingOthers &&
      controlledDeviceId !== device.id;
    const canBeContinuedLocally =
      !isSelf &&
      hasSupportedSnapshot &&
      !isControllingOthers &&
      (isOnline || isFreshOfflineSnapshot);
    const lastUpdatedAt = snapshotData?.lastUpdatedAt ?? 0;
    const lastSeenText = device.lastOnlineAt
      ? dateTime(device.lastOnlineAt).fromNow()
      : "";

    const model: DevicePlaybackModel = {
      device,
      snapshot,
      isOnline,
      canBeControlled,
      canBeContinuedLocally,
      projectedProgressSeconds,
      durationSeconds,
      lastUpdatedAt,
      lastSeenText,
    };

    if (isSelf) {
      thisDevice = model;
    } else if (isControllingOthers) {
      hiddenDevices.push(model);
    } else if (isOnline && hasSupportedSnapshot) {
      liveDevices.push(model);
    } else if (hasSupportedSnapshot && isFreshOfflineSnapshot) {
      offlineSnapshots.push(model);
    } else {
      hiddenDevices.push(model);
    }
  }

  return {
    thisDevice,
    liveDevices,
    offlineSnapshots,
    hiddenDevices,
  };
}

export function useDevicePlaybackModels(): DerivedDevicesGroup {
  const currentDeviceId = useCoordinationStore((state) => state.deviceId);
  const devices = useCoordinationStore((state) => state.devices);
  const deviceSnapshots = useCoordinationStore(
    (state) => state.deviceSnapshots,
  );
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const [, setTicker] = useState(0);

  useEffect(() => {
    const interval = window.setInterval(() => {
      setTicker((value) => value + 1);
    }, 1000);

    return () => window.clearInterval(interval);
  }, []);

  return deriveDevicePlaybackModels({
    devices,
    deviceSnapshots,
    currentDeviceId,
    controlledDeviceId,
    now: Date.now(),
    nowPerformance: performance.now(),
  });
}
