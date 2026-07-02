import { is } from "@electron-toolkit/utils";
import { app, type BrowserWindow, ipcMain } from "electron";
import { IpcChannels } from "../../preload/types";
import {
  AudioSidecarBridge,
  isAudioSidecarBridgeEnabled,
} from "./audioSidecarBridge";
import {
  AudioSidecarManager,
  resolveAudioSidecarRequestTimeoutMs,
} from "./audioSidecarManager";

let activeBridge: AudioSidecarBridge | null = null;
let cleanupActiveBridge: (() => void) | null = null;

export function setupAudioSidecarIpc(window: BrowserWindow): void {
  cleanupActiveBridge?.();

  const bridge = new AudioSidecarBridge({
    enabled: isAudioSidecarBridgeEnabled(process.env, is.dev),
    getWindow: () => window,
    managerFactory: () =>
      new AudioSidecarManager({
        requestTimeoutMs: resolveAudioSidecarRequestTimeoutMs(process.env),
      }),
    eventChannel: IpcChannels.AudioSidecarEvent,
    errorChannel: IpcChannels.AudioSidecarError,
  });
  activeBridge = bridge;

  const cleanup = () => {
    bridge.dispose();
    if (activeBridge === bridge) {
      removeAudioSidecarIpcHandlers();
      activeBridge = null;
      cleanupActiveBridge = null;
    }
  };

  cleanupActiveBridge = cleanup;
  window.once("closed", cleanup);
  app.once("before-quit", cleanup);

  registerAudioSidecarIpcHandlers(bridge);
}

export function getActiveAudioSidecarBridge(): AudioSidecarBridge | null {
  return activeBridge;
}

function registerAudioSidecarIpcHandlers(bridge: AudioSidecarBridge): void {
  removeAudioSidecarIpcHandlers();

  ipcMain.handle(IpcChannels.AudioSidecarIsAvailable, () => {
    return bridge.isAvailable();
  });
  ipcMain.handle(IpcChannels.AudioSidecarStart, () => {
    bridge.start();
  });
  ipcMain.handle(IpcChannels.AudioSidecarStop, () => {
    bridge.stop();
  });
  ipcMain.handle(IpcChannels.AudioSidecarLoad, (_, options) => {
    return bridge.load(options);
  });
  ipcMain.handle(IpcChannels.AudioSidecarPlay, () => {
    return bridge.play();
  });
  ipcMain.handle(IpcChannels.AudioSidecarPause, () => {
    return bridge.pause();
  });
  ipcMain.handle(IpcChannels.AudioSidecarStopPlayback, () => {
    return bridge.stopPlayback();
  });
  ipcMain.handle(IpcChannels.AudioSidecarSeek, (_, options) => {
    return bridge.seek(options);
  });
}

function removeAudioSidecarIpcHandlers(): void {
  for (const channel of AUDIO_SIDECAR_HANDLER_CHANNELS) {
    ipcMain.removeHandler(channel);
  }
}

const AUDIO_SIDECAR_HANDLER_CHANNELS = [
  IpcChannels.AudioSidecarIsAvailable,
  IpcChannels.AudioSidecarStart,
  IpcChannels.AudioSidecarStop,
  IpcChannels.AudioSidecarLoad,
  IpcChannels.AudioSidecarPlay,
  IpcChannels.AudioSidecarPause,
  IpcChannels.AudioSidecarStopPlayback,
  IpcChannels.AudioSidecarSeek,
];
