import { build } from "esbuild";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type {
  Envelope,
  PlaybackSnapshot,
  RegisterResponse,
} from "../../src/coordination/types";

let mf: Miniflare;
let rejectProof = false;
let proofRequests = 0;
const sockets: { close(): void }[] = [];
const origin = "https://coord.example";
const identityUrl = "https://music.example/music";

async function api(
  path: string,
  input?: unknown,
  token?: string,
  method = input === undefined ? "GET" : "POST",
) {
  return mf.dispatchFetch(`${origin}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: input === undefined ? undefined : JSON.stringify(input),
  });
}
async function register(username = "alice") {
  const c = await api("/v1/auth/challenge", { identityUrl, username });
  expect(c.status).toBe(200);
  const { challengeId } = (await c.json()) as { challengeId: string };
  const r = await api("/v1/auth/register", {
    challengeId,
    identityUrl,
    username,
    authMode: "password",
    password: "enc:6162",
    deviceName: "test",
    platform: "web",
    capabilities: 15,
  });
  expect(r.status).toBe(201);
  return r.json() as Promise<RegisterResponse>;
}

function snapshot(sessionId = crypto.randomUUID()): PlaybackSnapshot {
  return {
    sessionId,
    logicalPlaybackSessionId: crypto.randomUUID(),
    mediaKind: "song",
    songId: "one",
    progressSeconds: 42,
    durationSeconds: 180,
    isPlaying: true,
    sampledAt: Date.now() / 1000,
    contextQueue: ["one", "two"],
    contextIndex: 0,
    sourceId: null,
    sourceName: null,
    userQueue: [],
    inUserQueue: false,
    restorePrevious: [],
    shuffle: false,
    repeat: "off",
    volume: 1,
    accumulatedPlaySeconds: 42,
    historyWritten: true,
    nowPlayingSent: true,
    scrobbleSent: false,
  };
}
async function connect(device: RegisterResponse) {
  const r = await api("/v1/auth/ws-ticket", {}, device.accessToken);
  const { ticket } = (await r.json()) as { ticket: string };
  const endpoint = new URL(await mf.ready);
  endpoint.protocol = "ws:";
  endpoint.pathname = "/v1/realtime";
  endpoint.searchParams.set("ticket", ticket);
  const ws = new WebSocket(endpoint);
  sockets.push(ws);
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener(
      "error",
      () => reject(new Error("WebSocket open failed")),
      { once: true },
    );
  });
  const inbox: Envelope[] = [];
  const pending: { type: string; resolve: (env: Envelope) => void }[] = [];
  ws.addEventListener("message", (event) => {
    const env = JSON.parse(event.data as string) as Envelope;
    const at = pending.findIndex((p) => p.type === env.type);
    if (at >= 0) pending.splice(at, 1)[0].resolve(env);
    else inbox.push(env);
  });
  function next(type: string, timeoutMs = 5000): Promise<Envelope> {
    const index = inbox.findIndex((env) => env.type === type);
    if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () =>
          reject(
            new Error(
              `timeout waiting for ${type}; inbox: ${JSON.stringify(inbox)}`,
            ),
          ),
        timeoutMs,
      );
      pending.push({
        type,
        resolve: (env) => {
          clearTimeout(timeout);
          resolve(env);
        },
      });
    });
  }
  function send(payload: Record<string, unknown>) {
    const env = { version: 1, messageId: crypto.randomUUID(), ...payload };
    ws.send(JSON.stringify(env));
    return env.messageId;
  }
  send({
    type: "hello",
    protocolVersion: 1,
    capabilities: 15,
    deviceId: device.deviceId,
    ticket,
  });
  await next("welcome");
  return { ws, next, send, ticket };
}

async function hibernate(account: string) {
  // Let the previous WebSocket handler finish its storage output gate first.
  await new Promise((resolve) => setTimeout(resolve, 30));
  await mf.unsafeEvictDurableObject("coordination", "AccountCoordinator", {
    name: account,
    webSockets: "hibernate",
  });
}

beforeAll(async () => {
  const compiled = await build({
    entryPoints: ["src/index.ts"],
    bundle: true,
    write: false,
    format: "esm",
    platform: "neutral",
    external: ["cloudflare:workers"],
    target: "es2022",
  });
  mf = new Miniflare(
    convertV4MiniflareOptions({
      name: "coordination",
      modules: true,
      script: compiled.outputFiles[0].text,
      compatibilityDate: "2026-09-30",
      bindings: {
        STABLE_KEY: "test-key-with-at-least-32-characters-long",
        ALLOWED_IDENTITY_ORIGINS: "https://music.example",
      },
      durableObjects: {
        ACCOUNTS: { className: "AccountCoordinator", useSQLite: true },
      },
      outboundService: async (request) => {
        proofRequests++;
        expect(new URL(request.url).origin).toBe("https://music.example");
        return new Response(
          JSON.stringify({
            "subsonic-response": { status: rejectProof ? "failed" : "ok" },
          }),
          { headers: { "Content-Type": "application/json" } },
        );
      },
    }),
  );
  await mf.ready;
});
afterAll(async () => {
  for (const socket of sockets) {
    try {
      socket.close();
    } catch {
      /* Closed by an earlier lifecycle test. */
    }
  }
  await mf?.dispose();
});

describe("Workers HTTP protocol", () => {
  it("rejects unconfigured origins, credentials and redirects before account binding", async () => {
    const before = proofRequests;
    expect(
      (
        await api("/v1/auth/challenge", {
          identityUrl: "https://evil.example",
          username: "a",
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await api("/v1/auth/challenge", {
          identityUrl: "https://user@music.example",
          username: "a",
        })
      ).status,
    ).toBe(400);
    expect(proofRequests).toBe(before);
    const c = await api("/v1/auth/challenge", {
      identityUrl,
      username: "rejected",
    });
    const input = {
      ...((await c.json()) as object),
      identityUrl,
      username: "rejected",
      authMode: "password",
      password: "wrong",
      deviceName: "test",
      platform: "web",
    };
    rejectProof = true;
    expect((await api("/v1/auth/register", input)).status).toBe(401);
    rejectProof = false;
    expect((await api("/v1/auth/register", input)).status).toBe(400);
  });
  it("binds canonical usernames, rotates tokens, and isolates accounts", async () => {
    const a = await register(" ＡLICE ");
    const b = await register("alice");
    const c = await register("bob");
    expect(a.accountId).toBe(b.accountId);
    expect(a.accountId).not.toBe(c.accountId);
    const devices = (await (
      await api("/v1/devices", undefined, a.accessToken)
    ).json()) as { id: string }[];
    expect(devices.map((d) => d.id)).toContain(b.deviceId);
    expect(devices.map((d) => d.id)).not.toContain(c.deviceId);
    expect(
      (
        await api(
          `/v1/devices/${c.deviceId}`,
          { name: "hijack" },
          a.accessToken,
          "PATCH",
        )
      ).status,
    ).toBe(403);
    const input = { deviceId: a.deviceId, refreshToken: a.refreshToken };
    const refreshed = await api("/v1/auth/token", input);
    expect(refreshed.status).toBe(200);
    expect((await api("/v1/auth/token", input)).status).toBe(401);
    const recovery = (await (
      await api("/v1/auth/challenge", { identityUrl, username: "alice" })
    ).json()) as object;
    expect(
      (
        await api("/v1/auth/token", {
          ...input,
          ...recovery,
          identityUrl,
          username: "alice",
          authMode: "password",
          password: "enc:6162",
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await api(
          `/v1/devices/${a.deviceId}`,
          undefined,
          b.accessToken,
          "DELETE",
        )
      ).status,
    ).toBe(204);
    expect((await api("/v1/devices", undefined, a.accessToken)).status).toBe(
      401,
    );
  });
  it("keeps history operations idempotent and emits delete/prune tombstones", async () => {
    const d = await register("history");
    const op = {
      kind: "add",
      operationId: crypto.randomUUID(),
      eventId: crypto.randomUUID(),
      songId: "one",
    };
    const first = await (
      await api("/v1/history", { operations: [op] }, d.accessToken)
    ).json();
    expect(
      await (
        await api("/v1/history", { operations: [op] }, d.accessToken)
      ).json(),
    ).toEqual(first);
    const additions = ["two", "three"].map((songId) => ({
      kind: "add",
      operationId: crypto.randomUUID(),
      eventId: crypto.randomUUID(),
      songId,
    }));
    await api(
      "/v1/history",
      {
        operations: [
          ...additions,
          {
            kind: "set_limit",
            operationId: crypto.randomUUID(),
            historyLimit: 1,
          },
        ],
      },
      d.accessToken,
    );
    const pull = (await (
      await api("/v1/history?after_revision=0", undefined, d.accessToken)
    ).json()) as {
      entries: { songId: string }[];
      tombstones: unknown[];
      historyGeneration: number;
    };
    expect(pull.entries.map((e) => e.songId)).toEqual(["three"]);
    expect(pull.tombstones).toHaveLength(2);
    await api(
      "/v1/history",
      { operations: [{ ...op, operationId: crypto.randomUUID() }] },
      d.accessToken,
    );
    expect(
      (
        (await (
          await api("/v1/history", undefined, d.accessToken)
        ).json()) as typeof pull
      ).entries,
    ).toHaveLength(1);
    await api(
      "/v1/history",
      { operations: [{ kind: "clear", operationId: crypto.randomUUID() }] },
      d.accessToken,
    );
    const cleared = (await (
      await api("/v1/history", undefined, d.accessToken)
    ).json()) as typeof pull;
    expect(cleared.historyGeneration).toBe(2);
    expect(cleared.entries).toHaveLength(0);
  });
  it("imports legacy history once and invalidates all credentials on account deletion", async () => {
    const d = await register("legacy");
    const input = { entries: [{ songId: "a" }, { songId: "b" }] };
    expect(
      (await api("/v1/history/legacy-import", input, d.accessToken)).status,
    ).toBe(200);
    expect(
      (await api("/v1/history/legacy-import", input, d.accessToken)).status,
    ).toBe(400);
    expect(
      (await api("/v1/account", undefined, d.accessToken, "DELETE")).status,
    ).toBe(204);
    expect((await api("/v1/devices", undefined, d.accessToken)).status).toBe(
      404,
    );
    expect(
      (
        await api("/v1/auth/token", {
          deviceId: d.deviceId,
          refreshToken: d.refreshToken,
        })
      ).status,
    ).toBe(403);
  });
});

describe("Workers realtime protocol", () => {
  it("consumes tickets once, validates snapshots and returns remote command acknowledgements", async () => {
    const a = await register("remote");
    const b = await register("remote");
    const left = await connect(a);
    const right = await connect(b);
    expect(
      (
        await mf.dispatchFetch(
          `${origin}/v1/realtime?ticket=${encodeURIComponent(left.ticket)}`,
          { headers: { Upgrade: "websocket" } },
        )
      ).status,
    ).toBe(401);
    const s = snapshot();
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
      snapshot: s,
    });
    expect((await right.next("snapshot_projection")).type).toBe(
      "snapshot_projection",
    );
    const id = right.send({
      type: "command",
      targetDeviceId: a.deviceId,
      expectedGeneration: 1,
      command: { type: "pause" },
      sourceDeviceId: "spoofed",
    });
    const forwarded = await left.next("command");
    expect(forwarded.sourceDeviceId).toBe(b.deviceId);
    expect(forwarded.messageId).toBe(id);
    left.send({ type: "command_ack", messageId: id, result: { status: "ok" } });
    expect((await right.next("command_ack")).messageId).toBe(id);
    right.send({
      type: "command",
      targetDeviceId: a.deviceId,
      expectedGeneration: 99,
      command: { type: "pause" },
    });
    expect(await right.next("command_ack")).toMatchObject({
      result: { code: "stale_epoch" },
    });
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 2,
      snapshot: { ...s, volume: 2 },
    });
    expect(await left.next("error")).toMatchObject({ code: "bad_message" });
    right.send({ type: "heartbeat" });
    expect((await right.next("heartbeat_ack")).serverTime).toBeTypeOf("number");
  });
  it("commits online handoff once and rejects spoofed relinquish acknowledgements", async () => {
    const a = await register("handoff");
    const b = await register("handoff");
    const c = await register("handoff");
    const left = await connect(a);
    const right = await connect(b);
    const third = await connect(c);
    const s = snapshot();
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
      snapshot: s,
    });
    await right.next("snapshot_projection");
    right.send({
      type: "handoff_candidate_request",
      sourceDeviceId: a.deviceId,
      expectedGeneration: 1,
      expectedSnapshotRevision: 1,
    });
    const candidate = await right.next("handoff_candidate");
    if (candidate.type !== "handoff_candidate") throw new Error();
    await hibernate(a.accountId);
    const ready = {
      type: "target_ready",
      transactionId: candidate.transactionId,
      sourceDeviceId: a.deviceId,
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
    };
    right.send(ready);
    await left.next("prepare_relinquish");
    third.send({
      type: "relinquish_ack",
      transactionId: candidate.transactionId,
      snapshot: s,
    });
    expect(await third.next("error")).toMatchObject({ code: "forbidden" });
    third.send({ ...ready, transactionId: crypto.randomUUID() });
    expect(await third.next("handoff_failed")).toMatchObject({
      code: "handoff_conflict",
    });
    left.send({
      type: "relinquish_ack",
      transactionId: candidate.transactionId,
      snapshot: s,
    });
    expect(await right.next("handoff_committed")).toMatchObject({
      newGeneration: 2,
      snapshot: { progressSeconds: 42, contextQueue: ["one", "two"] },
    });
    await left.next("session_superseded");
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 2,
      snapshot: s,
    });
    await left.next("session_superseded");
    right.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 2,
      snapshotRevision: 2,
      snapshot: s,
    });
    expect(await third.next("snapshot_projection")).toMatchObject({
      deviceId: a.deviceId,
    }); // initial queued projection
    expect(await third.next("snapshot_projection")).toMatchObject({
      deviceId: b.deviceId,
      generation: 2,
    });
  });
});

describe("Durable Object lifecycle", () => {
  it("replays offline state after eviction and permits only one offline takeover", async () => {
    const a = await register("offline");
    const b = await register("offline");
    const c = await register("offline");
    const left = await connect(a);
    const right = await connect(b);
    const s = snapshot();
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
      snapshot: s,
    });
    await right.next("snapshot_projection");
    left.ws.close();
    expect(await right.next("snapshot_projection")).toMatchObject({
      isOnline: false,
    });
    await hibernate(a.accountId);
    right.send({ type: "request_snapshots" });
    expect(await right.next("snapshot_projection")).toMatchObject({
      isOnline: false,
      snapshot: { progressSeconds: 42 },
    });
    right.send({
      type: "target_ready",
      transactionId: crypto.randomUUID(),
      sourceDeviceId: a.deviceId,
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
    });
    expect(await right.next("handoff_committed")).toMatchObject({
      newGeneration: 2,
    });
    const third = await connect(c);
    third.send({
      type: "target_ready",
      transactionId: crypto.randomUUID(),
      sourceDeviceId: a.deviceId,
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
    });
    expect(await third.next("handoff_failed")).toMatchObject({
      code: "handoff_conflict",
    });
    right.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 2,
      snapshotRevision: 2,
      snapshot: s,
    });
    await third.next("snapshot_projection");
    const reconnected = await connect(a);
    reconnected.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 99,
      snapshot: s,
    });
    expect(await reconnected.next("session_superseded")).toMatchObject({
      transferredToDevice: b.deviceId,
    });
  });
  it("expires an online handoff via an alarm after hibernation", async () => {
    const a = await register("deadline");
    const b = await register("deadline");
    const left = await connect(a);
    const right = await connect(b);
    const s = snapshot();
    left.send({
      type: "snapshot",
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
      snapshot: s,
    });
    await right.next("snapshot_projection");
    const txn = crypto.randomUUID();
    right.send({
      type: "target_ready",
      transactionId: txn,
      sourceDeviceId: a.deviceId,
      sessionId: s.sessionId,
      generation: 1,
      snapshotRevision: 1,
    });
    await left.next("prepare_relinquish");
    await hibernate(a.accountId);
    expect(await right.next("handoff_failed", 20000)).toMatchObject({
      transactionId: txn,
      code: "source_pause_timeout",
    });
  }, 25000);
});
