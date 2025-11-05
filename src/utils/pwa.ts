/**
 * Utility functions for PWA detection and management
 */

/**
 * Check if the app is running as an installed PWA
 */
export function isPWA(): boolean {
  // Check if running in standalone mode (iOS/Android)
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches

  // Check if running with window controls overlay (Desktop PWA)
  const isWindowControlsOverlay = window.matchMedia(
    '(display-mode: window-controls-overlay)',
  ).matches

  // Check if navigator standalone is set (iOS)
  const isIOSStandalone =
    'standalone' in window.navigator &&
    (window.navigator as { standalone?: boolean }).standalone === true

  return isStandalone || isWindowControlsOverlay || isIOSStandalone
}

/**
 * Check if Window Controls Overlay is available and visible
 */
export function isWindowControlsOverlayAvailable(): boolean {
  return (
    'windowControlsOverlay' in navigator &&
    navigator.windowControlsOverlay?.visible === true
  )
}

/**
 * Get the display mode of the current window
 */
export function getDisplayMode(): string {
  const modes = [
    'window-controls-overlay',
    'fullscreen',
    'standalone',
    'minimal-ui',
    'browser',
  ]

  for (const mode of modes) {
    if (window.matchMedia(`(display-mode: ${mode})`).matches) {
      return mode
    }
  }

  return 'browser'
}
