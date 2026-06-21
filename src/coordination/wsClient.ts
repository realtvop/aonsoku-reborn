// Coordination WebSocket client (design §9).
// Handles connection lifecycle, reconnection with exponential backoff,
// heartbeat, snapshot publish/subscribe, and remote command routing.

import { COORDINATION_PROTOCOL_VERSION, CoordinationCapability } from "./types";
import type {
  CommandResult,
  ConnectionId,
  ConnectionSeq,
  CoordinationCapabilities,
  DeviceId,
  Envelope,
  MessageId,
  PlaybackSnapshot,
  RemoteCommand,
  SessionGeneration,
  SessionId,
  SnapshotRevision,
} from "./types";

export type ConnectionState =
  | "disconnected"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "error";

export interface ConnectionCallbacks {
  onStateChange: (state: ConnectionState) => void;
  onWelcome: (
    deviceId: DeviceId,
    connectionId: ConnectionId,
    negotiated: CoordinationCapabilities,
  ) => void;
  onDevicesChanged: (devices: import("./types").DeviceDto[]) => void;
  onSnapshotProjection: (env: Envelope) => void;
  onCommand: (env: Envelope) => void;
  onHandoffCandidate: (env: Envelope) => void;
  onPrepareRelinquish: (env: Envelope) => void;
  onHandoffCommitted: (env: Envelope) => void;
  onHandoffFailed: (env: Envelope) => void;
  onSessionSuperseded: (env: Envelope) => void;
  onError: (code: string, reason: string) => void;
}

/// Options for `sendCommand()` when the caller wants the `CommandResult`
/// back (design §9.1). The fire-and-forget overload omits the options bag.
export interface SendCommandOptions {
  /// Resolve the returned `Promise<CommandResult>` after the matching
  /// `command_ack` arrives. When false (default for the options-less
  /// overload) the call is fire-and-forget.
  awaitAck?: boolean;
  /// Per-call ack timeout in ms. Defaults to `DEFAULT_ACK_TIMEOUT_MS`.
  timeoutMs?: number;
  /// When the ack returns `{ status: "error", code: "stale_epoch" }`, fetch
  /// the latest device snapshot via `refreshGeneration()` and resend once.
  /// A second `stale_epoch` rejects (design §13).
  retryOnStaleEpoch?: boolean;
}

/// Callback used by the stale-epoch retry path to refresh the expected
/// generation. The manager wires this to its device-snapshot cache.
export type RefreshGenerationFn = (
  targetDeviceId: DeviceId,
) => Promise<SessionGeneration | null>;

/// Unified coordination client surface (design §5.2). Both the TypeScript
/// `CoordinationWsClient` (web/Electron) and the native facade client
/// (`NativeCoordinationClient`) implement this interface so the
/// `Coordination Manager` is unaware of which transport is active.
export interface CoordinationClient {
  connect(): Promise<void>;
  disconnect(): void;
  getState(): ConnectionState;
  publishSnapshot(
    sessionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    snapshot: PlaybackSnapshot,
  ): void;
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ): void;
  sendCommandAck?(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options: SendCommandOptions,
  ): Promise<CommandResult>;
  requestHandoffCandidate(
    sourceDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    expectedSnapshotRevision: SnapshotRevision,
  ): void;
  sendTargetReady(
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ): void;
  sendRelinquishAck(transactionId: string, snapshot: PlaybackSnapshot): void;
  sendControlSessionBegin(targetDeviceId: DeviceId): void;
  sendControlSessionEnd(): void;
}

/// Unified coordination client surface (design §5.2). Both the TypeScript
/// `CoordinationWsClient` (web/Electron) and the native facade client
/// (`NativeCoordinationClient`) implement this interface so the
/// `CoordinationManager` is unaware of which transport is active.
export interface CoordinationClient {
  connect(): Promise<void>;
  disconnect(): void;
  getState(): ConnectionState;
  publishSnapshot(
    sessionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    snapshot: PlaybackSnapshot,
  ): void;
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ): void;
  requestHandoffCandidate(
    sourceDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    expectedSnapshotRevision: SnapshotRevision,
  ): void;
  sendTargetReady(
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ): void;
  sendRelinquishAck(transactionId: string, snapshot: PlaybackSnapshot): void;
  sendControlSessionBegin(targetDeviceId: DeviceId): void;
  sendControlSessionEnd(): void;
}

