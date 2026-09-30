import type {
  CoordinationErrorCode,
  DeviceDto,
  Envelope,
  Payload,
  PlaybackSnapshot,
} from "../../src/coordination/types";
import { ApiError, fail, integer, uuid } from "./security";
import { type Device, type Handoff, type Session, Store } from "./store";
import { command, snapshot } from "./validation";

export interface Attachment {
  deviceId: string;
  connectionId: string;
  joined: boolean;
  capabilities: number;
  lastSeen: number;
  seq: number;
  controlling: string | null;
}
interface AckRoute {
  source: string;
  target: string;
  expires: number;
}
export const OFFLINE_TTL = 8 * 3600_000;
export const GRACE = 45_000;

export class Realtime {
  constructor(
    readonly ctx: DurableObjectState,
    readonly store: Store,
  ) {}
  attachment(ws: WebSocket) {
    return ws.deserializeAttachment() as Attachment;
  }
  sockets() {
    return this.ctx
      .getWebSockets()
      .filter((ws) => ws.readyState === WebSocket.OPEN);
  }
  socket(deviceId: string) {
    return this.sockets().find((ws) => {
      const a = this.attachment(ws);
      return a.deviceId === deviceId && a.joined;
    });
  }
  activeSession(deviceId: string) {
    return this.store
      .list<Session>("session:")
      .filter((s) => s.deviceId === deviceId && !s.transferredTo)
      .sort((a, b) => b.confirmedAt - a.confirmedAt)[0];
  }
  send(ws: WebSocket, payload: Payload, extra: Partial<Envelope> = {}) {
    const a = this.attachment(ws);
    ws.send(
      JSON.stringify({
        version: 1,
        messageId: crypto.randomUUID(),
        serverTime: Math.floor(Date.now() / 1000),
        ...extra,
        ...payload,
        targetDeviceId: a.deviceId,
      }),
    );
  }
  to(deviceId: string, payload: Payload, extra: Partial<Envelope> = {}) {
    const ws = this.socket(deviceId);
    if (ws) this.send(ws, payload, extra);
  }
  device(id: string): Device {
    const d = this.store.get<Device>(`device:${uuid(id)}`);
    if (!d) fail("forbidden", "device does not belong to this account", 403);
    if (d.revokedAt) fail("device_revoked", "device revoked", 401);
    return d;
  }
  devices(): DeviceDto[] {
    return this.store
      .list<Device>("device:")
      .map(({ refreshHash: _hash, refreshUsedAt: _used, ...d }) => {
        const ws = this.socket(d.id);
        return {
          ...d,
          isControlling: Boolean(ws && this.attachment(ws).controlling),
          lastOnlineAt: ws ? new Date().toISOString() : d.lastOnlineAt,
        };
      });
  }
  broadcastDevices() {
    const devices = this.devices();
    for (const ws of this.sockets())
      if (this.attachment(ws).joined)
        this.send(ws, { type: "devices_changed", devices });
  }
  projection(s: Session): Payload {
    return {
      type: "snapshot_projection",
      deviceId: s.deviceId,
      sessionId: s.id,
      generation: s.generation,
      snapshotRevision: s.snapshotRevision,
      snapshot: s.snapshot,
      isOnline: Boolean(this.socket(s.deviceId)),
      lastConfirmedAt: Math.floor(s.confirmedAt / 1000),
    };
  }
  replay(ws: WebSocket) {
    const own = this.attachment(ws).deviceId;
    for (const d of this.devices()) {
      if (d.id === own || d.revokedAt || d.isControlling) continue;
      const s = this.activeSession(d.id);
      if (s && (!s.offlineAt || Date.now() - s.offlineAt <= OFFLINE_TTL))
        this.send(ws, this.projection(s));
    }
  }
  disconnected(ws: WebSocket) {
    const a = this.attachment(ws);
    a.joined = false;
    ws.serializeAttachment(a);
    // A superseded socket's late close must not take a replacement connection offline.
    if (this.socket(a.deviceId)) return;
    const d = this.store.get<Device>(`device:${a.deviceId}`);
    if (d) {
      d.lastOnlineAt = new Date().toISOString();
      this.store.set(`device:${d.id}`, d);
    }
    const s = this.activeSession(a.deviceId);
    if (s) {
      s.offlineAt = Date.now();
      this.store.set(`session:${s.id}`, s);
      for (const peer of this.sockets())
        if (this.attachment(peer).joined) this.send(peer, this.projection(s));
    }
    for (const { key, value } of this.store.entries<AckRoute>("ack:"))
      if (value.target === a.deviceId || value.source === a.deviceId)
        this.store.delete(key);
    for (const txn of this.store.list<Handoff>("handoff:"))
      if (txn.source === a.deviceId || txn.target === a.deviceId)
        this.failHandoff(txn, "target_offline");
    this.broadcastDevices();
  }
  failHandoff(txn: Handoff, code: CoordinationErrorCode) {
    this.store.delete(`handoff:${txn.id}`);
    this.to(txn.target, {
      type: "handoff_failed",
      transactionId: txn.id,
      code,
    });
  }
  commit(txn: Handoff, final: PlaybackSnapshot) {
    let generation = 0;
    this.store.transaction(() => {
      const current = this.store.get<Session>(`session:${txn.sessionId}`);
      if (
        !current ||
        current.deviceId !== txn.source ||
        current.generation !== txn.generation ||
        current.transferredTo
      )
        fail("source_changed", "source session changed");
      if (
        current.snapshot.logicalPlaybackSessionId !==
          final.logicalPlaybackSessionId ||
        final.sessionId !== current.id
      )
        fail("source_changed", "source playback changed");
      generation = current.generation + 1;
      current.generation = generation;
      current.transferredTo = txn.target;
      current.snapshot = final;
      this.store.set(`session:${current.id}`, current);
      // The target owns the transferred session immediately, even before its next snapshot.
      this.store.set(`grant:${current.id}`, {
        target: txn.target,
        generation,
        expires: Date.now() + 7 * 86400_000,
      });
      this.store.set(`superseded:${current.id}:${txn.source}`, {
        target: txn.target,
        generation,
        expires: Date.now() + 7 * 86400_000,
      });
      this.store.delete(`handoff:${txn.id}`);
    });
    this.to(
      txn.target,
      {
        type: "handoff_committed",
        transactionId: txn.id,
        newGeneration: generation,
        snapshot: final,
      },
      {
        sourceDeviceId: txn.source,
        sessionId: txn.sessionId,
        expectedGeneration: generation,
      },
    );
    this.to(
      txn.source,
      {
        type: "session_superseded",
        supersededGeneration: generation,
        transferredToDevice: txn.target,
      },
      { sessionId: txn.sessionId, expectedGeneration: generation },
    );
  }
  handle(ws: WebSocket, env: Envelope) {
    const a = this.attachment(ws);
    this.device(a.deviceId);
    if (env.type === "hello") {
      if (a.joined) fail("bad_message", "already joined");
      if (env.protocolVersion !== 1)
        fail("protocol_incompatible", "server protocol is 1");
      if (env.deviceId && uuid(env.deviceId) !== a.deviceId)
        fail("forbidden", "hello device mismatch");
      integer(env.capabilities, 0, 0xffffffff);
      a.joined = true;
      a.capabilities = env.capabilities & 15;
      ws.serializeAttachment(a);
      this.send(ws, {
        type: "welcome",
        serverProtocolVersion: 1,
        negotiated: a.capabilities,
        connectionId: a.connectionId,
        deviceId: a.deviceId,
        serverTime: Math.floor(Date.now() / 1000),
      });
      this.broadcastDevices();
      this.replay(ws);
      return;
    }
    if (!a.joined) fail("authentication_failed", "hello required", 401);
    if (env.type === "heartbeat") {
      this.send(ws, {
        type: "heartbeat_ack",
        serverTime: Math.floor(Date.now() / 1000),
      });
      return;
    }
    if (env.type === "request_snapshots") {
      this.replay(ws);
      return;
    }
    if (env.type === "snapshot") {
      const s = snapshot(env.snapshot);
      uuid(env.sessionId);
      integer(env.generation, 1);
      integer(env.snapshotRevision);
      if (env.sessionId !== s.sessionId)
        fail("bad_message", "session mismatch");
      const superseded = this.store.get<{ target: string; generation: number }>(
        `superseded:${s.sessionId}:${a.deviceId}`,
      );
      const grantForDevice = this.store.get<{
        target: string;
        generation: number;
      }>(`grant:${s.sessionId}`);
      if (superseded && grantForDevice?.target !== a.deviceId) {
        this.send(ws, {
          type: "session_superseded",
          supersededGeneration: superseded.generation,
          transferredToDevice: superseded.target,
        });
        return;
      }
      const prior = this.store.get<Session>(`session:${s.sessionId}`);
      const grant = this.store.get<{ target: string; generation: number }>(
        `grant:${s.sessionId}`,
      );
      if (
        prior?.transferredTo &&
        !(grant?.target === a.deviceId && grant.generation === env.generation)
      ) {
        this.send(ws, {
          type: "session_superseded",
          supersededGeneration: prior.generation,
          transferredToDevice: prior.transferredTo,
        });
        return;
      }
      if (
        prior &&
        prior.deviceId !== a.deviceId &&
        grant?.target !== a.deviceId
      )
        fail("forbidden", "session belongs to another device");
      if (
        prior &&
        !grant &&
        (env.generation < prior.generation ||
          (env.generation === prior.generation &&
            env.snapshotRevision < prior.snapshotRevision))
      )
        fail("stale_epoch", "stale snapshot");
      const current: Session = {
        id: s.sessionId,
        deviceId: a.deviceId,
        generation: env.generation,
        snapshotRevision: env.snapshotRevision,
        snapshot: s,
        confirmedAt: Date.now(),
        offlineAt: null,
        transferredTo: null,
      };
      this.store.transaction(() => {
        this.store.set(`session:${s.sessionId}`, current);
        this.store.delete(`grant:${s.sessionId}`);
        // New activity replaces this device's older snapshots, including offline candidates.
        for (const old of this.store.list<Session>("session:"))
          if (
            old.deviceId === a.deviceId &&
            old.id !== s.sessionId &&
            !old.transferredTo
          )
            this.store.delete(`session:${old.id}`);
      });
      for (const peer of this.sockets())
        if (
          peer !== ws &&
          this.attachment(peer).joined &&
          this.attachment(peer).capabilities & 2
        )
          this.send(peer, this.projection(current));
      return;
    }
    if (env.type === "command") {
      try {
        this.device(env.targetDeviceId);
        integer(env.expectedGeneration, 1);
        const c = command(env.command);
        const target = this.socket(env.targetDeviceId);
        if (!target) fail("target_offline", "target device is offline");
        if (this.attachment(target).controlling)
          fail("forbidden", "target is controlling another device");
        const s = this.activeSession(env.targetDeviceId);
        if (s && s.generation !== env.expectedGeneration)
          fail("stale_epoch", "session generation mismatch");
        if (this.store.get(`ack:${env.messageId}`))
          fail("bad_message", "command ID already pending");
        this.store.set(`ack:${env.messageId}`, {
          source: a.deviceId,
          target: env.targetDeviceId,
          expires: Date.now() + 30000,
        } satisfies AckRoute);
        this.send(
          target,
          {
            type: "command",
            messageId: env.messageId,
            targetDeviceId: env.targetDeviceId,
            expectedGeneration: env.expectedGeneration,
            command: c,
          } as Envelope,
          { sourceDeviceId: a.deviceId },
        );
      } catch (error) {
        if (!(error instanceof ApiError)) throw error;
        this.send(ws, {
          type: "command_ack",
          messageId: env.messageId,
          result: { status: "error", code: error.code, reason: error.message },
        });
      }
      return;
    }
    if (env.type === "command_ack") {
      const route = this.store.get<AckRoute>(`ack:${env.messageId}`);
      if (route?.target !== a.deviceId || route.expires < Date.now())
        fail("forbidden", "no pending acknowledgement");
      if (!env.result || !["ok", "error"].includes(env.result.status))
        fail("bad_message", "invalid acknowledgement");
      this.store.delete(`ack:${env.messageId}`);
      this.to(
        route.source,
        { type: "command_ack", messageId: env.messageId, result: env.result },
        { sourceDeviceId: a.deviceId },
      );
      return;
    }
    if (env.type === "control_session_begin") {
      this.device(env.targetDeviceId);
      if (env.targetDeviceId === a.deviceId)
        fail("bad_message", "cannot control self");
      a.controlling = env.targetDeviceId;
      ws.serializeAttachment(a);
      this.broadcastDevices();
      return;
    }
    if (env.type === "control_session_end") {
      a.controlling = null;
      ws.serializeAttachment(a);
      this.broadcastDevices();
      return;
    }
    if (env.type === "handoff_candidate_request") {
      this.device(env.sourceDeviceId);
      if (env.sourceDeviceId === a.deviceId)
        fail("bad_message", "cannot handoff to self");
      const source = this.socket(env.sourceDeviceId);
      if (source && this.attachment(source).controlling)
        fail("forbidden", "source is controlling another device");
      const s = this.activeSession(env.sourceDeviceId);
      if (!s) fail("target_offline", "source has no active session");
      if (s.offlineAt && Date.now() - s.offlineAt > OFFLINE_TTL)
        fail("snapshot_expired", "offline snapshot expired");
      if (s.generation !== env.expectedGeneration)
        fail("stale_epoch", "session generation mismatch");
      if (s.snapshotRevision !== env.expectedSnapshotRevision)
        fail("source_changed", "source snapshot changed");
      const txn: Handoff = {
        id: crypto.randomUUID(),
        source: env.sourceDeviceId,
        target: a.deviceId,
        sessionId: s.id,
        generation: s.generation,
        snapshotRevision: s.snapshotRevision,
        deadline: Date.now() + 15000,
        phase: "candidate",
      };
      this.store.set(`handoff:${txn.id}`, txn);
      this.send(
        ws,
        {
          type: "handoff_candidate",
          transactionId: txn.id,
          snapshot: s.snapshot,
          generation: s.generation,
          snapshotRevision: s.snapshotRevision,
          deadline: Math.floor(txn.deadline / 1000),
        },
        { sourceDeviceId: txn.source, sessionId: txn.sessionId },
      );
      return;
    }
    if (env.type === "target_ready") {
      // Clients can preload a cached projection and choose their own transaction UUID.
      uuid(env.transactionId);
      uuid(env.sourceDeviceId);
      uuid(env.sessionId);
      integer(env.generation, 1);
      integer(env.snapshotRevision);
      const sourceId = env.sourceDeviceId as string;
      this.device(sourceId);
      if (sourceId === a.deviceId)
        fail("bad_message", "cannot handoff to self");
      const prior = this.store.get<Handoff>(`handoff:${env.transactionId}`);
      if (
        prior &&
        (prior.target !== a.deviceId ||
          prior.source !== sourceId ||
          prior.sessionId !== env.sessionId ||
          prior.phase !== "candidate")
      )
        fail("handoff_conflict", "transaction mismatch");
      const s = this.store.get<Session>(`session:${env.sessionId}`);
      if (!s || s.deviceId !== sourceId || s.transferredTo)
        fail("handoff_conflict", "source unavailable");
      if (s.generation !== env.generation)
        fail("stale_epoch", "source generation changed");
      if (prior && prior.deadline < Date.now())
        fail("source_pause_timeout", "candidate expired");
      for (const pending of this.store.list<Handoff>("handoff:"))
        if (
          pending.sessionId === s.id &&
          pending.phase === "relinquish" &&
          pending.deadline > Date.now()
        )
          fail("handoff_conflict", "handoff already in progress");
      const txn: Handoff = {
        id: env.transactionId,
        source: sourceId,
        target: a.deviceId,
        sessionId: s.id,
        generation: s.generation,
        snapshotRevision: env.snapshotRevision,
        deadline: Date.now() + 15_000,
        phase: "relinquish",
      };
      const source = this.socket(sourceId);
      if (source && this.attachment(source).controlling)
        fail("forbidden", "source is controlling another device");
      if (!source) {
        if (!s.offlineAt || Date.now() - s.offlineAt > OFFLINE_TTL)
          fail("snapshot_expired", "offline snapshot expired");
        this.commit(txn, s.snapshot);
      } else {
        this.store.set(`handoff:${txn.id}`, txn);
        this.send(
          source,
          {
            type: "prepare_relinquish",
            transactionId: txn.id,
            expectedSnapshotRevision: txn.snapshotRevision,
            deadline: Math.floor(txn.deadline / 1000),
          },
          { sessionId: s.id, expectedGeneration: s.generation },
        );
      }
      return;
    }
    if (env.type === "relinquish_ack") {
      const txn = this.store.get<Handoff>(`handoff:${uuid(env.transactionId)}`);
      if (!txn || txn.source !== a.deviceId || txn.phase !== "relinquish")
        fail("forbidden", "not the relinquishing device");
      if (txn.deadline < Date.now()) {
        this.failHandoff(txn, "source_pause_timeout");
        return;
      }
      if (!this.socket(txn.target)) {
        this.failHandoff(txn, "target_offline");
        return;
      }
      this.commit(txn, snapshot(env.snapshot));
      return;
    }
    fail("bad_message", "unexpected client message");
  }
}
