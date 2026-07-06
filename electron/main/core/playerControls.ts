import type { NativeAudioRemoteCommand } from "@aonsoku/audio-contract";
import type { PlayerStateListenerActions } from "../../preload/types";
import { desktopNativeAudioService } from "../native/audio/ipc";
import type {
  NativeAudioControlState,
  NativeAudioService,
} from "../native/audio/service";
import { sendPlayerEvents } from "./playerEvents";
import { playerState } from "./playerState";

type ChromeUpdate = () => void;

let unsubscribeFromNativeChromeUpdates: (() => void) | null = null;

const nativeChromeEventNames = new Set([
  "playbackStateChanged",
  "queueStateChanged",
  "queueContentsChanged",
  "ended",
]);

export function getDesktopPlaybackControlState() {
  return resolveDesktopPlaybackControlState(
    desktopNativeAudioService.getControlState(),
    playerState.value(),
  );
}

export function resolveDesktopPlaybackControlState(
  nativeState: NativeAudioControlState,
  rendererState: ReturnType<typeof playerState.value>,
) {
  if (nativeState.hasCurrent || nativeState.hasNativeQueue) {
    return {
      isPlaying: nativeState.isPlaying,
      hasPrevious: nativeState.hasPrevious,
      hasNext: nativeState.hasNext,
      hasSonglist: nativeState.hasCurrent || nativeState.hasNativeQueue,
    };
  }

  return rendererState;
}

export async function dispatchDesktopPlaybackAction(
  action: PlayerStateListenerActions,
): Promise<void> {
  await routeDesktopPlaybackAction(action, {
    service: desktopNativeAudioService,
    sendRendererAction: sendPlayerEvents,
  });
}

export async function routeDesktopPlaybackAction(
  action: PlayerStateListenerActions,
  dependencies: {
    service: Pick<
      NativeAudioService,
      "handleRemoteCommand" | "emitRemoteCommand"
    >;
    sendRendererAction: (action: PlayerStateListenerActions) => void;
  },
): Promise<void> {
  const command = playerActionToRemoteCommand(action);
  if (!command) {
    dependencies.sendRendererAction(action);
    return;
  }

  const handled = await dependencies.service
    .handleRemoteCommand(command)
    .catch(() => false);

  if (handled) return;

  dependencies.service.emitRemoteCommand(command);
  dependencies.sendRendererAction(action);
}

export function setupDesktopPlaybackControlChrome(
  updateChrome: ChromeUpdate,
): void {
  unsubscribeFromNativeChromeUpdates?.();
  unsubscribeFromNativeChromeUpdates = desktopNativeAudioService.onEvent(
    ({ eventName }) => {
      if (!nativeChromeEventNames.has(eventName)) return;
      updateChrome();
    },
  );
}

function playerActionToRemoteCommand(
  action: PlayerStateListenerActions,
): NativeAudioRemoteCommand | null {
  switch (action) {
    case "togglePlayPause":
      return "togglePlayPause";
    case "skipBackwards":
      return "previous";
    case "skipForward":
      return "next";
    case "toggleShuffle":
      return "shuffle";
    case "toggleRepeat":
      return null;
  }
}