const HEARTBEAT_INTERVAL_MS = 15_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;
/// §9.1 ack timeout. Generous vs the §10 p95 < 500ms target so jitter on a
/// slow link does not spuriously reject commands.
const DEFAULT_ACK_TIMEOUT_MS = 10_000;
/// §9.1 dedup cache: keep the last N messageIds we have already dispatched.
/// Duplicates within this window are skipped silently (debug-level log).
const DEDUP_CACHE_MAX = 200;

interface PendingAck {
  messageId: MessageId;
  createdAt: number;
  resolve: (result: CommandResult) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  /// Original command parameters, kept so the stale-epoch retry path can
  /// re-send with an updated `expectedGeneration` without re-binding args.
  retry: {
    targetDeviceId: DeviceId;
    expectedGeneration: SessionGeneration;
    command: RemoteCommand;
    options: SendCommandOptions;
    attempted: boolean;
  };
}

/// LRU-ish dedup cache. The oldest entry is evicted when the cap is reached.
/// Implemented as a `Map` (insertion-ordered) so `keys().next()` gives the
/// oldest entry in O(1).
class DedupCache {
  private readonly seen = new Map<MessageId, number>();
  private readonly max: number;
  constructor(max = DEDUP_CACHE_MAX) {
    this.max = max;
  }
  /** Returns true if `id` was already seen (duplicate). */
  has(id: MessageId): boolean {
    return this.seen.has(id);
  }
  /** Mark `id` as seen. Evicts the oldest entry when full. */
  mark(id: MessageId): void {
    if (this.seen.has(id)) return;
    if (this.seen.size >= this.max) {
      const oldest = this.seen.keys().next().value;
      if (oldest !== undefined) this.seen.delete(oldest);
    }
    this.seen.set(id, Date.now());
  }
  clear(): void {
    this.seen.clear();
  }
  size(): number {
    return this.seen.size;
  }
}

export class CoordinationWsClient implements CoordinationClient {
  private ws: WebSocket | null = null;
  private state: ConnectionState = "disconnected";
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private lastSeq: ConnectionSeq = 0;
  private negotiatedCaps: CoordinationCapabilities =
    CoordinationCapability.NONE;
  private disposed = false;
  /// §9.1 pending-ack map keyed by messageId. Each entry holds the
  /// caller's resolve/reject and a timeout timer.
  private pendingAcks = new Map<MessageId, PendingAck>();
  /// §9.1 dedup cache for incoming envelopes. Dedup is expected behavior
  /// (the server replays results for replayed messageIds) so duplicates are
  /// skipped silently.
  private dedup = new DedupCache();
  /// Stale-epoch retry hook. Wired by the manager to its device-snapshot
  /// cache so the retry path can fetch the current generation.
  private refreshGenerationFn: RefreshGenerationFn | null = null;

  constructor(
    private readonly urlFn: () => string,
    private readonly ticketFn: () => Promise<string | null>,
    private readonly deviceId: DeviceId | null,
    private readonly capabilities: CoordinationCapabilities,
    private readonly callbacks: ConnectionCallbacks,
  ) {}

  /// Wire the stale-epoch retry hook (design §13). The manager calls this
  /// with a function that resolves to the latest generation for a target
  /// device, drawn from its `onDeviceSnapshot` cache or a fresh
  /// `getDevices()` call.
  setRefreshGenerationFn(fn: RefreshGenerationFn): void {
    this.refreshGenerationFn = fn;
  }

  /// Test-only: inspect the dedup cache size.
  internalDedupSize(): number {
    return this.dedup.size();
  }

  /// Test-only: inspect the pending-ack map size.
  internalPendingAckSize(): number {
    return this.pendingAcks.size;
  }

  /// Test-only: current tracked lastSeq.
  internalLastSeq(): ConnectionSeq {
    return this.lastSeq;
  }

