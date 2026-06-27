import type { AonsokuNativeCoordinationPlugin } from "@aonsoku/capacitor-native/coordination";
import type { PluginListenerHandle } from "@capacitor/core";
import { Capacitor } from "@capacitor/core";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Envelope, PlaybackSnapshot } from "@/coordination/types";
import type { ConnectionCallbacks } from "@/coordination/wsClient";
import {
  createNativeCoordinationFetch,
  getNativeCoordinationAvailability,
  isNativeCoordinationAvailable,
  NativeCoordinationClient,
  NativeCoordinationTokenStore,
} from "./facade";

const mocks = vi.hoisted(() => {
  const mockPlugin = {
    storeTokens: vi.fn(),
    loadTokens: vi.fn(),
    clearTokens: vi.fn(),
    storeConfig: vi.fn(),
    loadConfig: vi.fn(),
    request: vi.fn(),
    connect: vi.fn(),
    disconnect: vi.fn(),
    getState: vi.fn(),
    publishSnapshot: vi.fn(),
    sendCommand: vi.fn(),
    sendActiveControlCommand: vi.fn(),
    requestHandoffCandidate: vi.fn(),
    sendTargetReady: vi.fn(),
    sendRelinquishAck: vi.fn(),
    requestSnapshots: vi.fn(),
    addListener: vi.fn(),
    removeAllListeners: vi.fn(),
  };
  return {
    mockPlugin,
    mockIsNativePlatform: vi.fn(),
    mockGetPlatform: vi.fn(),
    mockIsPluginAvailable: vi.fn(),
  };
});

vi.mock("@capacitor/core", () => ({
  Capacitor: {
    isNativePlatform: mocks.mockIsNativePlatform,
    getPlatform: mocks.mockGetPlatform,
    isPluginAvailable: mocks.mockIsPluginAvailable,
  },
}));

vi.mock("@aonsoku/capacitor-native/coordination", () => ({
  AonsokuNativeCoordination: mocks.mockPlugin,
  COORDINATION_PLUGIN_NAME: "AonsokuNativeCoordination",
}));

const mockIsNativePlatform = vi.mocked(Capacitor.isNativePlatform);
const mockGetPlatform = vi.mocked(Capacitor.getPlatform);
const mockIsPluginAvailable = vi.mocked(Capacitor.isPluginAvailable);
const mockPlugin =
  mocks.mockPlugin as unknown as AonsokuNativeCoordinationPlugin;

function makeCallbacks(): ConnectionCallbacks {
  return {
    onStateChange: vi.fn(),
    onWelcome: vi.fn(),
    onDevicesChanged: vi.fn(),
    onSnapshotProjection: vi.fn(),
    onCommand: vi.fn(),
    onHandoffCandidate: vi.fn(),
    onPrepareRelinquish: vi.fn(),
    onHandoffCommitted: vi.fn(),
    onHandoffFailed: vi.fn(),
    onSessionSuperseded: vi.fn(),
    onError: vi.fn(),
  };
}

/// Minimal `PlaybackSnapshot` for tests — fills required fields so we avoid
/// `as any` casts in assertions.
function snapshot(sessionId: string): PlaybackSnapshot {
  return {
    sessionId,
    logicalPlaybackSessionId: sessionId,
    mediaKind: "song",
    songId: "song-1",
    progressSeconds: 0,
    durationSeconds: 0,
    isPlaying: true,
    sampledAt: 0,
    contextQueue: [],
    contextIndex: null,
    sourceId: null,
    sourceName: null,
    userQueue: [],
    inUserQueue: false,
    restorePrevious: [],
    shuffle: false,
    repeat: "off",
    volume: null,
    accumulatedPlaySeconds: 0,
    historyWritten: false,
    nowPlayingSent: false,
    scrobbleSent: false,
  };
}

