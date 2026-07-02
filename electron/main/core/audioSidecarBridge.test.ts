import { describe, expect, it } from "vitest";
import {
  AudioSidecarBridge,
  AudioSidecarBridgeDisabledError,
  type AudioSidecarBridgeErrorPayload,
  type AudioSidecarBridgeManager,
  type AudioSidecarBridgeWindow,
  isAudioSidecarBridgeEnabled,
} from "./audioSidecarBridge";
import type { AudioSidecarEventEnvelope } from "./audioSidecarManager";

class FakeBridgeManager implements AudioSidecarBridgeManager {
  running = false;
  starts = 0;
  stops = 0;
  loads: unknown[] = [];
  seeks: unknown[] = [];
  private audioEventListener:
    | ((event: AudioSidecarEventEnvelope) => void)
    | null = null;
  private errorListener: ((error: Error) => void) | null = null;

  start(): void {
    this.running = true;
    this.starts += 1;
  }

  stop(): void {
    this.running = false;
    this.stops += 1;
  }

  async load(options: Parameters<AudioSidecarBridgeManager["load"]>[0]) {
    this.loads.push(options);
  }

  async play() {}

  async pause() {}

  async stopPlayback() {}

  async seek(options: Parameters<AudioSidecarBridgeManager["seek"]>[0]) {
    this.seeks.push(options);
  }

  onAudioEvent(
    listener: (event: AudioSidecarEventEnvelope) => void,
  ): () => void {
    this.audioEventListener = listener;

    return () => {
      this.audioEventListener = null;
    };
  }

  onSidecarError(listener: (error: Error) => void): () => void {
    this.errorListener = listener;

    return () => {
      this.errorListener = null;
    };
  }

  emitAudioEvent(event: AudioSidecarEventEnvelope): void {
    this.audioEventListener?.(event);
  }

  emitError(error: Error): void {
    this.errorListener?.(error);
  }
}

class FakeWindow implements AudioSidecarBridgeWindow {
  destroyed = false;
  sent: Array<{
    channel: string;
    payload: unknown;
  }> = [];
  webContents = {
    send: (channel: string, payload: unknown) => {
      this.sent.push({
        channel,
        payload,
      });
    },
  };

  isDestroyed(): boolean {
    return this.destroyed;
  }
}

describe("AudioSidecarBridge", () => {
  it("is disabled unless the dev opt-in flag is present", () => {
    expect(
      isAudioSidecarBridgeEnabled(
        {
          AONSOKU_PLAYERD_BRIDGE: "1",
        },
        true,
      ),
    ).toBe(true);
    expect(
      isAudioSidecarBridgeEnabled(
        {
          AONSOKU_PLAYERD_BRIDGE: "1",
        },
        false,
      ),
    ).toBe(false);
    expect(isAudioSidecarBridgeEnabled({}, true)).toBe(false);
  });

  it("rejects commands while disabled", async () => {
    const manager = new FakeBridgeManager();
    const bridge = createBridge({
      enabled: false,
      manager,
    });

    expect(bridge.isAvailable()).toBe(false);
    await expect(bridge.play()).rejects.toBeInstanceOf(
      AudioSidecarBridgeDisabledError,
    );
    expect(manager.starts).toBe(0);
  });

  it("lazily starts the manager for MVP commands", async () => {
    const manager = new FakeBridgeManager();
    const bridge = createBridge({
      manager,
    });

    await bridge.load({
      source: {
        kind: "stream",
        url: "https://example.test/song.flac",
      },
    });
    await bridge.seek({
      position: 42,
    });

    expect(manager.starts).toBe(1);
    expect(manager.loads).toEqual([
      {
        source: {
          kind: "stream",
          url: "https://example.test/song.flac",
        },
      },
    ]);
    expect(manager.seeks).toEqual([
      {
        position: 42,
      },
    ]);
  });

  it("fans out manager events and serializes manager errors", () => {
    const manager = new FakeBridgeManager();
    const window = new FakeWindow();
    const bridge = createBridge({
      manager,
      window,
    });

    bridge.start();
    manager.emitAudioEvent({
      event: "playbackStateChanged",
      payload: {
        state: "playing",
      },
    });
    manager.emitError(
      Object.assign(new Error("sidecar failed"), {
        code: "BOOM",
      }),
    );

    expect(window.sent).toEqual([
      {
        channel: "audio-event",
        payload: {
          event: "playbackStateChanged",
          payload: {
            state: "playing",
          },
        },
      },
      {
        channel: "audio-error",
        payload: {
          message: "sidecar failed",
          code: "BOOM",
        } satisfies AudioSidecarBridgeErrorPayload,
      },
    ]);
  });

  it("cleans up listeners and stops the manager on dispose", () => {
    const manager = new FakeBridgeManager();
    const window = new FakeWindow();
    const bridge = createBridge({
      manager,
      window,
    });

    bridge.start();
    bridge.dispose();
    manager.emitAudioEvent({
      event: "ended",
      payload: {},
    });

    expect(manager.stops).toBe(1);
    expect(window.sent).toEqual([]);
  });
});

function createBridge(options: {
  enabled?: boolean;
  manager: FakeBridgeManager;
  window?: FakeWindow;
}): AudioSidecarBridge {
  return new AudioSidecarBridge({
    enabled: options.enabled ?? true,
    getWindow: () => options.window ?? new FakeWindow(),
    managerFactory: () => options.manager,
    eventChannel: "audio-event",
    errorChannel: "audio-error",
  });
}
