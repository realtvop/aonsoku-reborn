import { DurableObject } from "cloudflare:workers";
import type {
  Envelope,
  LegacyImportRequest,
} from "../../src/coordination/types";
import { applyOperation, mergeLegacy, operationInput } from "./history";
import { type Attachment, GRACE, OFFLINE_TTL, Realtime } from "./realtime";
import {
  ApiError,
  accountId,
  body,
  canonicalUser,
  type Env,
  errorResponse,
  fail,
  hash,
  identity,
  integer,
  json,
  object,
  sign,
  string,
  uuid,
  verify,
  verifyCredentials,
} from "./security";
import {
  type Device,
  type Entry,
  type Handoff,
  type Meta,
  type Session,
  Store,
  type Timed,
  type Tombstone,
} from "./store";
import { envelope } from "./validation";

interface Challenge extends Timed {
  identity: string;
  user: string;
}
interface Ticket extends Timed {
  deviceId: string;
}

export class AccountCoordinator extends DurableObject<Env, unknown> {
  readonly store: Store;
  readonly realtime: Realtime;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new Store(ctx.storage);
    this.realtime = new Realtime(ctx, this.store);
    // After host loss there may be persisted online sessions without live sockets.
    // Hibernation retains sockets; only absent owners become frozen candidates.
    for (const session of this.store.list<Session>("session:")) {
      if (
        !session.offlineAt &&
        !session.transferredTo &&
        !this.realtime.socket(session.deviceId)
      ) {
        session.offlineAt = session.confirmedAt;
        this.store.set(`session:${session.id}`, session);
      }
    }
  }
  meta() {
    const meta = this.store.get<Meta>("meta");
    if (!meta) fail("not_found", "account not found", 404);
    return meta;
  }
  consumeChallenge(input: Record<string, unknown>) {
    const id = uuid(input.challengeId);
    const challenge = this.store.get<Challenge>(`challenge:${id}`);
    this.store.delete(`challenge:${id}`);
    if (!challenge || challenge.expires < Date.now())
      fail("challenge_expired", "challenge expired");
    if (
      challenge.identity !== identity(input.identityUrl, this.env) ||
      challenge.user !== canonicalUser(input.username)
    )
      fail("challenge_expired", "challenge identity mismatch");
  }
  async rotatedTokens(device: Device, account: string, expectedHash?: string) {
    const refreshToken = await sign(this.env.STABLE_KEY, {
      kind: "refresh",
      account_id: account,
      device_id: device.id,
      nonce: crypto.randomUUID(),
      exp: Math.floor(Date.now() / 1000) + 90 * 86400,
    });
    const refreshHash = await hash(refreshToken);
    const accessToken = await sign(this.env.STABLE_KEY, {
      device_id: device.id,
      account_id: account,
      exp: Math.floor(Date.now() / 1000) + 900,
    });
    // Crypto awaits may allow a concurrent rotation. Compare the hash again at commit.
    this.store.transaction(() => {
      const current = this.store.get<Device>(`device:${device.id}`);
      if (current?.revokedAt) fail("device_revoked", "device revoked", 401);
      if (expectedHash && current?.refreshHash !== expectedHash)
        fail("authentication_failed", "refresh token already rotated", 401);
      device.refreshHash = refreshHash;
      device.refreshUsedAt = Date.now();
      this.store.set(
        `device:${device.id}`,
        current
          ? { ...current, refreshHash, refreshUsedAt: device.refreshUsedAt }
          : device,
      );
    });
    return { accessToken, refreshToken, expiresIn: 900 };
  }
  async authenticated(request: Request, account: string) {
    const token = request.headers.get("Authorization")?.replace(/^Bearer /, "");
    const claims = await verify(this.env.STABLE_KEY, string(token));
    if (claims.account_id !== account || this.meta().accountId !== account)
      fail("forbidden", "account mismatch", 403);
    return this.realtime.device(uuid(claims.device_id));
  }
  async fetch(request: Request): Promise<Response> {
    try {
      return await this.route(request);
    } catch (error) {
      return errorResponse(error);
    }
  }
  async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    if (path === "/readyz") {
      this.ctx.storage.sql.exec("SELECT 1");
      return json({ status: "ready" });
    }
    const account = uuid(request.headers.get("X-Account-Id"));
    if (request.method === "POST" && path === "/v1/auth/challenge") {
      const input = await body(request);
      const normalized = identity(input.identityUrl, this.env);
      const user = canonicalUser(input.username);
      if (!user) fail("invalid_identity", "empty username");
      const expected = await accountId(this.env.STABLE_KEY, normalized, user);
      if (expected !== account) fail("forbidden", "account mismatch", 403);
      // Bound outstanding anonymous challenges per identity.
      const now = Date.now();
      for (const { key, value } of this.store.entries<Timed>("challenge:"))
        if (value.expires < now) this.store.delete(key);
      if (this.store.list("challenge:").length >= 32)
        fail("rate_limited", "too many challenges", 429);
      const challengeId = crypto.randomUUID();
      this.store.set(`challenge:${challengeId}`, {
        identity: normalized,
        user,
        expires: now + 60000,
      } satisfies Challenge);
      await this.scheduleAlarm();
      return json({ challengeId });
    }
    if (request.method === "POST" && path === "/v1/auth/register") {
      const input = await body(request);
      const name = string(input.deviceName, 256);
      const platform = string(input.platform, 128);
      if (
        input.clientVersion !== undefined &&
        typeof input.clientVersion !== "string"
      )
        fail("bad_message", "invalid client version");
      const capabilities = integer(input.capabilities ?? 0, 0, 0xffffffff);
      this.consumeChallenge(input);
      await verifyCredentials(this.env, input);
      if (this.store.list("device:").length >= 100)
        fail("rate_limited", "device limit reached", 429);
      if (!this.store.get("meta"))
        this.store.set("meta", {
          accountId: account,
          historyLimit: 100,
          historyGeneration: 1,
          historyRevision: 0,
        } satisfies Meta);
      const device: Device = {
        id: crypto.randomUUID(),
        name,
        platform,
        clientVersion: (input.clientVersion as string) ?? null,
        capabilities,
        createdAt: new Date().toISOString(),
        lastOnlineAt: null,
        revokedAt: null,
        historySyncCursor: 0,
        legacyHistoryImported: false,
        refreshHash: "",
        refreshUsedAt: Date.now(),
      };
      const tokens = await this.rotatedTokens(device, account);
      this.realtime.broadcastDevices();
      return json(
        {
          deviceId: device.id,
          accountId: account,
          historyLimit: this.meta().historyLimit,
          ...tokens,
        },
        201,
      );
    }
    if (request.method === "POST" && path === "/v1/auth/token") {
      const input = await body(request);
      const device = this.realtime.device(uuid(input.deviceId));
      const providedHash = await hash(string(input.refreshToken));
      let valid = false;
      try {
        const claims = await verify(
          this.env.STABLE_KEY,
          string(input.refreshToken),
          "refresh",
        );
        valid =
          claims.account_id === account &&
          claims.device_id === device.id &&
          providedHash === device.refreshHash &&
          Date.now() - device.refreshUsedAt <= 90 * 86400_000;
      } catch (error) {
        if (error instanceof ApiError && error.code === "not_ready")
          throw error;
      }
      if (!valid) {
        if (!input.challengeId)
          fail("authentication_failed", "invalid refresh token", 401);
        this.consumeChallenge(input);
        const recovered = await accountId(
          this.env.STABLE_KEY,
          identity(input.identityUrl, this.env),
          canonicalUser(input.username),
        );
        if (recovered !== account)
          fail("authentication_failed", "account mismatch", 401);
        await verifyCredentials(this.env, input);
      }
      return json(
        await this.rotatedTokens(
          device,
          account,
          valid ? providedHash : device.refreshHash,
        ),
      );
    }
    if (request.method === "GET" && path === "/v1/realtime") {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket")
        fail("bad_message", "WebSocket upgrade required", 426);
      const raw = string(url.searchParams.get("ticket"));
      const claims = await verify(this.env.STABLE_KEY, raw, "ticket");
      const digest = await hash(raw);
      const ticket = this.store.get<Ticket>(`ticket:${digest}`);
      this.store.delete(`ticket:${digest}`);
      if (
        !ticket ||
        ticket.expires < Date.now() ||
        claims.account_id !== account ||
        claims.device_id !== ticket.deviceId
      )
        fail("ticket_expired", "ticket expired or used", 401);
      this.realtime.device(ticket.deviceId);
      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      // Close and detach the old connection before accepting the replacement.
      for (const old of this.realtime.sockets()) {
        const a = this.realtime.attachment(old);
        if (a.deviceId === ticket.deviceId) {
          a.joined = false;
          old.serializeAttachment(a);
          old.close(1000, "connection replaced");
        }
      }
      this.ctx.acceptWebSocket(server, [ticket.deviceId]);
      server.serializeAttachment({
        deviceId: ticket.deviceId,
        connectionId: crypto.randomUUID(),
        joined: false,
        capabilities: 0,
        lastSeen: Date.now(),
        seq: 0,
        controlling: null,
      } satisfies Attachment);
      await this.scheduleAlarm();
      return new Response(null, { status: 101, webSocket: client });
    }
    const device = await this.authenticated(request, account);
    if (request.method === "POST" && path === "/v1/auth/ws-ticket") {
      const input = await body(request);
      if (input.deviceId && input.deviceId !== device.id)
        fail("forbidden", "device mismatch", 403);
      if (this.store.list("ticket:").length > 100)
        fail("rate_limited", "too many tickets", 429);
      const ticket = await sign(this.env.STABLE_KEY, {
        kind: "ticket",
        account_id: account,
        device_id: device.id,
        nonce: crypto.randomUUID(),
        exp: Math.floor(Date.now() / 1000) + 30,
      });
      this.store.set(`ticket:${await hash(ticket)}`, {
        deviceId: device.id,
        expires: Date.now() + 30000,
      } satisfies Ticket);
      await this.scheduleAlarm();
      return json({ ticket, expiresIn: 30 });
    }
    if (request.method === "GET" && path === "/v1/devices")
      return json(this.realtime.devices());
    if (path.startsWith("/v1/devices/")) {
      const target = this.realtime.device(
        uuid(path.slice("/v1/devices/".length)),
      );
      if (request.method === "PATCH") {
        target.name = string((await body(request)).name, 256);
        this.store.set(`device:${target.id}`, target);
        this.realtime.broadcastDevices();
        return json(this.realtime.devices().find((d) => d.id === target.id));
      }
      if (request.method === "DELETE") {
        target.revokedAt = new Date().toISOString();
        this.store.set(`device:${target.id}`, target);
        for (const ws of this.realtime.sockets())
          if (this.realtime.attachment(ws).deviceId === target.id) {
            ws.close(1008, "device revoked");
            this.realtime.disconnected(ws);
          }
        for (const { key, value } of this.store.entries<Ticket>("ticket:"))
          if (value.deviceId === target.id) this.store.delete(key);
        this.realtime.broadcastDevices();
        return new Response(null, {
          status: 204,
          headers: { "Access-Control-Allow-Origin": "*" },
        });
      }
    }
    if (request.method === "DELETE" && path === "/v1/account") {
      for (const ws of this.realtime.sockets()) {
        const a = this.realtime.attachment(ws);
        a.joined = false;
        ws.serializeAttachment(a);
        ws.close(1000, "account deleted");
      }
      this.store.clear();
      await this.ctx.storage.deleteAlarm();
      return new Response(null, {
        status: 204,
        headers: { "Access-Control-Allow-Origin": "*" },
      });
    }
    if (request.method === "GET" && path === "/v1/history") {
      const after = integer(
        Number(url.searchParams.get("after_revision") ?? 0),
      );
      const limit = Math.min(
        1000,
        integer(Number(url.searchParams.get("limit") ?? 100), 1),
      );
      const meta = this.meta();
      const entries = this.store
        .list<Entry>("history:")
        .filter((e) => e.revision > after)
        .sort((a, b) => a.revision - b.revision)
        .slice(0, limit);
      const tombstones = this.store
        .list<Tombstone>("tombstone:")
        .filter((e) => e.revision > after)
        .sort((a, b) => a.revision - b.revision)
        .slice(0, limit)
        .map(({ expires: _expires, ...t }) => t);
      return json({
        entries,
        tombstones,
        historyGeneration: meta.historyGeneration,
        latestRevision: meta.historyRevision,
        historyLimit: meta.historyLimit,
      });
    }
    if (request.method === "POST" && path === "/v1/history") {
      const input = await body(request);
      if (!Array.isArray(input.operations) || input.operations.length > 1000)
        fail("bad_message", "invalid operations list");
      const operations = input.operations.map(operationInput);
      const results = operations.map((op) => applyOperation(this.store, op));
      await this.scheduleAlarm();
      return json({ results });
    }
    if (request.method === "POST" && path === "/v1/history/legacy-import") {
      const input = await body(request);
      if (!Array.isArray(input.entries) || input.entries.length > 1000)
        fail("bad_message", "invalid legacy entries");
      const entries = input.entries as LegacyImportRequest["entries"];
      for (const entry of entries)
        operationInput({
          ...object(entry),
          kind: "add",
          operationId: crypto.randomUUID(),
        });
      if (device.legacyHistoryImported)
        fail("bad_message", "legacy import already performed");
      const current = this.store
        .list<Entry>("history:")
        .sort((a, b) => b.revision - a.revision)
        .map((e) => e.songId);
      const mergedSongIds = mergeLegacy(
        current,
        entries.map((e) => e.songId),
      );
      this.store.transaction(() => {
        for (const entry of entries)
          if (!current.includes(entry.songId))
            applyOperation(this.store, {
              ...entry,
              kind: "add",
              operationId: crypto.randomUUID(),
            });
        device.legacyHistoryImported = true;
        this.store.set(`device:${device.id}`, device);
      });
      await this.scheduleAlarm();
      return json({ mergedSongIds, isFirstDevice: current.length === 0 });
    }
    fail("not_found", "route not found", 404);
  }
  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    let message: Envelope | undefined;
    try {
      message = envelope(raw);
      const a = this.realtime.attachment(ws);
      // Replaced/closing sockets cannot mutate the account after replacement.
      if (
        !this.ctx.getWebSockets(a.deviceId).includes(ws) ||
        ws.readyState !== WebSocket.OPEN
      )
        return;
      a.lastSeen = Date.now();
      a.seq = message.seq ?? a.seq + 1;
      ws.serializeAttachment(a);
      this.realtime.handle(ws, message);
      if (
        ["handoff_candidate_request", "target_ready", "command"].includes(
          message.type,
        )
      )
        await this.scheduleAlarm();
    } catch (error) {
      const e =
        error instanceof ApiError
          ? error
          : new ApiError("internal", "internal server error", 500);
      if (message?.type === "target_ready") {
        this.realtime.send(ws, {
          type: "handoff_failed",
          transactionId: message.transactionId,
          code: e.code,
        });
      } else {
        this.realtime.send(ws, {
          type: "error",
          code: e.code,
          reason: e.message,
        });
        if (message?.type === "relinquish_ack") {
          const txn = this.store.get<Handoff>(
            `handoff:${message.transactionId}`,
          );
          if (txn?.source === this.realtime.attachment(ws).deviceId)
            this.realtime.failHandoff(txn, e.code);
        }
      }
      if (
        e.code === "authentication_failed" ||
        e.code === "device_revoked" ||
        e.code === "protocol_incompatible"
      ) {
        ws.close(1008, e.code);
        this.realtime.disconnected(ws);
      }
    }
  }
  async webSocketClose(ws: WebSocket, code: number) {
    ws.close(code === 1005 ? 1000 : code);
    this.realtime.disconnected(ws);
    await this.scheduleAlarm();
  }
  async webSocketError(ws: WebSocket) {
    ws.close(1011, "connection error");
    this.realtime.disconnected(ws);
    await this.scheduleAlarm();
  }
  async scheduleAlarm() {
    const now = Date.now();
    let next = Number.POSITIVE_INFINITY;
    for (const ws of this.realtime.sockets()) {
      const a = this.realtime.attachment(ws);
      next = Math.min(next, a.lastSeen + (a.joined ? GRACE : 10000));
    }
    for (const txn of this.store.list<Handoff>("handoff:"))
      next = Math.min(next, txn.deadline);
    for (const prefix of [
      "challenge:",
      "ticket:",
      "ack:",
      "operation:",
      "tombstone:",
      "grant:",
      "superseded:",
    ])
      for (const value of this.store.list<Timed>(prefix))
        next = Math.min(next, value.expires);
    for (const session of this.store.list<Session>("session:")) {
      if (session.offlineAt)
        next = Math.min(next, session.offlineAt + OFFLINE_TTL);
      if (session.transferredTo)
        next = Math.min(next, session.confirmedAt + 7 * 86400_000);
    }
    if (!Number.isFinite(next)) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const existing = await this.ctx.storage.getAlarm();
    if (!existing || existing > next)
      await this.ctx.storage.setAlarm(Math.max(now + 100, next));
  }
  async alarm() {
    const now = Date.now();
    for (const ws of this.realtime.sockets()) {
      const a = this.realtime.attachment(ws);
      if (a.lastSeen + (a.joined ? GRACE : 10000) <= now) {
        ws.close(1001, "heartbeat timeout");
        this.realtime.disconnected(ws);
      }
    }
    for (const txn of this.store.list<Handoff>("handoff:"))
      if (txn.deadline <= now)
        this.realtime.failHandoff(txn, "source_pause_timeout");
    for (const prefix of [
      "challenge:",
      "ticket:",
      "ack:",
      "operation:",
      "tombstone:",
      "grant:",
      "superseded:",
    ])
      for (const { key, value } of this.store.entries<Timed>(prefix))
        if (value.expires <= now) this.store.delete(key);
    for (const { key, value: s } of this.store.entries<Session>("session:"))
      if (
        (s.offlineAt && now - s.offlineAt > OFFLINE_TTL) ||
        (s.transferredTo && now - s.confirmedAt > 7 * 86400_000)
      )
        this.store.delete(key);
    // Park accounts with no pending deadlines rather than waking them daily.
    await this.ctx.storage.deleteAlarm();
    await this.scheduleAlarm();
  }
}
