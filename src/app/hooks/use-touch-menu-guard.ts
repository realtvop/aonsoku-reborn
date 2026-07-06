import { useCallback, useEffect, useRef, useState } from "react";
import { useHaptic } from "@/app/hooks/use-haptic";

const TOUCH_SYNTHETIC_CLICK_GUARD_MS = 700;

interface UseTouchMenuGuardOptions {
  hapticOnLongPress?: boolean;
  longPressDuration?: number;
  moveThreshold?: number;
}

export function useTouchMenuGuard(options?: UseTouchMenuGuardOptions) {
  const {
    hapticOnLongPress = true,
    longPressDuration = 500,
    moveThreshold = 10,
  } = options ?? {};

  const [open, setOpen] = useState(false);
  const { trigger: hapticTrigger } = useHaptic();
  const startPos = useRef<{ x: number; y: number } | null>(null);
  const longPressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const openedByLongPress = useRef(false);
  const hasMoved = useRef(false);
  const allowOpen = useRef(false);
  const suppressNextClick = useRef(false);

  const clearTimer = useCallback(() => {
    if (longPressTimer.current) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  }, []);

  const suppressSyntheticClick = useCallback(() => {
    suppressNextClick.current = true;
    window.setTimeout(() => {
      suppressNextClick.current = false;
    }, TOUCH_SYNTHETIC_CLICK_GUARD_MS);
  }, []);

  useEffect(() => {
    return () => {
      if (longPressTimer.current) clearTimeout(longPressTimer.current);
    };
  }, []);

  const guardedSetOpen = useCallback((state: boolean) => {
    if (state) {
      if (!allowOpen.current) return;
      allowOpen.current = false;
    }
    setOpen(state);
  }, []);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (e.pointerType !== "touch") return;
      startPos.current = { x: e.clientX, y: e.clientY };
      openedByLongPress.current = false;
      hasMoved.current = false;
      e.preventDefault();
      e.stopPropagation();

      clearTimer();
      longPressTimer.current = setTimeout(() => {
        if (startPos.current && !hasMoved.current) {
          openedByLongPress.current = true;
          suppressSyntheticClick();
          allowOpen.current = true;
          setOpen(true);
          if (hapticOnLongPress && hapticTrigger) hapticTrigger("medium");
        }
      }, longPressDuration);
    },
    [
      clearTimer,
      hapticOnLongPress,
      hapticTrigger,
      longPressDuration,
      suppressSyntheticClick,
    ],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (e.pointerType !== "touch" || !startPos.current) return;
      const dx = Math.abs(e.clientX - startPos.current.x);
      const dy = Math.abs(e.clientY - startPos.current.y);
      if (dx > moveThreshold || dy > moveThreshold) {
        hasMoved.current = true;
        clearTimer();
      }
    },
    [clearTimer, moveThreshold],
  );

  const onPointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (e.pointerType !== "touch") return;
      clearTimer();
      if (!startPos.current) return;

      const dx = Math.abs(e.clientX - startPos.current.x);
      const dy = Math.abs(e.clientY - startPos.current.y);
      startPos.current = null;

      if (hasMoved.current || dx > moveThreshold || dy > moveThreshold) return;
      if (openedByLongPress.current) return;

      e.stopPropagation();
      suppressSyntheticClick();
      allowOpen.current = true;
      setOpen(true);
    },
    [clearTimer, moveThreshold, suppressSyntheticClick],
  );

  const onPointerCancel = useCallback(() => {
    clearTimer();
    startPos.current = null;
  }, [clearTimer]);

  const onClick = useCallback((e: React.MouseEvent) => {
    if (suppressNextClick.current) {
      suppressNextClick.current = false;
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    e.stopPropagation();
    allowOpen.current = true;
    setOpen(true);
  }, []);

  const onContextMenu = useCallback((e: React.SyntheticEvent) => {
    e.preventDefault();
  }, []);

  return {
    open,
    setOpen: guardedSetOpen,
    triggerProps: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel,
      onClick,
      onContextMenu,
      className: "touch-pan-y select-none",
    },
  };
}
