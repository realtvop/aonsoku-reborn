import { randomUUID } from "node:crypto";
import type {
  CoordinationConfigOptions,
  CoordinationConnectOptions,
  CoordinationHttpRequestOptions,
  CoordinationSnapshotOptions,
  CoordinationTokenOptions,
} from "@aonsoku/capacitor-native/coordination";
import WebSocket from "ws";
import { AonsokuStore } from "../../core/store";

interface CoordinationStore {
  tokens?: CoordinationTokenOptions;
  config?: CoordinationConfigOptions;
  lastSeq?: number;
}

type Emit = (event: string, payload: unknown) => void;

export class DesktopNativeCoordinationService {
  private readonly store = new AonsokuStore<CoordinationStore>({
    name: "native-coordination",
  });
  private ws: WebSocket | null = null;
  private state:
    | "disconnected"
    | "connecting"
    | "connected"
    | "reconnecting"
    | "error" = "disconnected";
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private generationByDevice = new Map<string, number>();
  private revisionByDevice = new Map<string, number>();
  private activeControlTarget: string | null = null;

  constructor(private readonly emit: Emit) {}

  storeTokens(options: CoordinationTokenOptions): void {
    this.store.set("tokens", options);
  }
  loadTokens(): CoordinationTokenOptions | null {
    return this.store.get("tokens") ?? null;
  }
  clearTokens(): void {
    this.store.delete("tokens");
  }
  storeConfig(options: CoordinationConfigOptions): void {
    this.store.set("config", options);
  }
  loadConfig(): CoordinationConfigOptions | null {
    return this.store.get("config") ?? null;
  }

  async request(options: CoordinationHttpRequestOptions) {
    const response = await fetch(options.url, {
      method: options.method,
      headers: options.headers,
      body: options.body,
      signal: AbortSignal.timeout(30_000),
    });
    return {
      status: response.status,
      statusText: response.statusText,
      body: await response.text(),
    };
  }

  async connect(options: CoordinationConnectOptions): Promise<void> {
    await this.disconnect();
    this.setState("connecting", options.deviceId);
    const url = `${options.wsUrl}?ticket=${encodeURIComponent(options.ticket)}`;
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(url);
      this.ws = ws;
      ws.once("open", () => {
        this.setState("connected", options.deviceId);
        this.send({
          version: options.protocolVersion,
          messageId: randomUUID(),
          type: "hello",
          protocolVersion: options.protocolVersion,
          capabilities: options.capabilities,
          deviceId: options.deviceId,
          ticket: options.ticket,
          lastSeq: options.lastSeq ?? this.store.get("lastSeq") ?? 0,
        });
        this.heartbeat = setInterval(() => {
          this.send({ version: 1, messageId: randomUUID(), type: "heartbeat" });
        }, 15_000);
        resolve();
      });
      ws.on("message", (data) => this.handleMessage(data.toString()));
      ws.once("error", (error) => {
        this.setState("error", options.deviceId);
        reject(error);
      });
      ws.on("close", () => {
        this.stopHeartbeat();
        if (this.ws === ws) this.ws = null;
        this.setState("reconnecting", options.deviceId);
        this.emit("coordinationReconnectNeeded", {});
      });
    });
  }

  async disconnect(): Promise<void> {
    this.stopHeartbeat();
    const ws = this.ws;
    this.ws = null;
    if (ws) {
      ws.removeAllListeners("close");
      ws.close();
    }
    this.setState("disconnected", null);
  }

  getState() {
    return { state: this.state, deviceId: this.loadTokens()?.deviceId ?? null };
  }

  publishSnapshot(options: CoordinationSnapshotOptions): void {
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "snapshot",
      sessionId: options.sessionId,
      generation: options.generation,
      snapshotRevision: options.snapshotRevision,
      snapshot: JSON.parse(options.snapshotJson),
    });
  }

  sendCommand(options: {
    targetDeviceId: string;
    expectedGeneration: number;
    commandJson: string;
    messageId?: string;
  }): void {
    this.send({
      version: 1,
      messageId: options.messageId ?? randomUUID(),
      type: "command",
      targetDeviceId: options.targetDeviceId,
      expectedGeneration: options.expectedGeneration,
      command: JSON.parse(options.commandJson),
    });
  }

  sendActiveControlCommand(options: { commandJson: string }): void {
    if (!this.activeControlTarget) throw new Error("No active control target");
    const generation = this.generationByDevice.get(this.activeControlTarget);
    if (generation === undefined)
      throw new Error("No generation for active target");
    this.sendCommand({
      targetDeviceId: this.activeControlTarget,
      expectedGeneration: generation,
      commandJson: options.commandJson,
    });
  }

  requestHandoffCandidate(
    sourceDeviceId: string,
    expectedGeneration: number,
    expectedSnapshotRevision: number,
  ): void {
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "handoff_candidate_request",
      sourceDeviceId,
      expectedGeneration,
      expectedSnapshotRevision,
    });
  }

  requestHandoffCandidateFromCache({
    sourceDeviceId,
  }: {
    sourceDeviceId: string;
  }): void {
    const generation = this.generationByDevice.get(sourceDeviceId);
    const revision = this.revisionByDevice.get(sourceDeviceId);
    if (generation === undefined || revision === undefined)
      throw new Error("No cached source snapshot");
    this.requestHandoffCandidate(sourceDeviceId, generation, revision);
  }

  sendTargetReady(
    transactionId: string,
    generation: number,
    snapshotRevision: number,
    sourceDeviceId: string,
    sessionId: string,
  ): void {
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "target_ready",
      transactionId,
      generation,
      snapshotRevision,
      sourceDeviceId,
      sessionId,
    });
  }

  sendRelinquishAck(options: {
    transactionId: string;
    snapshotJson: string;
  }): void {
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "relinquish_ack",
      transactionId: options.transactionId,
      snapshot: JSON.parse(options.snapshotJson),
    });
  }

  sendControlSessionBegin({
    targetDeviceId,
  }: {
    targetDeviceId: string;
  }): void {
    this.activeControlTarget = targetDeviceId;
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "control_session_begin",
      targetDeviceId,
    });
  }

  sendControlSessionEnd(): void {
    this.activeControlTarget = null;
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "control_session_end",
    });
  }

  requestSnapshots(): void {
    this.send({
      version: 1,
      messageId: randomUUID(),
      type: "request_snapshots",
    });
  }

  private send(envelope: Record<string, unknown>): void {
    if (this.ws?.readyState === WebSocket.OPEN)
      this.ws.send(JSON.stringify(envelope));
  }

  private handleMessage(raw: string): void {
    let envelope: Record<string, unknown>;
    try {
      envelope = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }
    if (typeof envelope.seq === "number")
      this.store.set("lastSeq", envelope.seq);
    if (
      envelope.type === "snapshot_projection" &&
      typeof envelope.deviceId === "string"
    ) {
      if (typeof envelope.generation === "number")
        this.generationByDevice.set(envelope.deviceId, envelope.generation);
      if (typeof envelope.snapshotRevision === "number")
        this.revisionByDevice.set(envelope.deviceId, envelope.snapshotRevision);
    }
    if (envelope.type === "command_ack") {
      this.emit("coordinationAck", {
        messageId: envelope.messageId,
        resultJson: JSON.stringify(envelope.result),
      });
      return;
    }
    this.emit("coordinationEvent", { envelopeJson: raw });
  }

  private setState(state: typeof this.state, deviceId: string | null): void {
    this.state = state;
    this.emit("coordinationStateChange", { state, deviceId });
  }

  private stopHeartbeat(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
  }
}
