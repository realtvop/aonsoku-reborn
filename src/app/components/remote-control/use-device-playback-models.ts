import { useMemo, useState, useEffect } from "react";
import { useCoordinationStore } from "@/coordination/store";
import type { DevicePlaybackModel, DerivedDevicesGroup } from "./types";
import dateTime from "@/utils/dateTime";

const OFFLINE_EXPIRY_MS = 8 * 60 * 60 * 1000; // 8 hours

export function useDevicePlaybackModels(): DerivedDevicesGroup {
  const currentDeviceId = useCoordinationStore((state) => state.deviceId);
  const devices = useCoordinationStore((state) => state.devices);
  const deviceSnapshots = useCoordinationStore((state) => state.deviceSnapshots);
  const controlledDeviceId = useCoordinationStore((state) => state.controlledDeviceId);

  // Trigger re-render to update progress projection interpolation
  const [ticker, setTicker] = useState(0);
  useEffect(() => {
    const interval = setInterval(() => {
      setTicker((t) => t + 1);
    }, 1000);
    return () => clearInterval(interval);
  }, []);

  return useMemo(() => {
    // Reference ticker to trigger re-evaluation of progress projection on the interval
    const _ = ticker;
    let thisDevice: DevicePlaybackModel | null = null;
    const liveDevices: DevicePlaybackModel[] = [];
    const offlineSnapshots: DevicePlaybackModel[] = [];

    for (const device of devices) {
      const isSelf = device.id === currentDeviceId;
      const snapshotData = deviceSnapshots[device.id];
      const isOnline = snapshotData?.isOnline ?? false;
      const snapshot = snapshotData?.snapshot ?? null;

      // Project progress
      let projectedProgressSeconds = 0;
      let durationSeconds = 0;
      if (snapshot) {
        durationSeconds = snapshot.durationSeconds;
        if (snapshot.isPlaying && isOnline) {
          const elapsed = Date.now() / 1000 - snapshot.sampledAt;
          projectedProgressSeconds = Math.min(
            durationSeconds,
            Math.max(0, snapshot.progressSeconds + elapsed)
          );
        } else {
          projectedProgressSeconds = snapshot.progressSeconds;
        }
      }

      // Check if device is acting as a remote controller
      const isControllingOthers = device.isControlling;

      // Compute capabilities / actions availability
      // Live devices can be controlled if they are online, have a snapshot,
      // and are not currently acting as a controller themselves.
      const canBeControlled =
        !isSelf &&
        isOnline &&
        !!snapshot &&
        !isControllingOthers &&
        controlledDeviceId !== device.id;

      // Devices can be continued locally if they have a snapshot,
      // are not themselves a controller, and are not our current device.
      const canBeContinuedLocally =
        !isSelf &&
        !!snapshot &&
        !isControllingOthers;

      const lastUpdatedAt = snapshotData?.lastUpdatedAt ?? 0;
      let lastSeenText = "";
      if (device.lastOnlineAt) {
        lastSeenText = dateTime(device.lastOnlineAt).fromNow();
      }

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
        // Exclusivity rule: skip/hide device if it is active as a controller
        continue;
      } else if (isOnline && snapshot && snapshot.songId) {
        liveDevices.push(model);
      } else if (
        !isOnline &&
        snapshot &&
        snapshot.songId &&
        Date.now() - lastUpdatedAt < OFFLINE_EXPIRY_MS
      ) {
        offlineSnapshots.push(model);
      }
    }

    return {
      thisDevice,
      liveDevices,
      offlineSnapshots,
    };
  }, [devices, deviceSnapshots, currentDeviceId, controlledDeviceId, ticker]);
}
