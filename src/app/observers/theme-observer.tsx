import { useLayoutEffect } from 'react'
import { useTheme } from '@/store/theme.store'
import { Theme } from '@/types/themeContext'
import { hslToHex } from '@/utils/getAverageColor'
import { emitBgChange } from '@/utils/tauriTools'

export const appThemes: Theme[] = Object.values(Theme)

export function ThemeObserver() {
  const { theme } = useTheme()

  useLayoutEffect(() => {
    async function update() {
      const root = window.document.documentElement

      root.classList.remove(...appThemes)
      root.classList.add(theme)

      const rootStyles = getComputedStyle(root)
      const bgColorHsl = rootStyles.getPropertyValue('--background').trim()
      const bgColorInHex = hslToHex(bgColorHsl)

      await emitBgChange(bgColorInHex)

      // Update PWA theme-color meta tag to match header background
      updatePWAThemeColor(bgColorInHex)
    }

    update()
  }, [theme])

  return null
}

function updatePWAThemeColor(hexColor: string) {
  // Update meta theme-color tag
  let metaThemeColor = document.querySelector('meta[name="theme-color"]')
  
  if (!metaThemeColor) {
    metaThemeColor = document.createElement('meta')
    metaThemeColor.setAttribute('name', 'theme-color')
    document.head.appendChild(metaThemeColor)
  }
  
  metaThemeColor.setAttribute('content', hexColor)
}
