import { useEffect, useState } from 'react'

// Extend Navigator interface to include windowControlsOverlay
declare global {
  interface WindowControlsOverlay extends EventTarget {
    visible: boolean
    getTitlebarAreaRect(): DOMRect
  }

  interface Navigator {
    windowControlsOverlay?: WindowControlsOverlay
  }
}

interface WindowControlsOverlayState {
  visible: boolean
  titlebarAreaRect: DOMRect | null
}

/**
 * Hook to detect and manage Window Controls Overlay API for PWA
 * This allows the web app to use the title bar area when installed as a PWA
 */
export function useWindowControlsOverlay() {
  const [overlayState, setOverlayState] = useState<WindowControlsOverlayState>({
    visible: false,
    titlebarAreaRect: null,
  })

  useEffect(() => {
    const overlay = navigator.windowControlsOverlay

    if (!overlay) {
      return
    }

    const updateOverlayState = () => {
      setOverlayState({
        visible: overlay.visible,
        titlebarAreaRect: overlay.visible
          ? overlay.getTitlebarAreaRect()
          : null,
      })
    }

    // Initial state
    updateOverlayState()

    // Listen for geometry changes
    const handleGeometryChange = () => {
      updateOverlayState()
    }

    overlay.addEventListener('geometrychange', handleGeometryChange)

    return () => {
      overlay.removeEventListener('geometrychange', handleGeometryChange)
    }
  }, [])

  return overlayState
}
