import clsx from 'clsx'
import { HomeIcon } from 'lucide-react'
import { memo } from 'react'
import { Link } from 'react-router-dom'
import { Linux } from '@/app/components/controls/linux'
import { Windows } from '@/app/components/controls/windows'
import { NavigationButtons } from '@/app/components/header/navigation-buttons'
import { UserDropdown } from '@/app/components/header/user-dropdown'
import { SettingsButton } from '@/app/components/settings/header-button'
import { useAppWindow } from '@/app/hooks/use-app-window'
import { useWindowControlsOverlay } from '@/app/hooks/use-window-controls-overlay'
import { isLinux, isMac, isWindows } from '@/utils/osType'
import { tauriDragRegion } from '@/utils/tauriDragRegion'
import { isTauri } from '@/utils/tauriTools'
import CommandMenu from '../components/command/command-menu'
import { Button } from '../components/ui/button'

export function Header() {
  const { isFullscreen } = useAppWindow()
  const { visible: wcoVisible } = useWindowControlsOverlay()
  const isPWA = !isTauri()
  const MemoCommandMenu = memo(CommandMenu)

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
        <div className={clsx('w-8 h-8')}>
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
      </div>
      <div className="col-span-2 flex justify-center items-center px-4 gap-2">
        <NavigationButtons />
        <MemoCommandMenu />
      </div>
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
