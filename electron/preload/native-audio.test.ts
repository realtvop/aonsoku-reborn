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
import { __resetNativeAudioDispatcherForTest } from "./native-audio";

function dispatch(payload: { eventName: string; event: unknown }): void {
  const dispatcher = mocks.ipcRenderer.on.mock.calls[0]?.[1] as
    | ((event: unknown, payload: unknown) => void)
    | undefined;
  dispatcher?.({}, payload);
}

describe("aonsokuNativeAudioBridge", () => {
  beforeEach(() => {
    __resetNativeAudioDispatcherForTest();
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

  it("installs a single IPC dispatcher regardless of subscriber count", async () => {
    await aonsokuNativeAudioBridge.addListener("progress", vi.fn());
    await aonsokuNativeAudioBridge.addListener("progress", vi.fn());
    await aonsokuNativeAudioBridge.addListener("bufferingChanged", vi.fn());
    await aonsokuNativeAudioBridge.addListener("remoteCommand", vi.fn());

    // One ipcRenderer.on for the shared dispatcher, not one per subscriber.
    expect(mocks.ipcRenderer.on).toHaveBeenCalledTimes(1);
    expect(mocks.ipcRenderer.on).toHaveBeenCalledWith(
      DESKTOP_NATIVE_AUDIO_EVENT_CHANNEL,
      expect.any(Function),
    );
  });

  it("dispatches events only to listeners registered for that event name", async () => {
    const progressListener = vi.fn();
    const bufferingListener = vi.fn();

    await aonsokuNativeAudioBridge.addListener("progress", progressListener);
    await aonsokuNativeAudioBridge.addListener(
      "bufferingChanged",
      bufferingListener,
    );

    dispatch({
      eventName: "bufferingChanged",
      event: { requestId: "request-1", isBuffering: true },
    });
    dispatch({
      eventName: "progress",
      event: {
        requestId: "request-1",
        currentTime: 12,
        duration: 120,
        bufferedTime: 20,
      },
    });

    expect(bufferingListener).toHaveBeenCalledTimes(1);
    expect(bufferingListener).toHaveBeenCalledWith({
      requestId: "request-1",
      isBuffering: true,
    });
    expect(progressListener).toHaveBeenCalledTimes(1);
    expect(progressListener).toHaveBeenCalledWith({
      requestId: "request-1",
      currentTime: 12,
      duration: 120,
      bufferedTime: 20,
    });
  });

  it("stops delivering events after the listener handle is removed", async () => {
    const listener = vi.fn();
    const handle = await aonsokuNativeAudioBridge.addListener(
      "progress",
      listener,
    );

    dispatch({ eventName: "progress", event: { currentTime: 1 } });
    expect(listener).toHaveBeenCalledTimes(1);

    await handle.remove();

    dispatch({ eventName: "progress", event: { currentTime: 2 } });
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("isolates a throwing listener from the other listeners", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const throwing = vi.fn(() => {
      throw new Error("boom");
    });
    const healthy = vi.fn();

    await aonsokuNativeAudioBridge.addListener("progress", throwing);
    await aonsokuNativeAudioBridge.addListener("progress", healthy);

    dispatch({ eventName: "progress", event: { currentTime: 5 } });

    expect(throwing).toHaveBeenCalledTimes(1);
    expect(healthy).toHaveBeenCalledTimes(1);
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });
});
