import {
  createNativeMpvPlayer,
  LibMpvBindingLoadError,
  libMpvPlatformKey,
  loadLibMpvBinding,
} from "./libmpv-binding";
import { LibMpvAudioEngine } from "./libmpv-engine";
import type {
  DesktopAudioEngine,
  DesktopAudioEngineDiagnostics,
} from "./types";
import { UnavailableDesktopAudioEngine } from "./unavailable-engine";

export function createDesktopAudioEngine(): DesktopAudioEngine {
  try {
    const binding = loadLibMpvBinding();
    const runtimeInfo = binding.runtimeInfo?.();
    if (runtimeInfo?.systemMediaSessionApiVersion !== "2") {
      throw new Error(
        "The Aonsoku libmpv addon does not provide system media session API version 2.",
      );
    }
    const capabilityProbe = createNativeMpvPlayer(binding);
    try {
      const result = capabilityProbe.initialize({
        options: {
          "audio-display": "no",
          "force-window": "no",
          idle: "yes",
          terminal: "no",
          vid: "no",
        },
        registerSystemMediaSession: false,
      });
      if (result instanceof Promise) {
        throw new Error(
          "The desktop native audio capability probe must initialize synchronously.",
        );
      }
    } finally {
      capabilityProbe.destroy();
    }
    const diagnostics = {
      backend: "libmpv",
      status: "available",
      platformKey: libMpvPlatformKey(),
      runtimeInfo,
    } satisfies DesktopAudioEngineDiagnostics;

    return new LibMpvAudioEngine({
      playerFactory: () => createNativeMpvPlayer(binding),
      diagnostics,
    });
  } catch (error) {
    return new UnavailableDesktopAudioEngine(toUnavailableDiagnostics(error));
  }
}

function toUnavailableDiagnostics(
  error: unknown,
): DesktopAudioEngineDiagnostics {
  if (error instanceof LibMpvBindingLoadError) {
    return {
      backend: "libmpv",
      status: "unavailable",
      code: error.code,
      message: error.message,
      platformKey: error.platformKey,
      searchedPaths: error.searchedPaths,
    };
  }

  if (error instanceof Error) {
    const code = errorWithCode(error);

    return {
      backend: "libmpv",
      status: "unavailable",
      code: code ?? "libmpv-unavailable",
      message: error.message,
      platformKey: libMpvPlatformKey(),
    };
  }

  return {
    backend: "libmpv",
    status: "unavailable",
    code: "libmpv-unavailable",
    message: "libmpv native addon could not be loaded.",
    platformKey: libMpvPlatformKey(),
  };
}

function errorWithCode(error: Error): string | undefined {
  const maybeCodedError = error as Error & { code?: unknown };

  return typeof maybeCodedError.code === "string"
    ? maybeCodedError.code
    : undefined;
}
