import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  const ipcMain = {
    removeHandler: vi.fn(),
    removeAllListeners: vi.fn(),
    on: vi.fn(),
    handle: vi.fn(),
  };
  const BrowserWindow = {
    getAllWindows: vi.fn(() => []),
  };

  return {
    BrowserWindow,
    ipcMain,
  };
});

vi.mock("electron", () => ({
  BrowserWindow: mocks.BrowserWindow,
  ipcMain: mocks.ipcMain,
}));

import { setupDesktopNativeAudioIpc } from "./ipc";

describe("desktop native audio IPC method binding", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("keeps service prototype methods bound to the service instance", async () => {
    setupDesktopNativeAudioIpc();

    const handler = mocks.ipcMain.handle.mock.calls[0]?.[1];

    await expect(
      handler?.(
        {},
        {
          method: "resolveSongs",
          args: [{ ids: [] }],
        },
      ),
    ).resolves.toEqual({ songs: [] });
  });
});
