import { engineName, isMacOs } from "react-device-detect";
import { getRuntime } from "./capabilities";
import { isDesktop } from "./desktop";
import { isDev } from "./env";

export enum MouseButton {
  Left = 0,
  Middle = 1,
  Right = 2,
}

export const isChromeOrFirefox = ["Blink", "Gecko"].includes(engineName);

// Enable for browsers that support Document PiP API
export const hasPiPSupport = isDesktop()
  ? false
  : "documentPictureInPicture" in window;

// Enable mini player for desktop (Electron) or browsers with PiP support
export const hasMiniPlayerSupport = isDesktop()
  ? true
  : "documentPictureInPicture" in window;

function preventContextMenu() {
  document.addEventListener("contextmenu", (e) => {
    if (
      e.target instanceof HTMLInputElement ||
      e.target instanceof HTMLTextAreaElement ||
      e.target instanceof HTMLSelectElement
    ) {
      return;
    }

    e.preventDefault();
  });
}

function isAnyModifierKeyPressed(e: MouseEvent) {
  return e.ctrlKey || e.metaKey || e.shiftKey || e.altKey;
}

function preventNewTabAndScroll() {
  // Prevent new tab on middle click
  document.addEventListener("auxclick", (e) => {
    e.preventDefault();
  });

  // Prevent scroll circle and new tab
  document.addEventListener("mousedown", (e) => {
    if (e.button === MouseButton.Middle || isAnyModifierKeyPressed(e)) {
      e.preventDefault();
    }
  });

  // Prevent new tab if clicking with special key
  document.addEventListener("click", (e) => {
    if (isAnyModifierKeyPressed(e)) {
      e.preventDefault();
    }
  });
}

function preventReload() {
  document.addEventListener("keydown", async (e) => {
    const isF5 = e.key === "F5";
    const isReloadCmd = (e.ctrlKey || e.metaKey) && e.key === "r";

    if (!isF5 && !isReloadCmd) return;

    e.preventDefault();

    if (isDesktop()) return;

    const [{ default: i18n }, { usePlayerStore }] = await Promise.all([
      import("@/i18n"),
      import("@/store/player/store"),
    ]);
    const { isPlaying } = usePlayerStore.getState().playerState;

    if (isPlaying) {
      const message = i18n.t("warnings.reload");

      const shouldReload = window.confirm(message);
      if (!shouldReload) return;
    }

    window.location.reload();
  });
}

function preventAltBehaviour() {
  document.addEventListener("keydown", (e) => {
    if (e.altKey) {
      e.preventDefault();
    }
  });
}

export function enterFullscreen() {
  try {
    const element = document.documentElement;
    if (element.requestFullscreen) {
      element.requestFullscreen().catch((err) => {
        console.warn("Failed to enter fullscreen:", err);
      });
    } else if ("webkitRequestFullscreen" in element) {
      // @ts-expect-error no types for webkit
      element.webkitRequestFullscreen();
    }
  } catch (err) {
    console.warn("enterFullscreen failed:", err);
  }
}

export function exitFullscreen() {
  try {
    const isFullscreen = !!(
      document.fullscreenElement ||
      // @ts-expect-error no types for webkit
      document.webkitFullscreenElement
    );
    if (!isFullscreen) return;

    if (document.exitFullscreen) {
      document.exitFullscreen().catch((err) => {
        console.warn("Failed to exit fullscreen:", err);
      });
    } else if ("webkitExitFullscreen" in document) {
      // @ts-expect-error no types for webkit
      document.webkitExitFullscreen();
    }
  } catch (err) {
    console.warn("exitFullscreen failed:", err);
  }
}

function setPlatformClasses() {
  if (isMacOs) {
    document.body.classList.add("mac");
  } else {
    document.body.classList.add("windows-linux");
  }

  const runtime = getRuntime();
  if (runtime === "capacitor-android") {
    document.body.classList.add("capacitor-android");
  } else if (runtime === "capacitor-ios") {
    document.body.classList.add("capacitor-ios");
  }
}

export function blockFeatures() {
  setPlatformClasses();

  if (isDev) return;

  preventContextMenu();
  preventNewTabAndScroll();
  preventReload();
  preventAltBehaviour();
}
