import type { DeviceDto, PlaybackSnapshot } from "@/coordination/types";

export interface DevicePlaybackModel {
  device: DeviceDto;
  snapshot: PlaybackSnapshot | null;
  isOnline: boolean;
  canBeControlled: boolean;
  canBeContinuedLocally: boolean;
  projectedProgressSeconds: number;
  durationSeconds: number;
  lastUpdatedAt: number;
  lastSeenText: string;
}

export interface DerivedDevicesGroup {
  thisDevice: DevicePlaybackModel | null;
  liveDevices: DevicePlaybackModel[];
  offlineSnapshots: DevicePlaybackModel[];
  hiddenDevices: DevicePlaybackModel[];
}