  /// Test-only: inject an envelope into `handleEnvelope` without a live WS.
  internalHandleEnvelope(env: Envelope): void {
    this.handleEnvelope(env);
  }

  getState(): ConnectionState {
    return this.state;
  }

  getNegotiatedCapabilities(): CoordinationCapabilities {
    return this.negotiatedCaps;
  }

  async connect(): Promise<void> {
    if (this.disposed) return;
    if (this.state === "connecting" || this.state === "connected") return;
    this.setState("connecting");
    const ticket = await this.ticketFn();
    if (!ticket) {
      this.setState("error");
      this.callbacks.onError("authentication_failed", "no ws ticket available");
      return;
    }
    const url = this.urlFn();
    const wsUrl = `${url}?ticket=${encodeURIComponent(ticket)}`;
    try {
      this.ws = new WebSocket(wsUrl);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws.onopen = () => {
      this.setState("connected");
      this.reconnectAttempts = 0;
      this.sendHello(ticket);
      this.startHeartbeat();
    };
    this.ws.onmessage = (event) => {
      try {
        const env = JSON.parse(event.data as string) as Envelope;
        this.handleEnvelope(env);
      } catch {
        // Malformed message; ignore.
      }
    };
    this.ws.onerror = () => {
      this.setState("error");
    };
    this.ws.onclose = () => {
      this.stopHeartbeat();
      if (!this.disposed) {
        this.scheduleReconnect();
      }
    };
  }

  disconnect(): void {
    this.disposed = true;
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    // Reject any in-flight acks so callers don't hang on teardown.
    for (const pending of this.pendingAcks.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("coordination: disconnected before ack"));
    }
    this.pendingAcks.clear();
    // The dedup cache is per-connection; clear it so a reconnect does not
    // falsely skip messages from the new connection.
    this.dedup.clear();
    if (this.ws) {
      this.ws.onclose = null;
      this.ws.close();
      this.ws = null;
    }
    this.setState("disconnected");
  }

  private setState(state: ConnectionState) {
    if (this.state === state) return;
    this.state = state;
    this.callbacks.onStateChange(state);
  }

