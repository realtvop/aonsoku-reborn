import { beforeEach, describe, expect, it, vi } from "vitest";
import { CoordinationWsClient, type ConnectionCallbacks } from "./wsClient";
import type { CommandResult, Envelope, PlaybackSnapshot } from "./types";
import { COORDINATION_PROTOCOL_VERSION } from "./types";

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

/// Minimal WebSocket stub. We only need `readyState`, `send`, `close`, and
/// the on* handlers so the client can wire messages. The test drives
/// `handleEnvelope` directly via the `internalHandleEnvelope` helper.
class MockWebSocket {
  static OPEN = 1;
  static CONNECTING = 0;
  static CLOSED = 3;
  static CLOSING = 2;
  readyState = MockWebSocket.OPEN;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: string[] = [];
  send(data: string) {
    this.sent.push(data);
  }
  close() {
    this.readyState = MockWebSocket.CLOSED;
  }
}

/// A constructor function that returns the shared `MockWebSocket` instance.
/// Vitest's `vi.fn(() => ws)` does NOT work with `new` (it ignores the impl's
/// return value), so we use a plain function constructor instead.
function makeMockWebSocketConstructor(ws: MockWebSocket): typeof WebSocket {
  // The static constants are set on the function itself.
  const ctor = function (_url: string) {
    return ws;
  } as unknown as typeof WebSocket;
  (ctor as unknown as { OPEN: number }).OPEN = MockWebSocket.OPEN;
  (ctor as unknown as { CONNECTING: number }).CONNECTING =
    MockWebSocket.CONNECTING;
  (ctor as unknown as { CLOSING: number }).CLOSING = MockWebSocket.CLOSING;
  (ctor as unknown as { CLOSED: number }).CLOSED = MockWebSocket.CLOSED;
  return ctor;
}

