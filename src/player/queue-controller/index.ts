import { getNativeAudioPluginAvailability } from "@/native/audio";
import { getPlaybackCapabilities } from "@/utils/capabilities";
import { logger } from "@/utils/logger";
import { NativeQueueController } from "./native-controller";
import type { QueueController } from "./types";
import { WebQueueController } from "./web-controller";

let instance: QueueController | null = null;

export function getQueueController(): QueueController {
  if (!instance) {
    instance = createQueueController();
  }
  return instance;
}

function createQueueController(): QueueController {
  if (
    getPlaybackCapabilities().supportsNativePlayback &&
    getNativeAudioPluginAvailability().available
  ) {
    try {
      return new NativeQueueController();
    } catch (err) {
      logger.error(
        "[QueueController] Native controller unavailable, falling back to web",
        err,
      );
    }
  }
  return new WebQueueController();
}

export function getNativeQueueController(): NativeQueueController | null {
  const controller = getQueueController();
  return controller instanceof NativeQueueController ? controller : null;
}

export function resetQueueController(): void {
  instance?.dispose();
  instance = null;
}

export type {
  QueueController,
  QueueControllerEvent,
  QueueControllerListener,
  QueueControllerState,
  QueueStateChangeEvent,
  QueueStateChangeReason,
} from "./types";
