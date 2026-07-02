import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import {
  AudioSidecarError,
  AudioSidecarManager,
  type AudioSidecarManagerOptions,
  type AudioSidecarProcess,
  resolveAudioSidecarSpawnCommand,
} from "./audioSidecarManager";

class FakeSidecarProcess extends EventEmitter implements AudioSidecarProcess {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  killed = false;

  kill(): boolean {
    this.killed = true;
    this.emit("exit", 0, null);

    return true;
  }
}

describe("AudioSidecarManager", () => {
  it("sends MVP requests with jsonrpc ids and resolves responses", async () => {
    const fake = new FakeSidecarProcess();
    const writes = collectWrites(fake);
    const manager = createManager(fake);

    manager.start();

    const requests = [
      manager.load({
        source: {
          kind: "stream",
          url: "https://example.test/song.flac",
          songId: "song-1",
        },
        metadata: {
          duration: 120,
        },
        autoplay: true,
      }),
      manager.play(),
      manager.pause(),
      manager.seek({
        position: 42,
      }),
      manager.stopPlayback(),
    ];

    await waitFor(() => writes.length === 5);

    for (const request of parseRequests(writes)) {
      fake.stdout.write(
        `${JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          result: {},
        })}\n`,
      );
    }

    await expect(Promise.all(requests)).resolves.toEqual([
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
    ]);

    expect(parseRequests(writes)).toMatchObject([
      {
        jsonrpc: "2.0",
        method: "load",
        params: {
          source: {
            kind: "stream",
          },
          autoplay: true,
        },
      },
      {
        jsonrpc: "2.0",
        method: "play",
      },
      {
        jsonrpc: "2.0",
        method: "pause",
      },
      {
        jsonrpc: "2.0",
        method: "seek",
        params: {
          position: 42,
        },
      },
      {
        jsonrpc: "2.0",
        method: "stop",
      },
    ]);
  });

  it("fans out sidecar audio events", async () => {
    const fake = new FakeSidecarProcess();
    const sinkEvents: unknown[] = [];
    const listenerEvents: unknown[] = [];
    const manager = createManager(fake, {
      audioEventSink: (event) => {
        sinkEvents.push(event);
      },
    });
    manager.onAudioEvent((event) => {
      listenerEvents.push(event);
    });

    manager.start();
    fake.stdout.write(
      `${JSON.stringify({
        event: "progress",
        payload: {
          requestId: "load-1",
          currentTime: 12,
          duration: 120,
          bufferedTime: 60,
        },
      })}\n`,
    );

    await waitFor(() => listenerEvents.length === 1);

    expect(listenerEvents).toEqual(sinkEvents);
    expect(listenerEvents).toEqual([
      {
        event: "progress",
        payload: {
          requestId: "load-1",
          currentTime: 12,
          duration: 120,
          bufferedTime: 60,
        },
      },
    ]);
  });

  it("emits protocol errors instead of forwarding invalid audio events", async () => {
    const fake = new FakeSidecarProcess();
    const listenerEvents: unknown[] = [];
    const errors: Error[] = [];
    const manager = createManager(fake);
    manager.onAudioEvent((event) => {
      listenerEvents.push(event);
    });
    manager.onSidecarError((error) => {
      errors.push(error);
    });

    manager.start();
    fake.stdout.write(
      `${JSON.stringify({
        event: "progress",
        payload: {
          requestId: "load-1",
          currentTime: "12",
          duration: 120,
        },
      })}\n`,
    );

    await waitFor(() => errors.length === 1);

    expect(listenerEvents).toEqual([]);
    expect(errors[0]).toBeInstanceOf(AudioSidecarError);
    expect(errors[0].message).toBe(
      "invalid aonsoku-playerd event payload: progress",
    );
  });

  it("rejects a correlated request on sidecar failure responses", async () => {
    const fake = new FakeSidecarProcess();
    const writes = collectWrites(fake);
    const manager = createManager(fake);

    manager.start();

    const request = manager.seek({
      position: 10,
    });

    await waitFor(() => writes.length === 1);

    fake.stdout.write(
      `${JSON.stringify({
        jsonrpc: "2.0",
        id: parseRequests(writes)[0].id,
        error: {
          code: "BACKEND_ERROR",
          message: "not loaded",
        },
      })}\n`,
    );

    await expect(request).rejects.toMatchObject({
      name: "AudioSidecarError",
      code: "BACKEND_ERROR",
      message: "not loaded",
    });
  });

  it("rejects requests when playerd does not respond before timeout", async () => {
    const fake = new FakeSidecarProcess();
    const manager = createManager(fake, {
      requestTimeoutMs: 5,
    });

    manager.start();

    await expect(manager.play()).rejects.toMatchObject({
      name: "AudioSidecarError",
      code: "REQUEST_TIMEOUT",
      message: "aonsoku-playerd request timed out: play",
    });
  });

  it("emits protocol errors for malformed stdout lines", async () => {
    const fake = new FakeSidecarProcess();
    const errors: Error[] = [];
    const manager = createManager(fake);
    manager.onSidecarError((error) => {
      errors.push(error);
    });

    manager.start();
    fake.stdout.write("not-json\n");

    await waitFor(() => errors.length === 1);

    expect(errors[0]).toBeInstanceOf(AudioSidecarError);
    expect(errors[0].message).toContain("invalid aonsoku-playerd JSON line");
  });

  it("rejects pending requests when playerd exits unexpectedly", async () => {
    const fake = new FakeSidecarProcess();
    const manager = createManager(fake);

    manager.start();

    const request = manager.play();
    fake.emit("exit", 1, null);

    await expect(request).rejects.toThrow(
      "aonsoku-playerd exited with exit code 1",
    );
    expect(manager.running).toBe(false);
  });
});

