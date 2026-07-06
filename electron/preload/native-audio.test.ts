import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  const ipcRenderer = {
    invoke: vi.fn(),
    on: vi.fn(),
    removeListener: vi.fn(),
  };
  const ipcMain = {
    removeHandler: vi.fn(),
    handle: vi.fn(),
  };
  const BrowserWindow = {
    getAllWindows: vi.fn(() => []),
  };

  return {
    BrowserWindow,
    ipcMain,
    ipcRenderer,
  };
});

vi.mock("electron", () => ({
  BrowserWindow: mocks.BrowserWindow,
  ipcMain: mocks.ipcMain,
  ipcRenderer: mocks.ipcRenderer,
}));

import {
  DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
  DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
} from "../main/native/audio/ipc";
import { aonsokuNativeAudioBridge } from "./native-audio";

describe("aonsokuNativeAudioBridge", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.ipcRenderer.invoke.mockResolvedValue(undefined);
  });

  it("invokes desktop native audio methods through the typed channel", async () => {
    const loadOptions = {
      requestId: "request-1",
      source: {
        kind: "stream" as const,
        url: "https://server/rest/stream?id=song-1",
      },
    };

    await aonsokuNativeAudioBridge.load(loadOptions);

    expect(mocks.ipcRenderer.invoke).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_INVOKE_CHANNEL,
      {
        method: "load",
        args: [loadOptions],
      },
    );
  });

  it("returns listener handles that remove the wrapped IPC listener", async () => {
    const listener = vi.fn();
    const handle = await aonsokuNativeAudioBridge.addListener(
      "progress",
      listener,
    );
    const wrappedListener = mocks.ipcRenderer.on.mock.calls[0]?.[1];

    wrappedListener?.(
      {},
      {
        eventName: "bufferingChanged",
        event: {
          requestId: "request-1",
          isBuffering: true,
        },
      },
    );
    wrappedListener?.(
      {},
      {
        eventName: "progress",
        event: {
          requestId: "request-1",
          currentTime: 12,
          duration: 120,
          bufferedTime: 20,
        },
      },
    );
    await handle.remove();

    expect(mocks.ipcRenderer.on).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
      wrappedListener,
    );
    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith({
      requestId: "request-1",
      currentTime: 12,
      duration: 120,
      bufferedTime: 20,
    });
    expect(mocks.ipcRenderer.removeListener).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
      wrappedListener,
    );
  });
});
