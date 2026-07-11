/**
 * Shared types for the Electron native player debug window.
 *
 * These are the wire shapes between the main-process debug IPC handler and the
 * `electron/renderer/native-debug` renderer entry. They intentionally live in
 * `electron/` (not `src/`) so the web/Capacitor builds never see them.
 */

import type { NativeFullState } from "@aonsoku/audio-contract";
import type { DesktopAudioEngineDiagnostics } from "../audio/types";

/** Password is always stripped before credentials reach the renderer. */
export interface NativeDebugConnection {
  serverUrl: string;
  username: string;
  authType: "token" | "password";
  protocolVersion: string;
  serverType: string;
  hasFallbackUrl: boolean;
}

export interface NativeDebugSystemInfo {
  rssMB: number;
  electronVersion: string;
  platform: string;
  arch: string;
  nodeVersion: string;
}

export interface NativeDebugSnapshot {
  audio: NativeFullState | null;
  /** Player/libmpv volume in 0..1 (NOT the OS output volume). */
  volume: number;
  isBuffering: boolean;
  diagnostics: DesktopAudioEngineDiagnostics | undefined;
  connection: NativeDebugConnection | null;
  system: NativeDebugSystemInfo;
  logs: NativeDebugLogEntry[];
}

export type NativeDebugControl = "playPause" | "next" | "previous";

export type NativeDebugLogLevel = "debug" | "info" | "warn" | "error";

export interface NativeDebugLogEntry {
  /** Unix epoch milliseconds. */
  timestamp: number;
  level: NativeDebugLogLevel;
  message: string;
  source: string;
}
