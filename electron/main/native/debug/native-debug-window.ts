import { is } from "@electron-toolkit/utils";
import { BrowserWindow, ipcMain } from "electron";
import { join } from "path";
import { IpcChannels } from "../../../preload/types";

let nativeDebugWindow: BrowserWindow | null = null;

export function getNativeDebugWindow(): BrowserWindow | null {
  return nativeDebugWindow;
}

/**
 * Open the native player debug window. macOS-only entry point (wired from the
 * application menu); the window itself is platform-neutral so other runtimes
 * can be enabled later. Loaded from a dedicated Electron-only renderer entry
 * (`electron/renderer/native-debug/index.html`) that is not part of the shared
 * `src/` SPA, so web/Capacitor builds never bundle it.
 */
export function createNativeDebugWindow(): BrowserWindow | null {
  if (nativeDebugWindow && !nativeDebugWindow.isDestroyed()) {
    nativeDebugWindow.focus();
    return nativeDebugWindow;
  }

  nativeDebugWindow = new BrowserWindow({
    width: 720,
    height: 640,
    minWidth: 520,
    minHeight: 480,
    resizable: true,
    show: false,
    title: "Native Player Debug",
    backgroundColor: "#060e23",
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, "../preload/index.mjs"),
      sandbox: false,
    },
  });

  nativeDebugWindow.on("closed", () => {
    nativeDebugWindow = null;
  });

  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    const base = process.env.ELECTRON_RENDERER_URL.replace(/\/+$/, "");
    nativeDebugWindow.loadURL(
      `${base}/electron/renderer/native-debug/index.html`,
    );
  } else {
    nativeDebugWindow.loadFile(
      join(__dirname, "../renderer/electron/renderer/native-debug/index.html"),
    );
  }

  nativeDebugWindow.once("ready-to-show", () => {
    nativeDebugWindow?.show();
  });

  return nativeDebugWindow;
}

export function closeNativeDebugWindow(): void {
  if (nativeDebugWindow && !nativeDebugWindow.isDestroyed()) {
    nativeDebugWindow.close();
  }
  nativeDebugWindow = null;
}

/** Alias used by the macOS application menu entry. */
export const openNativeDebugWindow = createNativeDebugWindow;

export function destroyNativeDebugWindow(): void {
  if (nativeDebugWindow && !nativeDebugWindow.isDestroyed()) {
    nativeDebugWindow.destroy();
  }
  nativeDebugWindow = null;
}

export function setupNativeDebugWindowIpc(): void {
  ipcMain.on(IpcChannels.OpenNativeDebug, () => {
    createNativeDebugWindow();
  });
}
