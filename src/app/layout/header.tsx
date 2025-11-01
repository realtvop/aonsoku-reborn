import clsx from 'clsx'
import { Linux } from '@/app/components/controls/linux'
import { Windows } from '@/app/components/controls/windows'
import { NavigationButtons } from '@/app/components/header/navigation-buttons'
import { UserDropdown } from '@/app/components/header/user-dropdown'
import { HeaderSongInfo } from '@/app/components/header-song'
import { SettingsButton } from '@/app/components/settings/header-button'
import { useAppWindow } from '@/app/hooks/use-app-window'
import { useWindowControlsOverlay } from '@/app/hooks/use-window-controls-overlay'
import { isLinux, isMac, isWindows } from '@/utils/osType'
import { tauriDragRegion } from '@/utils/tauriDragRegion'
import { isTauri } from '@/utils/tauriTools'

export function Header() {
  const { isFullscreen } = useAppWindow()
  const { visible: wcoVisible } = useWindowControlsOverlay()
  const isPWA = !isTauri()

  return (
    <header
      className={clsx(
        'w-full grid grid-cols-header h-header px-4 fixed top-0 right-0 left-0 z-20 bg-background border-b',
        (isWindows || isLinux) && 'pr-0',
      )}
      style={
        isPWA && wcoVisible
          ? ({
              // Use titlebar area environment variables for PWA
              appRegion: 'drag',
              WebkitAppRegion: 'drag',
            } as React.CSSProperties)
          : undefined
      }
    >
      <div
        {...(isTauri() ? tauriDragRegion : {})}
        className="flex items-center"
        style={
          isPWA && wcoVisible
            ? {
                paddingLeft: 'var(--titlebar-area-x)',
              }
            : undefined
        }
      >
        {isMac && !isFullscreen && !wcoVisible && <div className="w-[70px]" />}
        <NavigationButtons />
      </div>
      <HeaderSongInfo />
      <div
        {...(isTauri() ? tauriDragRegion : {})}
        className="flex justify-end items-center gap-2"
        style={
          isPWA && wcoVisible
            ? {
                paddingRight: `calc(100vw - var(--titlebar-area-x) - var(--titlebar-area-width) + 1rem)`,
              }
            : undefined
        }
      >
        <SettingsButton />
        <UserDropdown />
        {isTauri() && isWindows && <Windows />}
        {isTauri() && isLinux && <Linux />}
      </div>
    </header>
  )
}