  private sendHello(ticket: string) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "hello",
      protocolVersion: COORDINATION_PROTOCOL_VERSION,
      capabilities: this.capabilities,
      deviceId: this.deviceId ?? null,
      ticket,
      lastSeq: this.lastSeq,
    };
    this.send(env);
  }

  private startHeartbeat() {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      this.send({
        version: COORDINATION_PROTOCOL_VERSION,
        messageId: crypto.randomUUID(),
        type: "heartbeat",
      });
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private send(env: Envelope) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(env));
    }
  }

  private handleEnvelope(env: Envelope) {
    // §9.2: track the incoming seq on every envelope so the next `hello`
    // can submit the highest seq the client has processed. The server uses
    // it to skip already-delivered messages; if it ignores it, the dedup
    // cache below still prevents double-dispatch.
    if (typeof env.seq === "number" && env.seq > this.lastSeq) {
      this.lastSeq = env.seq;
    }

    // §9.1: dedup incoming command/snapshot envelopes by messageId. The
    // server replays the original result for a replayed messageId, so a
    // duplicate here is expected — skip re-dispatch silently (debug log).
    if (
      (env.type === "command" || env.type === "snapshot_projection") &&
      env.messageId
    ) {
      if (this.dedup.has(env.messageId)) {
        return;
      }
      this.dedup.mark(env.messageId);
    }

    switch (env.type) {
      case "welcome":
        this.negotiatedCaps = env.negotiated;
        if (typeof env.seq === "number" && env.seq > this.lastSeq) {
          this.lastSeq = env.seq;
        }
        this.callbacks.onWelcome(
          env.deviceId,
          env.connectionId,
          env.negotiated,
        );
        break;
      case "heartbeat_ack":
        // Update last-seen; no action needed.
        break;
      case "devices_changed":
        this.callbacks.onDevicesChanged(env.devices);
        break;
      case "snapshot_projection":
        this.callbacks.onSnapshotProjection(env);
        break;
      case "command":
        this.callbacks.onCommand(env);
        break;
      case "command_ack": {
        // §9.1: resolve the pending-ack promise for this messageId.
        const pending = this.pendingAcks.get(env.messageId);
        if (pending) {
          clearTimeout(pending.timer);
          this.pendingAcks.delete(env.messageId);
          // §13: stale_epoch retry path. When the caller opted in via
          // `retryOnStaleEpoch` and we have a refresh hook, fetch the
          // latest generation and resend once. A second stale_epoch (or
          // no refresh hook) rejects.
          if (
            env.result.status === "error" &&
            env.result.code === "stale_epoch" &&
            pending.retry.options.retryOnStaleEpoch &&
            !pending.retry.attempted &&
            this.refreshGenerationFn
          ) {
            pending.retry.attempted = true;
            this.refreshGenerationFn(pending.retry.targetDeviceId)
              .then((gen) => {
                if (gen === null) {
                  pending.reject(
                    new Error(
                      "stale_epoch retry: could not refresh generation",
                    ),
                  );
                  return;
                }
                // Reuse the original caller's resolve/reject so the retry
                // result propagates to the same promise.
                this.resendCommand(pending, gen);
              })
              .catch((err) => pending.reject(err));
            return;
          }
          // §13: a second stale_epoch after a retry was attempted rejects
          // (no loop). Other errors resolve with the result so the caller
          // can inspect the code.
          if (
            env.result.status === "error" &&
            env.result.code === "stale_epoch" &&
            pending.retry.attempted
          ) {
            pending.reject(
              new Error(
                `stale_epoch: generation still stale after retry`,
              ),
            );
            return;
          }
          pending.resolve(env.result);
        } else if (env.result.status === "error") {
          // No pending ack for this messageId — log at debug only.
          console.debug(
            `[wsClient] unsolicited command_ack error: ${env.result.code} — ${env.result.reason}`,
          );
        }
        break;
      }
      case "handoff_candidate":
        this.callbacks.onHandoffCandidate(env);
        break;
      case "prepare_relinquish":
        this.callbacks.onPrepareRelinquish(env);
        break;
      case "handoff_committed":
        this.callbacks.onHandoffCommitted(env);
        break;
      case "handoff_failed":
        this.callbacks.onHandoffFailed(env);
        break;
      case "session_superseded":
        this.callbacks.onSessionSuperseded(env);
        break;
      case "error":
        this.callbacks.onError(env.code, env.reason);
        break;
      case "capability_disabled":
        this.callbacks.onError(
          "protocol_incompatible",
          `feature disabled: ${env.feature}`,
        );
        break;
      default:
        break;
    }
  }

  /// Resend a command with an updated expectedGeneration (stale-epoch
  /// retry, §13). Reuses the original `PendingAck`'s resolve/reject so the
  /// caller's promise resolves/rejects with the retry result. A new
  /// messageId is generated and a fresh timeout timer is armed.
  private resendCommand(pending: PendingAck, newGeneration: SessionGeneration): void {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "command",
      targetDeviceId: pending.retry.targetDeviceId,
      expectedGeneration: newGeneration,
      command: pending.retry.command,
    };
    // Arm a fresh timeout for the retry.
    const timeoutMs = pending.retry.options.timeoutMs ?? DEFAULT_ACK_TIMEOUT_MS;
    pending.timer = setTimeout(() => {
      this.pendingAcks.delete(env.messageId);
      pending.reject(new Error(`command_ack timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    this.pendingAcks.set(env.messageId, pending);
    this.send(env);
  }

  /// Register a pending-ack entry with a timeout timer.
  private trackPendingAck(
    messageId: MessageId,
    retry: PendingAck["retry"],
    options: SendCommandOptions,
  ): Promise<CommandResult> {
    return new Promise<CommandResult>((resolve, reject) => {
      const timeoutMs = options.timeoutMs ?? DEFAULT_ACK_TIMEOUT_MS;
      const timer = setTimeout(() => {
        this.pendingAcks.delete(messageId);
        reject(new Error(`command_ack timeout after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pendingAcks.set(messageId, {
        messageId,
        createdAt: Date.now(),
        resolve,
        reject,
        timer,
        retry,
      });
    });
  }

  private scheduleReconnect() {
    if (this.disposed) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.setState("reconnecting");
    const delay = Math.min(
      BASE_RECONNECT_DELAY_MS * 2 ** this.reconnectAttempts,
      MAX_RECONNECT_DELAY_MS,
    );
    this.reconnectAttempts++;
    this.reconnectTimer = setTimeout(
      () => {
        this.connect();
      },
      delay + Math.random() * 500,
    );
  }

  /// Publish a playback snapshot to the server (design §9.2).
  publishSnapshot(
    sessionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    snapshot: PlaybackSnapshot,
  ) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "snapshot",
      sessionId,
      generation,
      snapshotRevision,
      snapshot,
    };
    this.send(env);
  }

  /// Send a remote control command to a target device (design §10).
  /// Fire-and-forget overload: callers that do not need the `CommandResult`
  /// can ignore the return value (it is `void`).
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ): void;
  /// §9.1 ack overload: when `options.awaitAck` is true, resolves with the
  /// `CommandResult` returned by the server, or rejects after the timeout.
  /// When `options.retryOnStaleEpoch` is true and the server returns
  /// `stale_epoch`, the client refreshes the generation and resends once.
  sendCommandAck(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options: SendCommandOptions,
  ): Promise<CommandResult>;
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options?: SendCommandOptions,
  ): void | Promise<CommandResult> {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "command",
      targetDeviceId,
      expectedGeneration,
      command,
    };
    const opts: SendCommandOptions = options ?? {};
    if (opts.awaitAck) {
      const retry: PendingAck["retry"] = {
        targetDeviceId,
        expectedGeneration,
        command,
        options: opts,
        attempted: false,
      };
      const promise = this.trackPendingAck(env.messageId, retry, opts);
      this.send(env);
      return promise;
    }
    this.send(env);
    return;
  }

  /// §9.1 ack overload — exposed as a named method on the interface so the
  /// manager can call it via `coordClient?.sendCommandAck?.(...)`. Delegates
  /// to the overloaded `sendCommand`.
  sendCommandAck(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
    options: SendCommandOptions,
  ): Promise<CommandResult> {
    const result = this.sendCommand(
      targetDeviceId,
      expectedGeneration,
      command,
      options,
    );
    return result as Promise<CommandResult>;
  }

  /// Request handoff candidate from a source device (design §11.1 step 1).
  requestHandoffCandidate(
    sourceDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    expectedSnapshotRevision: SnapshotRevision,
  ) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "handoff_candidate_request",
      sourceDeviceId,
      expectedGeneration,
      expectedSnapshotRevision,
    };
    this.send(env);
  }

  /// Signal that B has preloaded and is ready (design §11.1 step 3).
  sendTargetReady(
    transactionId: string,
    generation: SessionGeneration,
    snapshotRevision: SnapshotRevision,
    sourceDeviceId?: DeviceId | null,
    sessionId?: SessionId | null,
  ) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "target_ready",
      transactionId,
      generation,
      snapshotRevision,
      sourceDeviceId,
      sessionId,
    };
    this.send(env);
  }

  /// A confirms relinquish with final snapshot (design §11.1 step 5).
  sendRelinquishAck(transactionId: string, snapshot: PlaybackSnapshot) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "relinquish_ack",
      transactionId,
      snapshot,
    };
    this.send(env);
  }

  /// B notifies the server it is starting remote control of
  /// `targetDeviceId` (design §10 exclusivity). The server marks B as an
  /// active controller so other devices cannot remote control or
  /// handoff-take B.
  sendControlSessionBegin(targetDeviceId: DeviceId) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "control_session_begin",
      targetDeviceId,
    };
    this.send(env);
  }

  /// B notifies the server it has stopped remote control (design §10).
  sendControlSessionEnd() {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "control_session_end",
    };
    this.send(env);
  }
}
