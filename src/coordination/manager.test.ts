import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CoordinationManager,
  type CoordinationManagerCallbacks,
} from "./manager";
import type { PlaybackSnapshot } from "./types";
import type { ConnectionCallbacks } from "./wsClient";

const transport = vi.hoisted(() => ({
  callbacks: null as ConnectionCallbacks | null,
}));

vi.mock("@/native/coordination", () => ({
  isNativeCoordinationAvailable: () => false,
}));
vi.mock("./tokenStore", () => ({
  loadConfig: async () => ({ serverUrl: "https://coord.example" }),
  loadTokens: async () => ({ deviceId: "local", accessToken: "test-token" }),
  saveConfig: vi.fn(),
  saveTokens: vi.fn(),
  clearTokens: vi.fn(),
}));
vi.mock("./wsClient", () => ({
  CoordinationWsClient: class {
    constructor(...args: unknown[]) {
      transport.callbacks = args[4] as ConnectionCallbacks;
    }
    async connect() {}
    disconnect() {}
    getState() {
      return "connected";
    }
  },
}));

describe("handoff UI subscriptions", () => {
  let manager: CoordinationManager;
  let callbacks: CoordinationManagerCallbacks;
  const snapshot = { sessionId: "session", songId: "song" } as PlaybackSnapshot;

  beforeEach(async () => {
    callbacks = {
      onConnectionStateChange: vi.fn(),
      onDevicesChanged: vi.fn(),
      onDeviceSnapshot: vi.fn(),
      onRemoteCommand: vi.fn(),
      onHandoffCandidate: vi.fn(),
      onPrepareRelinquish: vi.fn(),
      onHandoffCommitted: vi.fn(),
      onHandoffFailed: vi.fn(),
      onSessionSuperseded: vi.fn(),
      onError: vi.fn(),
    };
    manager = new CoordinationManager(callbacks);
    await manager.loadState();
    await manager.reconnect();
  });

  afterEach(async () => {
    await manager.disconnect();
  });

  it("keeps fullscreen completion subscribed after another surface unmounts and the observer reconnects", () => {
    const player = vi.fn();
    const fullscreen = vi.fn();
    const unsubscribePlayer = manager.subscribeHandoffEvents({
      onHandoffCommitted: player,
    });
    const unsubscribeFullscreen = manager.subscribeHandoffEvents({
      onHandoffCommitted: fullscreen,
    });
    const observer = vi.fn();
    callbacks.onHandoffCommitted = observer;
    unsubscribePlayer();
    transport.callbacks!.onHandoffCommitted({
      type: "handoff_committed",
      transactionId: "tx",
      snapshot,
      newGeneration: 2,
    });
    expect(player).not.toHaveBeenCalled();
    expect(fullscreen).toHaveBeenCalledWith(snapshot, 2);
    expect(observer).toHaveBeenCalledWith(snapshot, 2);
    unsubscribeFullscreen();
  });

  it("finishes UI timers before invoking the playback observer", () => {
    const events: string[] = [];
    callbacks.onHandoffCommitted = () => {
      events.push("playback");
    };
    manager.subscribeHandoffEvents({
      onHandoffCommitted: () => {
        events.push("finish-ui");
      },
    });
    transport.callbacks!.onHandoffCommitted({
      type: "handoff_committed",
      transactionId: "tx",
      snapshot,
      newGeneration: 2,
    });
    expect(events).toEqual(["finish-ui", "playback"]);
  });

  it("delivers failures to both surfaces and preserves unhandled errors", () => {
    const failure = vi.fn();
    const inactive = vi.fn(() => false);
    const active = vi.fn(() => true);
    const unsubscribe = manager.subscribeHandoffEvents({
      onHandoffFailed: failure,
      onError: active,
    });
    manager.subscribeHandoffEvents({ onError: inactive });
    transport.callbacks!.onHandoffFailed({
      type: "handoff_failed",
      transactionId: "tx",
      code: "source_pause_timeout",
    });
    expect(failure).toHaveBeenCalledWith("tx", "source_pause_timeout");
    expect(callbacks.onHandoffFailed).toHaveBeenCalledOnce();
    transport.callbacks!.onError("source_changed", "changed");
    expect(callbacks.onError).not.toHaveBeenCalled();
    unsubscribe();
    transport.callbacks!.onError("target_offline", "offline");
    expect(callbacks.onError).toHaveBeenCalledWith("target_offline", "offline");
  });
});