describe("native coordination facade availability", () => {
  beforeEach(() => {
    mockIsNativePlatform.mockReset();
    mockGetPlatform.mockReset();
    mockIsPluginAvailable.mockReset();
    mockIsNativePlatform.mockReturnValue(false);
    mockGetPlatform.mockReturnValue("web");
    mockIsPluginAvailable.mockReturnValue(false);
  });

  it("reports web as unavailable", () => {
    expect(getNativeCoordinationAvailability()).toMatchObject({
      available: false,
    });
    expect(isNativeCoordinationAvailable()).toBe(false);
  });

  it.each(["ios", "android"])(
    "returns the plugin on supported %s platforms",
    (platform) => {
      mockIsNativePlatform.mockReturnValue(true);
      mockGetPlatform.mockReturnValue(platform);
      mockIsPluginAvailable.mockReturnValue(true);

      expect(getNativeCoordinationAvailability()).toEqual({
        available: true,
        plugin: mockPlugin,
      });
      expect(isNativeCoordinationAvailable()).toBe(true);
      expect(mockIsPluginAvailable).toHaveBeenCalledWith(
        "AonsokuNativeCoordination",
      );
    },
  );

  it("keeps unsupported native platforms unavailable", () => {
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("electron");

    expect(getNativeCoordinationAvailability()).toMatchObject({
      available: false,
    });
  });

  it("reports missing plugin as unavailable on native", () => {
    mockIsNativePlatform.mockReturnValue(true);
    mockGetPlatform.mockReturnValue("ios");
    mockIsPluginAvailable.mockReturnValue(false);

    expect(getNativeCoordinationAvailability()).toMatchObject({
      available: false,
      reason: "Native coordination plugin is not installed",
    });
  });
});

describe("NativeCoordinationTokenStore", () => {
  beforeEach(() => {
    for (const value of Object.values(mocks.mockPlugin)) {
      if (typeof value === "function") vi.mocked(value).mockReset();
    }
  });

  it("delegates loadTokens to the native plugin", async () => {
    vi.mocked(mockPlugin.loadTokens).mockResolvedValue({
      accessToken: "at",
      refreshToken: "rt",
      deviceId: "dev-1",
      accountId: "acc-1",
      historyLimit: 500,
    });
    const store = new NativeCoordinationTokenStore(mockPlugin);
    const tokens = await store.loadTokens();
    expect(tokens).toEqual({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "at",
      refreshToken: "rt",
      accessTokenExpiresAt: 0,
      historyLimit: 500,
    });
  });

  it("returns null when the native plugin has no tokens", async () => {
    vi.mocked(mockPlugin.loadTokens).mockResolvedValue(null);
    const store = new NativeCoordinationTokenStore(mockPlugin);
    expect(await store.loadTokens()).toBeNull();
  });

  it("delegates saveTokens to storeTokens", async () => {
    const store = new NativeCoordinationTokenStore(mockPlugin);
    await store.saveTokens({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "at",
      refreshToken: "rt",
      accessTokenExpiresAt: 1234,
      historyLimit: 500,
    });
    expect(mockPlugin.storeTokens).toHaveBeenCalledWith({
      accessToken: "at",
      refreshToken: "rt",
      deviceId: "dev-1",
      accountId: "acc-1",
      historyLimit: 500,
    });
  });

  it("clears tokens via clearTokens when saving null", async () => {
    const store = new NativeCoordinationTokenStore(mockPlugin);
    await store.saveTokens(null);
    expect(mockPlugin.clearTokens).toHaveBeenCalled();
  });

  it("delegates clearTokens", async () => {
    const store = new NativeCoordinationTokenStore(mockPlugin);
    await store.clearTokens();
    expect(mockPlugin.clearTokens).toHaveBeenCalled();
  });

  it("delegates loadConfig", async () => {
    vi.mocked(mockPlugin.loadConfig).mockResolvedValue({
      serverUrl: "https://coord.example",
      identityUrl: "https://id.example",
    });
    const store = new NativeCoordinationTokenStore(mockPlugin);
    expect(await store.loadConfig()).toEqual({
      serverUrl: "https://coord.example",
      identityUrl: "https://id.example",
    });
  });

  it("delegates saveConfig", async () => {
    const store = new NativeCoordinationTokenStore(mockPlugin);
    await store.saveConfig({
      serverUrl: "https://coord.example",
      identityUrl: "https://id.example",
    });
    expect(mockPlugin.storeConfig).toHaveBeenCalledWith({
      serverUrl: "https://coord.example",
      identityUrl: "https://id.example",
    });
  });
});

