import { useEffect } from "react";
import { useIsXl } from "@/app/hooks/use-is-xl";
import { KeepAliveOutlet } from "@/app/layout/keep-alive-outlet";
import { cn } from "@/lib/utils";
import { useMainDrawerState } from "@/store/player.store";
import { useSidebar } from "@/store/ui.store";

export function MainRoutes() {
  const { isCollapsed } = useSidebar();
  const { mainDrawerState, closeDrawer } = useMainDrawerState();
  const isXl = useIsXl();

  // Auto-close right panel when resizing below xl
  useEffect(() => {
    if (mainDrawerState && !isXl) {
      closeDrawer();
    }
  }, [isXl, mainDrawerState, closeDrawer]);

  // Page scroll-to-top on navigation is intentionally NOT handled here anymore:
  // KeepAliveOutlet restores each cached page's own scroll position and only
  // scrolls fresh pages to the top.
  return (
    <main
      className={cn(
        "relative min-h-screen pt-0 md:pt-header pb-[calc(var(--player-height)+var(--bottom-nav-height))]",
        "pl-safe-left pr-safe-right md:pl-0",
        "md:pl-mini-sidebar",
        isCollapsed ? "xl:pl-mini-sidebar" : "xl:pl-sidebar",
        mainDrawerState ? "lg:pr-right-panel lg:pr-0" : "lg:pr-safe-right",
      )}
    >
      <div className="w-full">
        <KeepAliveOutlet exclude={["error"]} pin={["home"]} />
      </div>
    </main>
  );
}
