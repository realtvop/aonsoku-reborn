import { createNativeMpvPlayer, loadLibMpvBinding } from "./libmpv-binding";
import { LibMpvAudioEngine } from "./libmpv-engine";
import type { DesktopAudioEngine } from "./types";
import { UnavailableDesktopAudioEngine } from "./unavailable-engine";

export function createDesktopAudioEngine(): DesktopAudioEngine {
  try {
    const binding = loadLibMpvBinding();

    return new LibMpvAudioEngine({
      playerFactory: () => createNativeMpvPlayer(binding),
    });
  } catch (error) {
    return new UnavailableDesktopAudioEngine(describeEngineLoadFailure(error));
  }
}

function describeEngineLoadFailure(error: unknown): string {
  if (error instanceof Error) return error.message;

  return "libmpv native addon could not be loaded.";
}