describe("resolveAudioSidecarSpawnCommand", () => {
  it("uses an explicit sidecar path when provided", () => {
    const command = resolveAudioSidecarSpawnCommand({
      env: {
        AONSOKU_PLAYERD_PATH: "/tmp/aonsoku-playerd",
      },
    });

    expect(command).toMatchObject({
      command: "/tmp/aonsoku-playerd",
      args: [],
      cwd: "/tmp",
    });
  });

  it("falls back to cargo run for a dev checkout without a built binary", () => {
    const command = resolveAudioSidecarSpawnCommand({
      cwd: "/tmp/aonsoku-playerd-test",
      env: {},
      platform: "darwin",
    });

    expect(command).toMatchObject({
      command: "cargo",
      args: [
        "run",
        "--quiet",
        "--manifest-path",
        "/tmp/aonsoku-playerd-test/desktop/aonsoku-playerd/Cargo.toml",
      ],
      cwd: "/tmp/aonsoku-playerd-test/desktop/aonsoku-playerd",
    });
  });
});

const sidecarSmoke = process.env.AONSOKU_PLAYERD_SMOKE === "1" ? it : it.skip;

describe("AudioSidecarManager sidecar smoke", () => {
  sidecarSmoke("drives the Rust mock sidecar MVP commands", async () => {
    const events: unknown[] = [];
    const errors: Error[] = [];
    const spawnCommand = resolveAudioSidecarSpawnCommand({
      env: {
        ...process.env,
        AONSOKU_PLAYERD_BACKEND: "mock",
      },
    });
    const manager = new AudioSidecarManager({
      spawnCommand,
      requestIdPrefix: "smoke",
    });

    manager.onAudioEvent((event) => {
      events.push(event);
    });
    manager.onSidecarError((error) => {
      errors.push(error);
    });

    manager.start();

    try {
      await manager.load({
        source: {
          kind: "stream",
          url: "https://example.test/song.flac",
          songId: "song-1",
        },
        metadata: {
          duration: 120,
        },
        autoplay: false,
      });
      await manager.play();
      await manager.seek({
        position: 42,
      });
      await manager.pause();
      await manager.stopPlayback();

      await waitFor(() =>
        events.some((event) =>
          matchesEvent(event, "ended", {
            reason: "stopped",
          }),
        ),
      );
    } finally {
      manager.stop();
    }

    expect(errors).toEqual([]);
    expect(events).toContainEqual({
      event: "progress",
      payload: expect.objectContaining({
        currentTime: 42,
        duration: 120,
      }),
    });
    expect(events).toContainEqual({
      event: "playbackStateChanged",
      payload: expect.objectContaining({
        state: "stopped",
      }),
    });
  });
});

function createManager(
  fake: FakeSidecarProcess,
  options: {
    audioEventSink?: AudioSidecarManagerOptions["audioEventSink"];
    requestTimeoutMs?: AudioSidecarManagerOptions["requestTimeoutMs"];
  } = {},
): AudioSidecarManager {
  return new AudioSidecarManager({
    spawnCommand: {
      command: "fake-playerd",
      args: [],
    },
    spawn: () => fake,
    requestIdPrefix: "test",
    requestTimeoutMs: options.requestTimeoutMs,
    audioEventSink: options.audioEventSink,
  });
}

function collectWrites(fake: FakeSidecarProcess): string[] {
  const writes: string[] = [];

  fake.stdin.on("data", (chunk) => {
    writes.push(chunk.toString());
  });

  return writes;
}

function parseRequests(writes: string[]): Array<Record<string, unknown>> {
  return writes
    .join("")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 500,
): Promise<void> {
  const startedAt = Date.now();

  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error("timed out waiting for test condition");
    }

    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function matchesEvent(
  value: unknown,
  event: string,
  payload: Record<string, unknown>,
): boolean {
  if (typeof value !== "object" || value === null) return false;

  const envelope = value as {
    event?: unknown;
    payload?: unknown;
  };
  if (envelope.event !== event) return false;
  if (typeof envelope.payload !== "object" || envelope.payload === null) {
    return false;
  }

  const actualPayload = envelope.payload as Record<string, unknown>;

  return Object.entries(payload).every(
    ([key, expected]) => actualPayload[key] === expected,
  );
}
