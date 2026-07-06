import { describe, expect, it } from "vitest";
import type { DeviceDto, PlaybackSnapshot } from "@/coordination/types";
import { deriveDevicePlaybackModels } from "./use-device-playback-models";

const NOW = 2_000_000;
const NOW_PERFORMANCE = 20_000;
const OFFLINE_EXPIRY_MS = 8 * 60 * 60 * 1000;

function device(overrides: Partial<DeviceDto> = {}): DeviceDto {
  return {
    id: "device-1",
    name: "Mac",
    platform: "electron",
    clientVersion: "0.30.0",
    capabilities: 0,
    createdAt: "2026-06-25T00:00:00.000Z",
    lastOnlineAt: "2026-06-25T00:00:00.000Z",
    revokedAt: null,
    historySyncCursor: 0,
    legacyHistoryImported: false,
    ...overrides,
  };
}

function snapshot(overrides: Partial<PlaybackSnapshot> = {}): PlaybackSnapshot {
  return {
    sessionId: "session-1",
    logicalPlaybackSessionId: "logical-1",
    mediaKind: "song",
    songId: "song-1",
    progressSeconds: 10,
    durationSeconds: 120,
    isPlaying: true,
    sampledAt: 0,
    contextQueue: ["song-1"],
    contextIndex: 0,
    sourceId: null,
    sourceName: null,
    userQueue: [],
    inUserQueue: false,
    restorePrevious: [],
    shuffle: false,
    repeat: "off",
    volume: 80,
    accumulatedPlaySeconds: 10,
    historyWritten: false,
    nowPlayingSent: false,
    scrobbleSent: false,
    ...overrides,
  };
}

function snapshotState(
  overrides: Partial<{
    snapshot: PlaybackSnapshot;
    isOnline: boolean;
    lastUpdatedAt: number;
    serverTime: number;
    lastConfirmedAt: number;
    receivedAtPerformance: number;
  }> = {},
) {
  return {
    snapshot: snapshot(),
    isOnline: true,
    generation: 1,
    snapshotRevision: 1,
    lastUpdatedAt: NOW,
    serverTime: 1_010,
    lastConfirmedAt: 1_000,
    receivedAtPerformance: 5_000,
    ...overrides,
  };
}

describe("deriveDevicePlaybackModels", () => {
  it("groups current, live, offline, and hidden devices", () => {
    const result = deriveDevicePlaybackModels({
      devices: [
        device({ id: "self", name: "This Mac" }),
        device({ id: "live", name: "iPhone", platform: "ios" }),
        device({ id: "offline", name: "iPad", platform: "ios" }),
        device({ id: "controller", name: "Desk", isControlling: true }),
        device({ id: "empty", name: "Empty" }),
      ],
      deviceSnapshots: {
        self: snapshotState(),
        live: snapshotState({ isOnline: true }),
        offline: snapshotState({
          isOnline: false,
          lastUpdatedAt: NOW - OFFLINE_EXPIRY_MS + 1,
        }),
        controller: snapshotState({ isOnline: true }),
      },
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    expect(result.thisDevice?.device.id).toBe("self");
    expect(result.liveDevices.map((model) => model.device.id)).toEqual([
      "live",
    ]);
    expect(result.offlineSnapshots.map((model) => model.device.id)).toEqual([
      "offline",
    ]);
    expect(result.hiddenDevices.map((model) => model.device.id)).toEqual([
      "controller",
      "empty",
    ]);
  });

  it("expires offline snapshots at the existing eight hour boundary", () => {
    const fresh = deriveDevicePlaybackModels({
      devices: [device({ id: "phone" })],
      deviceSnapshots: {
        phone: snapshotState({
          isOnline: false,
          lastUpdatedAt: NOW - OFFLINE_EXPIRY_MS + 1,
        }),
      },
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });
    const expired = deriveDevicePlaybackModels({
      devices: [device({ id: "phone" })],
      deviceSnapshots: {
        phone: snapshotState({
          isOnline: false,
          lastUpdatedAt: NOW - OFFLINE_EXPIRY_MS,
        }),
      },
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    expect(fresh.offlineSnapshots).toHaveLength(1);
    expect(fresh.offlineSnapshots[0].canBeContinuedLocally).toBe(true);
    expect(expired.offlineSnapshots).toHaveLength(0);
    expect(expired.hiddenDevices[0].canBeContinuedLocally).toBe(false);
  });

  it("computes control and continue availability from live state", () => {
    const result = deriveDevicePlaybackModels({
      devices: [
        device({ id: "available" }),
        device({ id: "controlled" }),
        device({ id: "unsupported" }),
      ],
      deviceSnapshots: {
        available: snapshotState(),
        controlled: snapshotState(),
        unsupported: snapshotState({ snapshot: snapshot({ songId: "" }) }),
      },
      currentDeviceId: "self",
      controlledDeviceId: "controlled",
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    const [available, controlled] = result.liveDevices;

    expect(available.canBeControlled).toBe(true);
    expect(available.canBeContinuedLocally).toBe(true);
    expect(controlled.canBeControlled).toBe(false);
    expect(controlled.canBeContinuedLocally).toBe(true);
    expect(result.hiddenDevices[0].device.id).toBe("unsupported");
  });

  it("projects progress with the shared monotonic playback anchor", () => {
    const result = deriveDevicePlaybackModels({
      devices: [device({ id: "phone" })],
      deviceSnapshots: {
        phone: snapshotState(),
      },
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    expect(result.liveDevices[0].projectedProgressSeconds).toBe(35);
    expect(result.liveDevices[0].durationSeconds).toBe(120);
  });

  it("keeps the current device visible when the device list is stale", () => {
    const result = deriveDevicePlaybackModels({
      devices: [device({ id: "phone", name: "iPhone", platform: "ios" })],
      deviceSnapshots: {
        self: snapshotState(),
        phone: snapshotState(),
      },
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    expect(result.thisDevice?.device.id).toBe("self");
    expect(result.thisDevice?.device.name).toBe("This device");
    expect(result.thisDevice?.snapshot?.songId).toBe("song-1");
    expect(result.liveDevices.map((model) => model.device.id)).toEqual([
      "phone",
    ]);
  });

  it("keeps the current device visible before the first snapshot arrives", () => {
    const result = deriveDevicePlaybackModels({
      devices: [],
      deviceSnapshots: {},
      currentDeviceId: "self",
      controlledDeviceId: null,
      now: NOW,
      nowPerformance: NOW_PERFORMANCE,
    });

    expect(result.thisDevice?.device.id).toBe("self");
    expect(result.thisDevice?.snapshot).toBeNull();
  });
});