describe("createNativeCoordinationFetch", () => {
  beforeEach(() => {
    vi.mocked(mockPlugin.request).mockReset();
  });

  it("delegates HTTP requests to the native coordination plugin", async () => {
    vi.mocked(mockPlugin.request).mockResolvedValue({
      status: 201,
      statusText: "Created",
      body: JSON.stringify({ ok: true }),
    });

    const nativeFetch = createNativeCoordinationFetch(mockPlugin);
    const resp = await nativeFetch("https://coord.example/v1/auth/register", {
      method: "POST",
      headers: { Authorization: "Bearer token" },
      body: JSON.stringify({ deviceName: "Android" }),
    });

    expect(mockPlugin.request).toHaveBeenCalledWith({
      url: "https://coord.example/v1/auth/register",
      method: "POST",
      headers: { Authorization: "Bearer token" },
      body: JSON.stringify({ deviceName: "Android" }),
    });
    expect(resp.status).toBe(201);
    await expect(resp.json()).resolves.toEqual({ ok: true });
  });

  it("returns empty-body HTTP statuses without constructing a body", async () => {
    vi.mocked(mockPlugin.request).mockResolvedValue({
      status: 204,
      statusText: "No Content",
      body: "",
    });

    const nativeFetch = createNativeCoordinationFetch(mockPlugin);
    const resp = await nativeFetch("https://coord.example/v1/devices/dev-1", {
      method: "DELETE",
    });

    expect(resp.status).toBe(204);
    await expect(resp.text()).resolves.toBe("");
  });
});

