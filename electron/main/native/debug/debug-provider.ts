import process from "node:process";
import type { StoredCredentials } from "@aonsoku/capacitor-native/bridge";
import { desktopNativeAudioService } from "../audio/ipc";
import { desktopNativeBridgeService } from "../bridge/ipc";
import { nativeLogger } from "./native-logger";
import type {
  NativeDebugConnection,
  NativeDebugControl,
  NativeDebugSnapshot,
  NativeDebugSystemInfo,
} from "./types";

function toConnection(
  creds: StoredCredentials | null,
): NativeDebugConnection | null {
  if (!creds) return null;
  return {
    serverUrl: creds.serverUrl,
    username: creds.username,
    authType: creds.authType,
    protocolVersion: creds.protocolVersion,
    serverType: creds.serverType,
    hasFallbackUrl: Boolean(creds.fallbackUrl),
  };
}

function systemInfo(): NativeDebugSystemInfo {
  const rss = process.memoryUsage().rss;
  return {
    rssMB: Math.round((rss / (1024 * 1024)) * 10) / 10,
    electronVersion: process.versions.electron ?? "",
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.version,
  };
}

/**
 * Aggregate a single debug snapshot from the desktop native audio service,
 * credential store, process info, and the shared ring-buffered logger. The
 * debug window renderer polls this on a 2s interval (matching the mobile
 * DebugViewController / DebugActivity refresh cadence).
 */
export async function getNativeDebugSnapshot(): Promise<NativeDebugSnapshot> {
  const [audio, volumeResult, extras] = await Promise.all([
    desktopNativeAudioService.getFullState(),
    desktopNativeAudioService.getSystemVolume(),
    Promise.resolve(desktopNativeAudioService.getDebugExtras()),
  ]);

  return {
    audio,
    volume: volumeResult.volume,
    isBuffering: extras.isBuffering,
    diagnostics: extras.diagnostics,
    connection: toConnection(desktopNativeBridgeService.getCredentials()),
    system: systemInfo(),
    logs: nativeLogger.getEntries(),
  };
}

/**
 * Apply a playback control from the debug window. Mirrors the mobile
 * DebugDataProvider play-pause / skip-next / skip-previous controls. State is
 * read from the live full state so play/pause toggles correctly.
 */
export async function applyNativeDebugControl(
  control: NativeDebugControl,
): Promise<void> {
  switch (control) {
    case "playPause": {
      const state = await desktopNativeAudioService.getFullState();
      if (state.isPlaying) {
        await desktopNativeAudioService.pause();
      } else {
        await desktopNativeAudioService.play();
      }
      break;
    }
    case "next":
      await desktopNativeAudioService.skipToNext();
      break;
    case "previous":
      await desktopNativeAudioService.skipToPrevious();
      break;
  }
}

/** Clear the shared native debug log ring buffer. */
export function clearNativeDebugLogs(): void {
  nativeLogger.clear();
}
