import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeAudioServiceEventListener } from "./types";

const mocks = vi.hoisted(() => {
  let serviceListener: NativeAudioServiceEventListener | null = null;
  const unsubscribe = vi.fn();
  const service = {
    load: vi.fn(async () => {}),
    play: vi.fn(async () => {}),
    pause: vi.fn(async () => {}),
    stop: vi.fn(async () => {}),
    seek: vi.fn(async () => {}),
    clear: vi.fn(async () => {}),
    updateMetadata: vi.fn(async () => {}),
    destroy: vi.fn(async () => {}),
    onEvent: vi.fn((listener: NativeAudioServiceEventListener) => {
      serviceListener = listener;
      return unsubscribe;
    }),
  };
  const ipcMain = {
    removeHandler: vi.fn(),
    handle: vi.fn(),
  };
  const webContents = {
    send: vi.fn(),
  };
  const window = {
    isDestroyed: vi.fn(() => false),
    webContents,
  };
  const BrowserWindow = {
    getAllWindows: vi.fn(() => [window]),
  };

  return {
    BrowserWindow,
    ipcMain,
    service,
    unsubscribe,
    webContents,
    window,
    getServiceListener: () => serviceListener,
    setServiceListener: (listener: NativeAudioServiceEventListener | null) => {
      serviceListener = listener;
    },
  };
});

vi.mock("electron", () => ({
  BrowserWindow: mocks.BrowserWindow,
  ipcMain: mocks.ipcMain,
}));

vi.mock("./service", () => ({
  NativeAudioService: class {
    constructor() {
      return mocks.service;
    }
  },
}));

import {
  DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
  DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
  destroyDesktopNativeAudioService,
  setupDesktopNativeAudioIpc,
} from "./ipc";

function windowArg(): Parameters<typeof setupDesktopNativeAudioIpc>[0] {
  return mocks.window as unknown as Parameters<
    typeof setupDesktopNativeAudioIpc
  >[0];
}

describe("desktop native audio IPC", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.setServiceListener(null);
    mocks.window.isDestroyed.mockReturnValue(false);
    mocks.BrowserWindow.getAllWindows.mockReturnValue([mocks.window]);
  });

  it("dispatches invoke payloads to the native audio service", async () => {
    setupDesktopNativeAudioIpc(windowArg());

    const handler = mocks.ipcMain.handle.mock.calls[0]?.[1];
    await expect(
      handler?.(
        {},
        {
          method: "load",
          args: [
            {
              requestId: "request-1",
              source: {
                kind: "stream",
                url: "https://server/rest/stream?id=song-1",
              },
            },
          ],
        },
      ),
    ).resolves.toBeUndefined();

    expect(mocks.ipcMain.removeHandler).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
    );
    expect(mocks.service.load).toHaveBeenCalledWith({
      requestId: "request-1",
      source: {
        kind: "stream",
        url: "https://server/rest/stream?id=song-1",
      },
    });
  });

  it("rejects unknown invoke methods", async () => {
    setupDesktopNativeAudioIpc(windowArg());

    const handler = mocks.ipcMain.handle.mock.calls[0]?.[1];

    await expect(
      handler?.(
        {},
        {
          method: "missingMethod",
          args: [],
        },
      ),
    ).rejects.toThrow("Unknown desktop native audio method missingMethod");
  });

  it("forwards service events to the registered window", () => {
    setupDesktopNativeAudioIpc(windowArg());

    mocks.getServiceListener()?.({
      eventName: "playbackStateChanged",
      event: {
        requestId: "request-1",
        state: "playing",
      },
    });

    expect(mocks.webContents.send).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
      {
        eventName: "playbackStateChanged",
        event: {
          requestId: "request-1",
          state: "playing",
        },
      },
    );
  });

  it("replaces the previous service event subscription on setup", () => {
    setupDesktopNativeAudioIpc(windowArg());
    const unsubscribeCallsAfterFirstSetup = mocks.unsubscribe.mock.calls.length;

    setupDesktopNativeAudioIpc(windowArg());

    expect(mocks.unsubscribe).toHaveBeenCalledTimes(
      unsubscribeCallsAfterFirstSetup + 1,
    );
    expect(mocks.service.onEvent).toHaveBeenCalledTimes(2);
  });

  it("destroys the service and removes IPC bindings", async () => {
    setupDesktopNativeAudioIpc(windowArg());
    const unsubscribeCallsAfterSetup = mocks.unsubscribe.mock.calls.length;

    await destroyDesktopNativeAudioService();

    expect(mocks.ipcMain.removeHandler).toHaveBeenLastCalledWith(
      DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
    );
    expect(mocks.unsubscribe).toHaveBeenCalledTimes(
      unsubscribeCallsAfterSetup + 1,
    );
    expect(mocks.service.destroy).toHaveBeenCalledTimes(1);
  });
});
