// Coordination WebSocket client (design §9).
// Handles connection lifecycle, reconnection with exponential backoff,
// heartbeat, snapshot publish/subscribe, and remote command routing.

import { COORDINATION_PROTOCOL_VERSION, CoordinationCapability } from "./types";
import type {
  ConnectionId,
  ConnectionSeq,
  CoordinationCapabilities,
  DeviceId,
  Envelope,
  PlaybackSnapshot,
  RemoteCommand,
  SessionGeneration,
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
  onError: (code: string, reason: string) => void;
}

const HEARTBEAT_INTERVAL_MS = 15_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const BASE_RECONNECT_DELAY_MS = 1_000;

export class CoordinationWsClient {
  private ws: WebSocket | null = null;
  private state: ConnectionState = "disconnected";
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private lastSeq: ConnectionSeq = 0;
  private negotiatedCaps: CoordinationCapabilities =
    CoordinationCapability.NONE;
  private disposed = false;

  constructor(
    private readonly urlFn: () => string,
    private readonly ticketFn: () => Promise<string | null>,
    private readonly deviceId: DeviceId | null,
    private readonly capabilities: CoordinationCapabilities,
    private readonly callbacks: ConnectionCallbacks,
  ) {}

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
    switch (env.type) {
      case "welcome":
        this.negotiatedCaps = env.negotiated;
        this.lastSeq = env.seq ?? this.lastSeq;
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
  sendCommand(
    targetDeviceId: DeviceId,
    expectedGeneration: SessionGeneration,
    command: RemoteCommand,
  ) {
    const env: Envelope = {
      version: COORDINATION_PROTOCOL_VERSION,
      messageId: crypto.randomUUID(),
      type: "command",
      targetDeviceId,
      expectedGeneration,
      command,
    };
    this.send(env);
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
}