describe("CoordinationWsClient ack + dedup + seq", () => {
  let ws: MockWebSocket;
  let client: CoordinationWsClient;

  beforeEach(() => {
    ws = new MockWebSocket();
    vi.stubGlobal("WebSocket", makeMockWebSocketConstructor(ws));
    client = new CoordinationWsClient(
      () => "wss://coord.example/v1/realtime",
      async () => "ticket-1",
      "dev-1",
      15,
      makeCallbacks(),
    );
  });

  it("sendCommandAck resolves with the CommandResult when the matching command_ack arrives", async () => {
    await client.connect();
    // Trigger the onopen handshake so the client is in the connected state.
    ws.onopen?.();
    // The onopen callback sends hello; we don't care about that here.
    const promise: Promise<CommandResult> = client.sendCommandAck(
      "dev-2",
      1,
      { type: "play" },
      { awaitAck: true, timeoutMs: 1000 },
    );
    // The command envelope was sent. Capture its messageId.
    const commandEnv = JSON.parse(ws.sent[ws.sent.length - 1]) as Envelope;
    expect(commandEnv.type).toBe("command");
    const ack: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: commandEnv.messageId,
      type: "command_ack",
      result: { status: "ok" },
    } as unknown as Envelope;
    // Inject the ack.
    client.internalHandleEnvelope(ack);
    await expect(promise).resolves.toEqual({ status: "ok" });
    expect(client.internalPendingAckSize()).toBe(0);
  });

  it("sendCommandAck rejects after the timeout", async () => {
    vi.useFakeTimers();
    await client.connect();
    ws.onopen?.();
    const promise: Promise<CommandResult> = client.sendCommandAck(
      "dev-2",
      1,
      { type: "play" },
      { awaitAck: true, timeoutMs: 50 },
    );
    vi.advanceTimersByTime(60);
    await expect(promise).rejects.toThrow(/timeout/);
    vi.useRealTimers();
  });

  it("duplicate command envelopes are deduped (callback fires once)", async () => {
    await client.connect();
    ws.onopen?.();
    const cb = makeCallbacks();
    // Replace the client's callbacks with a fresh set so we can assert
    // call counts without the connect-time welcome noise.
    (client as unknown as { callbacks: ConnectionCallbacks }).callbacks = cb;
    const commandEnv: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: "m-dedup-1",
      type: "command",
      targetDeviceId: "dev-1",
      expectedGeneration: 1,
      command: { type: "play" },
      seq: 5,
    };
    client.internalHandleEnvelope(commandEnv);
    client.internalHandleEnvelope(commandEnv);
    expect(cb.onCommand).toHaveBeenCalledTimes(1);
    // lastSeq is tracked from the envelope's seq.
    expect(client.internalLastSeq()).toBe(5);
  });

  it("duplicate snapshot_projection envelopes are deduped", async () => {
    await client.connect();
    ws.onopen?.();
    const cb = makeCallbacks();
    (client as unknown as { callbacks: ConnectionCallbacks }).callbacks = cb;
    const snapEnv: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: "m-dedup-snap",
      type: "snapshot_projection",
      deviceId: "dev-2",
      sessionId: "sess-2",
      generation: 1,
      snapshotRevision: 2,
      snapshot: snapshot("sess-2"),
      isOnline: true,
      lastConfirmedAt: 1234,
      seq: 3,
    };
    client.internalHandleEnvelope(snapEnv);
    client.internalHandleEnvelope(snapEnv);
    expect(cb.onSnapshotProjection).toHaveBeenCalledTimes(1);
  });

  it("session_superseded dispatches onSessionSuperseded with fields", async () => {
    await client.connect();
    ws.onopen?.();
    const cb = makeCallbacks();
    (client as unknown as { callbacks: ConnectionCallbacks }).callbacks = cb;
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: "m-superseded",
      type: "session_superseded",
      supersededGeneration: 3,
      transferredToDevice: "dev-b",
      sessionId: "sess-a",
      expectedGeneration: 3,
      seq: 9,
    };
    client.internalHandleEnvelope(env);
    expect(cb.onSessionSuperseded).toHaveBeenCalledTimes(1);
    expect(cb.onSessionSuperseded).toHaveBeenCalledWith(env);
  });

  it("lastSeq is tracked and sent in the next hello", async () => {
    await client.connect();
    ws.onopen?.();
    // Reset the sent buffer so we only see the next hello.
    ws.sent.length = 0;
    // Feed envelopes with increasing seqs.
    client.internalHandleEnvelope({
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: "m-1",
      type: "snapshot_projection",
      deviceId: "dev-2",
      sessionId: "s",
      generation: 1,
      snapshotRevision: 1,
      snapshot: snapshot("s"),
      isOnline: true,
      lastConfirmedAt: 0,
      seq: 7,
    });
    client.internalHandleEnvelope({
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: "m-2",
      type: "snapshot_projection",
      deviceId: "dev-2",
      sessionId: "s",
      generation: 1,
      snapshotRevision: 2,
      snapshot: snapshot("s"),
      isOnline: true,
      lastConfirmedAt: 0,
      seq: 12,
    });
    expect(client.internalLastSeq()).toBe(12);
    // Trigger a hello via the private sendHello by calling connect's onopen
    // path. We simulate by re-invoking the hello sender through a fresh
    // connect (the state guard short-circuits, so we call the private method
    // via a cast).
    (client as unknown as { sendHello: (ticket: string) => void }).sendHello(
      "ticket-1",
    );
    const hello = JSON.parse(ws.sent[ws.sent.length - 1]) as Envelope;
    expect(hello.type).toBe("hello");
    expect((hello as { lastSeq: number }).lastSeq).toBe(12);
  });

  it("stale_epoch retry resends with the updated generation and does not loop", async () => {
    await client.connect();
    ws.onopen?.();
    const refresh = vi.fn().mockResolvedValue(42);
    client.setRefreshGenerationFn(refresh);
    const promise: Promise<CommandResult> = client.sendCommandAck(
      "dev-2",
      1,
      { type: "play" },
      {
        awaitAck: true,
        retryOnStaleEpoch: true,
        timeoutMs: 10_000,
      },
    );
    // First command envelope.
    const firstEnv = JSON.parse(ws.sent[ws.sent.length - 1]) as Envelope;
    expect(firstEnv.type).toBe("command");
    expect(firstEnv.expectedGeneration).toBe(1);
    // Server replies with stale_epoch.
    client.internalHandleEnvelope({
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: firstEnv.messageId,
      type: "command_ack",
      result: { status: "error", code: "stale_epoch", reason: "old gen" },
    } as unknown as Envelope);
    // Wait for the refresh + resend microtask chain.
    await Promise.resolve();
    await Promise.resolve();
    expect(refresh).toHaveBeenCalledWith("dev-2");
    // A second command envelope should have been sent with the new gen.
    const secondEnv = JSON.parse(ws.sent[ws.sent.length - 1]) as Envelope;
    expect(secondEnv.type).toBe("command");
    expect(secondEnv.expectedGeneration).toBe(42);
    // Server replies with stale_epoch again — must NOT loop, must reject.
    client.internalHandleEnvelope({
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: secondEnv.messageId,
      type: "command_ack",
      result: { status: "error", code: "stale_epoch", reason: "still old" },
    } as unknown as Envelope);
    await expect(promise).rejects.toThrow(/stale_epoch/);
    // Only one refresh call total — no loop.
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("fire-and-forget sendCommand returns void and does not register a pending ack", async () => {
    await client.connect();
    ws.onopen?.();
    const ret = client.sendCommand("dev-2", 1, { type: "play" });
    expect(ret).toBeUndefined();
    expect(client.internalPendingAckSize()).toBe(0);
  });

  it("disconnect rejects in-flight acks and clears the dedup cache", async () => {
    await client.connect();
    ws.onopen?.();
    const promise: Promise<CommandResult> = client.sendCommandAck(
      "dev-2",
      1,
      { type: "play" },
      { awaitAck: true, timeoutMs: 10_000 },
    );
    expect(client.internalPendingAckSize()).toBe(1);
    client.disconnect();
    await expect(promise).rejects.toThrow(/disconnected/);
    expect(client.internalPendingAckSize()).toBe(0);
    expect(client.internalDedupSize()).toBe(0);
  });
});