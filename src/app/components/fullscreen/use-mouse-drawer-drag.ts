import {
  type PointerEvent,
  type RefObject,
  useCallback,
  useEffect,
  useRef,
} from "react";
import { closeFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";

const MOUSE_DRAG_START_THRESHOLD_PX = 2;
const MOUSE_DRAG_CLOSE_DISTANCE_PX = 48;
const MOUSE_DRAG_CLOSE_THRESHOLD = 0.08;
const MOUSE_DRAG_VELOCITY_THRESHOLD = 0.12;
const DRAWER_MOUSE_RELEASE_EASING = "cubic-bezier(0.32, 0.72, 0, 1)";

type MouseDrawerDragState = {
  drawer: HTMLElement;
  pointerId: number;
  startX: number;
  startY: number;
  lastY: number;
  startedAt: number;
  hasDragged: boolean;
};

type UseFullscreenMouseDrawerDragOptions = {
  closeAnimationMs: number;
  drawerRef: RefObject<HTMLElement>;
  open?: boolean;
  disabled?: boolean;
};

function isMouseDrawerDragBlocked(target: EventTarget | null) {
  if (!(target instanceof Element)) return true;

  return Boolean(
    target.closest(
      [
        "button",
        "a",
        "input",
        "textarea",
        "select",
        "[role='button']",
        "[role='link']",
        "[role='slider']",
        "[data-vaul-no-drag]",
      ].join(","),
    ),
  );
}

function getVisibleDrawerHeight(drawer: HTMLElement) {
  return Math.min(drawer.getBoundingClientRect().height, window.innerHeight);
}

function getMouseDragCloseDistance(drawer: HTMLElement) {
  return Math.max(
    MOUSE_DRAG_CLOSE_DISTANCE_PX,
    getVisibleDrawerHeight(drawer) * MOUSE_DRAG_CLOSE_THRESHOLD,
  );
}

function getDrawerMouseReleaseTransition(durationMs: number) {
  return `transform ${durationMs}ms ${DRAWER_MOUSE_RELEASE_EASING}`;
}

function setPointerCaptureSafely(element: HTMLElement, pointerId: number) {
  try {
    element.setPointerCapture(pointerId);
  } catch {
    // Synthetic pointer events in tests may not register an active pointer.
  }
}

export function useFullscreenMouseDrawerDrag({
  closeAnimationMs,
  drawerRef,
  open,
  disabled = false,
}: UseFullscreenMouseDrawerDragOptions) {
  const dragStateRef = useRef<MouseDrawerDragState | null>(null);
  const resetTimerRef = useRef<number | null>(null);

  const clearResetTimer = useCallback(() => {
    if (resetTimerRef.current === null) return;

    window.clearTimeout(resetTimerRef.current);
    resetTimerRef.current = null;
  }, []);

  const clearDrawerStylesLater = useCallback(
    (drawer: HTMLElement, delay: number) => {
      clearResetTimer();
      resetTimerRef.current = window.setTimeout(() => {
        drawer.style.removeProperty("transition");
        drawer.style.removeProperty("transform");
        resetTimerRef.current = null;
      }, delay);
    },
    [clearResetTimer],
  );

  const resetDrawer = useCallback(
    (drawer: HTMLElement) => {
      drawer.style.transition =
        getDrawerMouseReleaseTransition(closeAnimationMs);
      drawer.style.transform = "translate3d(0, 0, 0)";
      clearDrawerStylesLater(drawer, closeAnimationMs);
    },
    [clearDrawerStylesLater, closeAnimationMs],
  );

  const closeDrawer = useCallback(
    (drawer: HTMLElement) => {
      clearResetTimer();
      drawer.style.transform = "translate3d(0, 100%, 0)";
      drawer.style.transition =
        getDrawerMouseReleaseTransition(closeAnimationMs);

      resetTimerRef.current = window.setTimeout(() => {
        resetTimerRef.current = null;
        closeFullscreenPlayerWithHistory();
      }, closeAnimationMs);
    },
    [clearResetTimer, closeAnimationMs],
  );

  const releasePointerCapture = useCallback(
    (event: PointerEvent<HTMLDivElement>, pointerId: number) => {
      try {
        if (!event.currentTarget.hasPointerCapture(pointerId)) return;

        event.currentTarget.releasePointerCapture(pointerId);
      } catch {
        // The pointer may already be gone after cancellation or synthetic tests.
      }
    },
    [],
  );

  const handlePointerDown = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      if (disabled) return;
      if (event.pointerType !== "mouse" || event.button !== 0) return;
      if (isMouseDrawerDragBlocked(event.target)) return;

      const drawer = drawerRef.current;
      if (!drawer) return;

      clearResetTimer();
      dragStateRef.current = {
        drawer,
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        lastY: event.clientY,
        startedAt: event.timeStamp,
        hasDragged: false,
      };

      setPointerCaptureSafely(event.currentTarget, event.pointerId);
      event.preventDefault();
      event.stopPropagation();
    },
    [clearResetTimer, drawerRef, disabled],
  );

  const handlePointerMove = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      const dragState = dragStateRef.current;
      if (!dragState || event.pointerId !== dragState.pointerId) return;

      const deltaX = event.clientX - dragState.startX;
      const deltaY = event.clientY - dragState.startY;

      if (!dragState.hasDragged) {
        const absX = Math.abs(deltaX);
        const absY = Math.abs(deltaY);

        if (
          absX < MOUSE_DRAG_START_THRESHOLD_PX &&
          absY < MOUSE_DRAG_START_THRESHOLD_PX
        ) {
          event.stopPropagation();
          return;
        }

        if (deltaY <= 0 || absX > absY) {
          releasePointerCapture(event, dragState.pointerId);
          dragStateRef.current = null;
          return;
        }

        dragState.hasDragged = true;
      }

      const translateY = Math.max(0, deltaY);
      dragState.lastY = event.clientY;
      dragState.drawer.style.transition = "none";
      dragState.drawer.style.transform = `translate3d(0, ${translateY}px, 0)`;

      event.preventDefault();
      event.stopPropagation();
    },
    [releasePointerCapture],
  );

  const finishPointerDrag = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      const dragState = dragStateRef.current;
      if (!dragState || event.pointerId !== dragState.pointerId) return;

      dragStateRef.current = null;
      releasePointerCapture(event, dragState.pointerId);

      if (!dragState.hasDragged) return;

      const distance = Math.max(0, event.clientY - dragState.startY);
      const elapsed = Math.max(1, event.timeStamp - dragState.startedAt);
      const velocity = distance / elapsed;
      const shouldClose =
        velocity > MOUSE_DRAG_VELOCITY_THRESHOLD ||
        distance >= getMouseDragCloseDistance(dragState.drawer);

      if (shouldClose) {
        closeDrawer(dragState.drawer);
      } else {
        resetDrawer(dragState.drawer);
      }

      event.preventDefault();
      event.stopPropagation();
    },
    [closeDrawer, releasePointerCapture, resetDrawer],
  );

  const handlePointerOut = useCallback(
    (event: PointerEvent<HTMLDivElement>) => {
      if (!dragStateRef.current) return;

      event.stopPropagation();
    },
    [],
  );

  useEffect(() => {
    return clearResetTimer;
  }, [clearResetTimer]);

  useEffect(() => {
    if (!open) return;

    const frame = window.requestAnimationFrame(() => {
      const drawer = drawerRef.current;

      drawer?.style.removeProperty("transition");
      drawer?.style.removeProperty("transform");
    });

    return () => window.cancelAnimationFrame(frame);
  }, [drawerRef, open]);

  return {
    onPointerDown: handlePointerDown,
    onPointerMove: handlePointerMove,
    onPointerUp: finishPointerDrag,
    onPointerCancel: finishPointerDrag,
    onPointerOut: handlePointerOut,
  };
}
