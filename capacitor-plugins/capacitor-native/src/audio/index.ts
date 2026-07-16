import { registerPlugin } from "@capacitor/core";
import type { AonsokuNativeAudioPlugin } from "./definitions";
import { NATIVE_AUDIO_PLUGIN_NAME } from "./definitions";
import { AonsokuNativeAudioWeb } from "./web";

export const AonsokuNativeAudio = registerPlugin<AonsokuNativeAudioPlugin>(
  NATIVE_AUDIO_PLUGIN_NAME,
  {
    web: () => new AonsokuNativeAudioWeb(),
  },
);

export * from "./definitions";
export {
  AonsokuNativeAudioWeb,
  createNativeAudioUnavailableError,
} from "./web";
