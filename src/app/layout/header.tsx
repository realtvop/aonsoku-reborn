import { NavigationButtons } from "@/app/components/header/navigation-buttons";
import { UserDropdown } from "@/app/components/header/user-dropdown";
import { SettingsButton } from "@/app/components/settings/header-button";
import { useAppWindow } from "@/app/hooks/use-app-window";
import { useWindowControlsOverlay } from "@/app/hooks/use-window-controls-overlay";
import { useThemeColor } from "@/app/hooks/use-theme-color";
import { isDesktop, isLinux, isMacOS, isWindows } from "@/utils/desktop";
import { isWindowControlsOverlayAvailable } from "@/utils/pwa";
import CommandMenu from "../components/command/command-menu";
import { memo, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "../components/ui/button";
import { HomeIcon } from "lucide-react";

export function Header() {
  const { isFullscreen } = useAppWindow();
  const MemoCommandMenu = memo(CommandMenu);

  // Update browser theme color dynamically
  useThemeColor();

  // Check if we're in PWA mode with window controls overlay
  const hasWindowControls = isWindowControlsOverlayAvailable();
  const windowControlsOverlay = useWindowControlsOverlay();
  const isElectronApp = isDesktop();

  // Calculate actual window controls width from overlay geometry
  const [controlsWidth, setControlsWidth] = useState({ left: 0, right: 0 });

  useEffect(() => {
    if (
      windowControlsOverlay.visible &&
      windowControlsOverlay.titlebarAreaRect
    ) {
      const rect = windowControlsOverlay.titlebarAreaRect;
      // Calculate controls width based on titlebar area position
      const leftWidth = rect.x;
      const rightWidth = window.innerWidth - (rect.x + rect.width);

      setControlsWidth({ left: leftWidth, right: rightWidth });
    } else {
      setControlsWidth({ left: 0, right: 0 });
    }
  }, [windowControlsOverlay.visible, windowControlsOverlay.titlebarAreaRect]);

  // Determine if we need spacing for window controls
  // Only add spacing in these cases:
  // 1. Electron app (not fullscreen)
  // 2. PWA with window-controls-overlay active (hasWindowControls = true)
  // Regular web page: no spacing

  const shouldAddSpacing =
    !isFullscreen && (isElectronApp || hasWindowControls);

  // macOS: traffic lights on left (Electron or PWA overlay)
  const needsLeftSpacing = isMacOS && shouldAddSpacing;

  // Windows/Linux/macOS: may have controls on right in PWA overlay mode
  // In Electron: only Windows/Linux have controls on right
  // In PWA overlay: use actual measured width (any platform)
  const needsRightSpacing =
    shouldAddSpacing &&
    // Electron: only Windows/Linux
    ((isElectronApp && (isWindows || isLinux)) ||
      // PWA overlay: use measured width (may exist on any platform)
      (hasWindowControls && controlsWidth.right > 0));

  // Calculate actual spacing width
  // In window-controls-overlay mode, use actual measured width
  // In Electron mode, use default values
  const leftSpacingWidth = needsLeftSpacing
    ? hasWindowControls && controlsWidth.left > 0
      ? controlsWidth.left
      : 80 // Electron macOS default
    : 0;

  const rightSpacingWidth = needsRightSpacing
    ? hasWindowControls && controlsWidth.right > 0
      ? controlsWidth.right // PWA overlay: use measured width
      : isWindows
        ? 122 // Electron Windows default
        : 94 // Electron Linux default
    : 0;

  return (
    <header className="w-full grid grid-cols-header h-header px-4 fixed top-0 right-0 left-0 z-20 bg-background border-b electron-drag">
      <div className="flex items-center">
        {/* Spacing for macOS window controls (traffic lights) on left side */}
        {leftSpacingWidth > 10 && (
          <div
            style={{ width: `${leftSpacingWidth - 10}px` }}
            className="flex-shrink-0"
          />
        )}
        <div className="w-8 h-8">
          <Link to="/">
            <Button
              variant="ghost"
              size="sm"
              className="h-8 w-8 p-0 rounded-md"
            >
              <HomeIcon className="w-4 h-4" strokeWidth={1.5} />
            </Button>
          </Link>
        </div>
        <div className="md:hidden flex justify-center items-center px-4 gap-2 w-full">
          <NavigationButtons />
          <MemoCommandMenu />
        </div>
      </div>
      <div className="col-span-2 flex items-center justify-center">
        <div className="hidden md:flex justify-center items-center px-4 gap-2 w-full">
          <NavigationButtons />
          <MemoCommandMenu />
        </div>
      </div>
      <div className="flex justify-end items-center gap-2">
        <SettingsButton />
        <UserDropdown />
        {/* Spacing for Windows/Linux window controls on right side */}
        {rightSpacingWidth > 10 && (
          <div
            style={{ width: `${rightSpacingWidth - 10}px` }}
            className="flex-shrink-0"
          />
        )}
      </div>
    </header>
  );
}