describe("NativeCoordinationClient", () => {
  let listeners: Record<string, ((data: unknown) => void)[]>;

  beforeEach(() => {
    for (const value of Object.values(mocks.mockPlugin)) {
      if (typeof value === "function") vi.mocked(value).mockReset();
    }
    listeners = {};
    vi.mocked(mockPlugin.addListener).mockImplementation(
      (eventName: string, listenerFunc: (data: unknown) => void) => {
        listeners[eventName] ??= [];
        listeners[eventName].push(listenerFunc);
        return Promise.resolve({
          remove: vi.fn().mockResolvedValue(undefined),
        }) as unknown as PluginListenerHandle;
      },
    );
    vi.mocked(mockPlugin.connect).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.disconnect).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.getState).mockResolvedValue({
      state: "disconnected",
      deviceId: null,
    });
    // All send methods return resolved promises so `.catch()` chains work.
    vi.mocked(mockPlugin.publishSnapshot).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.sendCommand).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.sendActiveControlCommand).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.requestHandoffCandidate).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.sendTargetReady).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.sendRelinquishAck).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.requestSnapshots).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.storeTokens).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.clearTokens).mockResolvedValue(undefined);
    vi.mocked(mockPlugin.storeConfig).mockResolvedValue(undefined);
  });

  function emit(eventName: string, data: unknown) {
    for (const listener of listeners[eventName] ?? []) listener(data);
  }

  it("routes publishSnapshot to the native plugin", async () => {
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
    await client.connect();
    client.publishSnapshot("sess-1", 1, 2, snapshot("sess-1"));
    expect(mockPlugin.publishSnapshot).toHaveBeenCalledWith({
      sessionId: "sess-1",
      generation: 1,
      snapshotRevision: 2,
      snapshotJson: expect.any(String),
    });
    const call = vi.mocked(mockPlugin.publishSnapshot).mock.calls[0][0];
    expect(JSON.parse(call.snapshotJson).sessionId).toBe("sess-1");
  });

  it("routes sendCommand to the native plugin", async () => {
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
    await client.connect();
    client.sendCommand("dev-2", 1, { type: "play" });
    expect(mockPlugin.sendCommand).toHaveBeenCalledWith({
      targetDeviceId: "dev-2",
      expectedGeneration: 1,
      commandJson: expect.any(String),
    });
    const call = vi.mocked(mockPlugin.sendCommand).mock.calls[0][0];
    expect(JSON.parse(call.commandJson)).toEqual({ type: "play" });
  });

  it("routes active control commands through the native target cache", async () => {
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
    await client.connect();
    client.sendActiveControlCommand({ type: "next" });
    expect(mockPlugin.sendActiveControlCommand).toHaveBeenCalledWith({
      commandJson: expect.any(String),
    });
    const call = vi.mocked(mockPlugin.sendActiveControlCommand).mock
      .calls[0][0];
    expect(JSON.parse(call.commandJson)).toEqual({ type: "next" });
  });

  it("routes requestHandoffCandidate, sendTargetReady, sendRelinquishAck", async () => {
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
    await client.connect();
    client.requestHandoffCandidate("dev-2", 1, 2);
    expect(mockPlugin.requestHandoffCandidate).toHaveBeenCalledWith(
      "dev-2",
      1,
      2,
    );

    client.sendTargetReady("tx-1", 1, 2, "dev-2", "sess-1");
    expect(mockPlugin.sendTargetReady).toHaveBeenCalledWith(
      "tx-1",
      1,
      2,
      "dev-2",
      "sess-1",
    );

    client.sendRelinquishAck("tx-1", snapshot("sess-1"));
    expect(mockPlugin.sendRelinquishAck).toHaveBeenCalledWith({
      transactionId: "tx-1",
      snapshotJson: expect.any(String),
    });
  });

  it("routes requestSnapshots to the native plugin", async () => {
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
    await client.connect();
    client.requestSnapshots();
    expect(mockPlugin.requestSnapshots).toHaveBeenCalled();
  });

  it("parses coordinationEvent envelopes and forwards through callbacks", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    await client.connect();

    const snapshotEnv: Envelope = {
      version: 1,
      messageId: "m-1",
      type: "snapshot_projection",
      deviceId: "dev-2",
      sessionId: "sess-2",
      generation: 1,
      snapshotRevision: 2,
      snapshot: snapshot("sess-2"),
      isOnline: true,
      lastConfirmedAt: 1234,
    };
    emit("coordinationEvent", { envelopeJson: JSON.stringify(snapshotEnv) });
    expect(cb.onSnapshotProjection).toHaveBeenCalledWith(snapshotEnv);

    const commandEnv: Envelope = {
      version: 1,
      messageId: "m-2",
      type: "command",
      targetDeviceId: "dev-1",
      expectedGeneration: 1,
      command: { type: "play" },
    };
    emit("coordinationEvent", { envelopeJson: JSON.stringify(commandEnv) });
    expect(cb.onCommand).toHaveBeenCalledWith(commandEnv);
  });

  it("ignores malformed coordinationEvent envelopes", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    await client.connect();
    emit("coordinationEvent", { envelopeJson: "{not valid json" });
    expect(cb.onError).not.toHaveBeenCalled();
  });

  it("forwards coordinationStateChange through onStateChange", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    await client.connect();
    emit("coordinationStateChange", { state: "connected", deviceId: "dev-1" });
    expect(cb.onStateChange).toHaveBeenCalledWith("connected");
  });

  it("triggers the reconnect handler on coordinationReconnectNeeded", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    const reconnect = vi.fn().mockResolvedValue(undefined);
    client.setReconnectHandler(reconnect);
    await client.connect();

    emit("coordinationReconnectNeeded", { attempt: 1 });
    expect(cb.onStateChange).toHaveBeenCalledWith("reconnecting");
    expect(reconnect).toHaveBeenCalled();
  });

  it("calls connect on the native plugin with wsUrl + ticket + deviceId", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    await client.connect();
    expect(mockPlugin.connect).toHaveBeenCalledWith({
      wsUrl: "wss://coord.example/v1/realtime",
      ticket: "ticket-1",
      deviceId: "dev-1",
      capabilities: 15,
      protocolVersion: 1,
      lastSeq: 0,
    });
  });

  it("surfaces error state when no ticket is available", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => null,
      "dev-1",
      15,
      cb,
    );
    await client.connect();
    expect(cb.onStateChange).toHaveBeenCalledWith("error");
    expect(cb.onError).toHaveBeenCalledWith(
      "authentication_failed",
      "no ws ticket available",
    );
    expect(mockPlugin.connect).not.toHaveBeenCalled();
  });

  it("disconnect calls the native plugin and removes listeners", async () => {
    const cb = makeCallbacks();
    const client = new NativeCoordinationClient(
      mockPlugin,
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      cb,
    );
    await client.connect();
    client.disconnect();
    expect(mockPlugin.disconnect).toHaveBeenCalled();
    expect(cb.onStateChange).toHaveBeenCalledWith("disconnected");
  });
});
