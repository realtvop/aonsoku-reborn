import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  data: {} as Record<string, unknown>,
}));

vi.mock("../../core/store", () => ({
  AonsokuStore: class {
    get(key: string) {
      return mocks.data[key];
    }
    set(key: string, value: unknown) {
      mocks.data[key] = value;
    }
    delete(key: string) {
      delete mocks.data[key];
    }
  },
}));

const { DesktopNativeCoordinationService } = await import("./service");

describe("DesktopNativeCoordinationService", () => {
  beforeEach(() => {
    mocks.data = {};
  });

  it("persists coordination config and device tokens in the main process", () => {
    const service = new DesktopNativeCoordinationService(() => {});
    const config = {
      serverUrl: "https://coord.example",
      identityUrl: "https://music.example",
    };
    const tokens = {
      deviceId: "device-1",
      accountId: "account-1",
      accessToken: "access",
      refreshToken: "refresh",
      historyLimit: 100,
    };

    service.storeConfig(config);
    service.storeTokens(tokens);

    expect(service.loadConfig()).toEqual(config);
    expect(service.loadTokens()).toEqual(tokens);
    service.clearTokens();
    expect(service.loadTokens()).toBeNull();
  });

  it("routes acknowledgements separately and forwards other envelopes", () => {
    const events: Array<{ event: string; payload: unknown }> = [];
    const service = new DesktopNativeCoordinationService((event, payload) =>
      events.push({ event, payload }),
    );
    const internal = service as unknown as {
      handleMessage(raw: string): void;
    };

    internal.handleMessage(
      JSON.stringify({
        type: "command_ack",
        messageId: "m1",
        result: { status: "ok" },
        seq: 4,
      }),
    );
    internal.handleMessage(
      JSON.stringify({
        type: "snapshot_projection",
        messageId: "m2",
        deviceId: "peer",
        generation: 2,
        snapshotRevision: 3,
      }),
    );

    expect(events[0]).toEqual({
      event: "coordinationAck",
      payload: {
        messageId: "m1",
        resultJson: JSON.stringify({ status: "ok" }),
      },
    });
    expect(events[1]).toMatchObject({
      event: "coordinationEvent",
    });
    expect(mocks.data.lastSeq).toBe(4);
  });
});
