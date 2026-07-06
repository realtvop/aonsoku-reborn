import * as React from "react";

export const MenuCloseContext = React.createContext<(() => void) | null>(null);

export const MENU_DISMISS_OVERLAY_ATTR = "data-menu-dismiss-overlay";
const OPEN_GESTURE_CLICK_GUARD_MS = 700;

export const MenuTouchOverlay = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement>
>((props, ref) => {
  const { style, onPointerDown, onPointerUp, onClick, ...overlayProps } = props;
  const close = React.useContext(MenuCloseContext);
  const mountedAtRef = React.useRef(Date.now());
  const sawOverlayPointerDownRef = React.useRef(false);

  if (!close) return null;

  return (
    <div
      ref={ref}
      data-menu-dismiss-overlay=""
      aria-hidden
      {...overlayProps}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 49,
        pointerEvents: "auto",
        touchAction: "manipulation",
        ...style,
      }}
      onPointerDown={(e) => {
        sawOverlayPointerDownRef.current = true;
        e.preventDefault();
        e.stopPropagation();
        onPointerDown?.(e);
      }}
      onPointerUp={(e) => {
        e.stopPropagation();
        onPointerUp?.(e);
      }}
      onClick={(e) => {
        e.preventDefault();
        e.stopPropagation();
        if (
          !sawOverlayPointerDownRef.current &&
          Date.now() - mountedAtRef.current < OPEN_GESTURE_CLICK_GUARD_MS
        ) {
          onClick?.(e);
          return;
        }
        React.startTransition(() => close());
        onClick?.(e);
      }}
    />
  );
});
MenuTouchOverlay.displayName = "MenuTouchOverlay";
