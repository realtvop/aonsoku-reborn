import {
  getNativeAudioPluginAvailability,
  type NativeAudioPluginAvailability,
} from "@/native/audio";
import { getPlaybackCapabilities } from "@/utils/capabilities";
import {
  createElectronAudioSidecarPlaybackBackend,
  getElectronAudioSidecarAvailability,
  type ElectronAudioSidecarAvailability,
  type ElectronAudioSidecarPlaybackBackend,
} from "./sidecar-backend";
import {
  createNativeAudioPlaybackBackend,
  type NativeAudioPlaybackBackend,
} from "./native-backend";
import type { PlaybackBackend } from "./types";
import {
  createWebAudioPlaybackBackend,
  type WebAudioPlaybackBackendOptions,
} from "./web-backend";

export type PlaybackBackendKind = "web" | "native" | "sidecar";

export interface PlaybackBackendSelection {
  backend: PlaybackBackend;
  kind: PlaybackBackendKind;
  fallbackReason?: string;
}

export interface PlaybackBackendSelectionOptions {
  createSidecarBackend?: (
    availability: Extract<
      ElectronAudioSidecarAvailability,
      { available: true }
    >,
  ) => PlaybackBackend;
  createNativeBackend?: (
    availability: Extract<NativeAudioPluginAvailability, { available: true }>,
  ) => PlaybackBackend;
  createWebBackend?: (audio: HTMLAudioElement) => PlaybackBackend;
  getSidecarAvailability?: () => ElectronAudioSidecarAvailability;
  getNativeAudioAvailability?: () => NativeAudioPluginAvailability;
  getCapabilities?: () => ReturnType<typeof getPlaybackCapabilities>;
  webOptions?: WebAudioPlaybackBackendOptions;
}

export function createPlaybackBackend(
  audio: HTMLAudioElement,
  options: PlaybackBackendSelectionOptions = {},
): PlaybackBackendSelection {
  const caps = (options.getCapabilities ?? getPlaybackCapabilities)();
  const createWebBackend =
    options.createWebBackend ??
    ((webAudio: HTMLAudioElement) =>
      createWebAudioPlaybackBackend(webAudio, options.webOptions));

  const sidecarAvailability = (
    options.getSidecarAvailability ?? getElectronAudioSidecarAvailability
  )();

  if (sidecarAvailability.available) {
    try {
      return {
        backend:
          options.createSidecarBackend?.(sidecarAvailability) ??
          createElectronAudioSidecarPlaybackBackend(sidecarAvailability.api),
        kind: "sidecar",
      };
    } catch (error) {
      return {
        backend: createWebBackend(audio),
        kind: "web",
        fallbackReason:
          error instanceof Error ? error.message : "sidecar-backend-error",
      };
    }
  }

  if (!caps.supportsNativePlayback) {
    return {
      backend: createWebBackend(audio),
      kind: "web",
    };
  }

  const availability = (
    options.getNativeAudioAvailability ?? getNativeAudioPluginAvailability
  )();

  if (!availability.available) {
    return {
      backend: createWebBackend(audio),
      kind: "web",
      fallbackReason: availability.reason,
    };
  }

  try {
    return {
      backend:
        options.createNativeBackend?.(availability) ??
        createNativeAudioPlaybackBackend(availability.plugin),
      kind: "native",
    };
  } catch (error) {
    return {
      backend: createWebBackend(audio),
      kind: "web",
      fallbackReason:
        error instanceof Error ? error.message : "native-backend-error",
    };
  }
}

export function shouldUseNativePlaybackBackend(
  options: Pick<
    PlaybackBackendSelectionOptions,
    "getSidecarAvailability" | "getNativeAudioAvailability" | "getCapabilities"
  > = {},
) {
  const sidecarAvailability = (
    options.getSidecarAvailability ?? getElectronAudioSidecarAvailability
  )();
  if (sidecarAvailability.available) return true;

  const caps = (options.getCapabilities ?? getPlaybackCapabilities)();
  if (!caps.supportsNativePlayback) {
    return false;
  }

  return (
    options.getNativeAudioAvailability ?? getNativeAudioPluginAvailability
  )().available;
}

export type { ElectronAudioSidecarPlaybackBackend, NativeAudioPlaybackBackend };
