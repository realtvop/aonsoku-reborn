import { useCallback, useLayoutEffect } from "react";
import { useThemeStore } from "@/store/theme.store";
import { isDarkTheme, Theme, ThemeMode } from "@/types/themeContext";
import { hasElectronBridge } from "@/utils/desktop";
import { setDesktopTitleBarColors, updatePwaThemeColor } from "@/utils/theme";
import { Capacitor } from "@capacitor/core";
import {
  isNativeBridgeAvailable,
  AonsokuNativeBridge,
} from "@/native/bridge/facade";

export const appThemes: Theme[] = Object.values(Theme);

const colorMap: Record<string, string[]> = {
  colorPrimary: ["--primary", "--ring"],
  colorOnPrimary: ["--primary-foreground"],
  colorSecondary: ["--secondary"],
  colorOnSecondary: ["--secondary-foreground"],
  colorSurfaceContainer: ["--background", "--background-foreground"], // M3 Modern: Container as main background (softer)
  colorOnSurface: ["--foreground", "--card-foreground", "--popover-foreground"],
  colorSurfaceContainerHigh: ["--card", "--popover"], // Subtle elevation
  colorSurfaceContainerHighest: ["--accent", "--muted"], // Focus/Accent areas
  colorOnSurfaceVariant: ["--muted-foreground", "--accent-foreground"],
  colorOutlineVariant: ["--border", "--input"], // Standard soft border
};

function hexToHslComponents(hex: string): string {
  let h = hex.replace(/^#/, "");
  if (h.length === 3) {
    h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
  }
  const r = parseInt(h.substring(0, 2), 16) / 255;
  const g = parseInt(h.substring(2, 4), 16) / 255;
  const b = parseInt(h.substring(4, 6), 16) / 255;

  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let hue = 0;
  let sat = 0;
  const light = (max + min) / 2;

  if (max !== min) {
    const d = max - min;
    sat = light > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r:
        hue = (g - b) / d + (g < b ? 6 : 0);
        break;
      case g:
        hue = (b - r) / d + 2;
        break;
      case b:
        hue = (r - g) / d + 4;
        break;
    }
    hue /= 6;
  }

  const hueDeg = Math.round(hue * 360);
  const satPct = Math.round(sat * 100);
  const lightPct = Math.round(light * 100);

  return `${hueDeg} ${satPct}% ${lightPct}%`;
}

function clearMaterialYouStyles(root: HTMLElement) {
  const allCssKeys = Object.values(colorMap).flat();
  for (const cssKey of allCssKeys) {
    root.style.removeProperty(cssKey);
  }
}

function getSystemPrefersDark(): boolean {
  if (typeof window === "undefined" || !window.matchMedia) return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function resolveTheme(
  themeMode: ThemeMode,
  lightTheme: Theme,
  darkTheme: Theme,
): Theme {
  switch (themeMode) {
    case ThemeMode.Light:
      return lightTheme;
    case ThemeMode.Dark:
      return darkTheme;
    case ThemeMode.System:
      return getSystemPrefersDark() ? darkTheme : lightTheme;
  }
}

function applyTheme(theme: Theme) {
  const root = window.document.documentElement;
  root.classList.remove(...appThemes);
  root.classList.add(theme);
  setDesktopTitleBarColors();
  updatePwaThemeColor();

  if (hasElectronBridge()) {
    window.api.setNativeTheme(isDarkTheme(theme));
  }
}

export function ThemeObserver() {
  const themeMode = useThemeStore((s) => s.themeMode);
  const lightTheme = useThemeStore((s) => s.lightTheme);
  const darkTheme = useThemeStore((s) => s.darkTheme);
  const currentTheme = useThemeStore((s) => s.theme);
  const materialYouEnabled = useThemeStore((s) => s.materialYouEnabled);
  const usePointerCursors = useThemeStore((s) => s.usePointerCursors);

  const updateTheme = useCallback(() => {
    const resolved = resolveTheme(themeMode, lightTheme, darkTheme);
    if (resolved !== currentTheme) {
      useThemeStore.getState().setTheme(resolved);
    }
  }, [themeMode, lightTheme, darkTheme, currentTheme]);

  useLayoutEffect(() => {
    updateTheme();
  }, [updateTheme]);

  useLayoutEffect(() => {
    if (themeMode !== ThemeMode.System) return;

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const handleChange = () => {
      const resolved = resolveTheme(
        useThemeStore.getState().themeMode,
        useThemeStore.getState().lightTheme,
        useThemeStore.getState().darkTheme,
      );
      const current = useThemeStore.getState().theme;
      if (resolved !== current) {
        useThemeStore.getState().setTheme(resolved);
      }
    };
    mediaQuery.addEventListener("change", handleChange);
    return () => mediaQuery.removeEventListener("change", handleChange);
  }, [themeMode]);

  useLayoutEffect(() => {
    applyTheme(currentTheme);
  }, [currentTheme]);

  useLayoutEffect(() => {
    const root = window.document.documentElement;
    if (usePointerCursors) {
      root.classList.remove("no-pointer-cursors");
    } else {
      root.classList.add("no-pointer-cursors");
    }
  }, [usePointerCursors]);

  useLayoutEffect(() => {
    const root = window.document.documentElement;
    const isAndroid =
      Capacitor.isNativePlatform() && Capacitor.getPlatform() === "android";

    if (materialYouEnabled && isAndroid && isNativeBridgeAvailable()) {
      AonsokuNativeBridge.getMaterialYouColors({
        isDark: isDarkTheme(currentTheme),
      })
        .then((result) => {
          if (result.supported && result.colors) {
            for (const [nativeKey, cssKeys] of Object.entries(colorMap)) {
              const hexColor =
                result.colors[nativeKey as keyof typeof result.colors];
              if (hexColor) {
                const hslStr = hexToHslComponents(hexColor);
                for (const cssKey of cssKeys) {
                  root.style.setProperty(cssKey, hslStr);
                }
              }
            }
          } else {
            clearMaterialYouStyles(root);
          }
        })
        .catch((err) => {
          console.error("Failed to get Material You colors", err);
          clearMaterialYouStyles(root);
        });
    } else {
      clearMaterialYouStyles(root);
    }
  }, [currentTheme, materialYouEnabled]);

  return null;
}
