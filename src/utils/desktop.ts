import { isElectron, osName } from 'react-device-detect'

export function isDesktop(): boolean {
  return isElectron
}

/**
 * Detect operating system for both Electron and browser/PWA environments
 */
function detectOS(): { isMac: boolean; isWin: boolean; isLinux: boolean } {
  // In Electron, use react-device-detect
  if (isElectron) {
    return {
      isMac: osName === 'Mac OS',
      isWin: osName === 'Windows',
      isLinux: osName === 'Linux',
    }
  }

  // In browser/PWA, use userAgent and platform
  const userAgent = window.navigator.userAgent.toLowerCase()
  const platform = window.navigator.platform.toLowerCase()

  return {
    isMac: /mac|iphone|ipad|ipod/.test(platform) || /macintosh/.test(userAgent),
    isWin: /win/.test(platform),
    isLinux: /linux/.test(platform) && !/android/.test(userAgent),
  }
}

const os = detectOS()
export const isMacOS = os.isMac
export const isWindows = os.isWin
export const isLinux = os.isLinux
