import { memo, ReactNode, useCallback, useEffect, useRef, useState } from "react";
import {
  Drawer,
  DrawerContent,
  DrawerTitle,
  DrawerTrigger,
} from "@/app/components/ui/drawer";
import { useAppWindow } from "@/app/hooks/use-app-window";
import { useBackdropStyle } from "@/app/hooks/use-backdrop-bg";
import { closeFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";
import {
  useFullscreenPlayerSettings,
  usePlayerStore,
} from "@/store/player.store";
import { useTheme } from "@/store/theme.store";
import { enterFullscreen, exitFullscreen } from "@/utils/browser";
import { isDesktop } from "@/utils/desktop";
import { blendColors, hslToHex } from "@/utils/getAverageColor";
import { setDesktopTitleBarColors, updatePwaThemeColor } from "@/utils/theme";
import { FullscreenDragHandler } from "./drag-handler";
import { FullscreenContent } from "./fullscreen-content";
import { useFullscreenMouseDrawerDrag } from "./use-mouse-drawer-drag";

interface FullscreenModeProps {
  children: ReactNode;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}

const MemoFullscreenContent = memo(FullscreenContent);
const DRAWER_CLOSE_ANIMATION_MS = 500;

export default function FullscreenMode({
  children,
  open,
  onOpenChange,
}: FullscreenModeProps) {
  const { enterFullscreenWindow, exitFullscreenWindow } = useAppWindow();
  const { autoFullscreenEnabled } = useFullscreenPlayerSettings();
  const backdropStyle = useBackdropStyle();
  const drawerContentRef = useRef<HTMLDivElement>(null);
  const mouseDrawerDragHandlers = useFullscreenMouseDrawerDrag({
    closeAnimationMs: DRAWER_CLOSE_ANIMATION_MS,
    drawerRef: drawerContentRef,
    open,
  });

  const [devicePanelOpen, setDevicePanelOpen] = useState(false);

  useEffect(() => {
    const handleOpen = () => setDevicePanelOpen(true);
    const handleClose = () => setDevicePanelOpen(false);

    window.addEventListener("device-panel-opened", handleOpen);
    window.addEventListener("device-panel-closed", handleClose);

    return () => {
      window.removeEventListener("device-panel-opened", handleOpen);
      window.removeEventListener("device-panel-closed", handleClose);
    };
  }, []);

  const { theme } = useTheme();
  const { currentSongColor, currentSongColorIntensity } = usePlayerStore(
    (state) => ({
      currentSongColor: state.settings.colors.currentSongColor,
      currentSongColorIntensity:
        state.settings.colors.currentSongColorIntensity,
    }),
  );

  const atTopRef = useRef(false);
  const scrollUnlockTimerRef = useRef<number | null>(null);
  const wasScrollLockedRef = useRef(false);

  const applyThemeColor = useCallback(
    (atTop: boolean) => {
      const bgHsl = getComputedStyle(document.documentElement)
        .getPropertyValue("--background")
        .trim();
      const baseHex = hslToHex(bgHsl);

      if (atTop && open) {
        const color = currentSongColor
          ? blendColors(baseHex, currentSongColor, currentSongColorIntensity)
          : baseHex;
        updatePwaThemeColor(color);
        if (isDesktop()) setDesktopTitleBarColors(true, color);
      } else {
        updatePwaThemeColor();
        if (isDesktop()) setDesktopTitleBarColors(false);
      }
    },
    [open, currentSongColor, currentSongColorIntensity],
  );

  const handleDrag = useCallback(
    (_: React.PointerEvent<HTMLDivElement>, percentageDragged: number) => {
      const atTop = percentageDragged >= 1;
      if (atTopRef.current !== atTop) {
        atTopRef.current = atTop;
        applyThemeColor(atTop);
      }
    },
    [applyThemeColor],
  );

  const handleRelease = useCallback(
    (_: React.PointerEvent<HTMLDivElement>, isOpen: boolean) => {
      // When closing, reset theme color immediately
      if (!isOpen && atTopRef.current !== false) {
        atTopRef.current = false;
        applyThemeColor(false);
      }
      // When isOpen=true, wait for the drawer to finish its snap-back
      // animation/transition before applying theme color. This is handled
      // by the animationend/transitionend listeners in the open effect.
    },
    [applyThemeColor],
  );

  // Only apply blended theme color when the drawer's top edge is at the page top
  useEffect(() => {
    const el = drawerContentRef.current;

    if (open) {
      if (!el) {
        const rafId = requestAnimationFrame(() => {
          const innerEl = drawerContentRef.current;
          if (innerEl) {
            const handleAnimationEnd = () => {
              atTopRef.current = true;
              applyThemeColor(true);
            };
            const handleTransitionEnd = (e: TransitionEvent) => {
              if (e.propertyName === "transform" && e.target === innerEl) {
                atTopRef.current = true;
                applyThemeColor(true);
              }
            };
            innerEl.addEventListener("animationend", handleAnimationEnd, {
              once: true,
            });
            innerEl.addEventListener("transitionend", handleTransitionEnd);
          }
        });
        return () => cancelAnimationFrame(rafId);
      }

      const handleAnimationEnd = () => {
        atTopRef.current = true;
        applyThemeColor(true);
      };
      const handleTransitionEnd = (e: TransitionEvent) => {
        if (e.propertyName === "transform" && e.target === el) {
          atTopRef.current = true;
          applyThemeColor(true);
        }
      };

      el.addEventListener("animationend", handleAnimationEnd, { once: true });
      el.addEventListener("transitionend", handleTransitionEnd);
      return () => {
        el.removeEventListener("animationend", handleAnimationEnd);
        el.removeEventListener("transitionend", handleTransitionEnd);
      };
    } else {
      atTopRef.current = false;
      applyThemeColor(false);
    }
  }, [open, applyThemeColor]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: theme is used to trigger update when base background changes
  useEffect(() => {
    applyThemeColor(atTopRef.current);
  }, [theme, applyThemeColor]);

  const clearScrollUnlockTimer = useCallback(() => {
    if (scrollUnlockTimerRef.current === null) return;

    window.clearTimeout(scrollUnlockTimerRef.current);
    scrollUnlockTimerRef.current = null;
  }, []);

  const removeFullscreenScrollLock = useCallback(() => {
    clearScrollUnlockTimer();
    document.documentElement.classList.remove("fullscreen-scroll-lock");
    document.body.classList.remove("fullscreen-scroll-lock");
    wasScrollLockedRef.current = false;
  }, [clearScrollUnlockTimer]);

  const addFullscreenScrollLock = useCallback(() => {
    clearScrollUnlockTimer();
    document.documentElement.classList.add("fullscreen-scroll-lock");
    document.body.classList.add("fullscreen-scroll-lock");
    wasScrollLockedRef.current = true;
  }, [clearScrollUnlockTimer]);

  useEffect(() => {
    if (open) {
      addFullscreenScrollLock();
      return;
    }

    if (!wasScrollLockedRef.current) return;

    clearScrollUnlockTimer();
    scrollUnlockTimerRef.current = window.setTimeout(
      removeFullscreenScrollLock,
      DRAWER_CLOSE_ANIMATION_MS,
    );
  }, [
    open,
    addFullscreenScrollLock,
    clearScrollUnlockTimer,
    removeFullscreenScrollLock,
  ]);

  useEffect(() => {
    return removeFullscreenScrollLock;
  }, [removeFullscreenScrollLock]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: initial useEffect
  useEffect(() => {
    return () => {
      if (isDesktop()) {
        exitFullscreenWindow().then(() => {
          setDesktopTitleBarColors(false);
        });
      } else {
        exitFullscreen();
      }
    };
  }, []);

  async function handleFullscreen(open: boolean) {
    onOpenChange?.(open);

    if (!open) {
      closeFullscreenPlayerWithHistory({
        historyDelayMs: DRAWER_CLOSE_ANIMATION_MS,
      });
    }

    if (!autoFullscreenEnabled) return;

    if (isDesktop()) {
      open ? await enterFullscreenWindow() : await exitFullscreenWindow();
      return;
    }

    open ? enterFullscreen() : exitFullscreen();
  }

  return (
    <Drawer
      fixed
      shouldScaleBackground={false}
      dismissible={!devicePanelOpen}
      handleOnly={false}
      disablePreventScroll={true}
      modal={false}
      open={open}
      onOpenChange={handleFullscreen}
      onDrag={handleDrag}
      onRelease={handleRelease}
    >
      <DrawerTrigger asChild>{children}</DrawerTrigger>
      <DrawerTitle className="sr-only">Big Player</DrawerTitle>
      <DrawerContent
        ref={drawerContentRef}
        className="fullscreen-drawer-surface mt-0 h-dvh max-h-dvh w-screen rounded-t-none border-none select-none cursor-default"
        showHandle={false}
        aria-describedby={undefined}
        style={backdropStyle}
      >
        <FullscreenDragHandler />
        <div
          className="absolute inset-0 z-10 flex flex-col fullscreen-safe-area"
          {...mouseDrawerDragHandlers}
        >
          <MemoFullscreenContent />
        </div>
      </DrawerContent>
    </Drawer>
  );
}
