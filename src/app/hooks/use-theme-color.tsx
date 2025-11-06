import { useEffect } from "react";

/**
 * Hook to dynamically update the browser theme-color meta tag
 * based on the current theme and CSS variables
 */
export function useThemeColor() {
  useEffect(() => {
    // Get the computed background color from CSS variables
    const updateThemeColor = () => {
      const root = document.documentElement;
      const bgColor = getComputedStyle(root)
        .getPropertyValue("--background")
        .trim();

      // Convert HSL to hex color for theme-color meta tag
      // --background is typically in format like "222.2 84% 4.9%"
      const hslMatch = bgColor.match(
        /^(\d+\.?\d*)\s+(\d+\.?\d*)%\s+(\d+\.?\d*)%$/
      );

      if (hslMatch) {
        const [, h, s, l] = hslMatch;
        const color = hslToHex(Number(h), Number(s), Number(l));
        updateMetaThemeColor(color);
      } else {
        // Fallback: try to get the actual computed background color of the body
        const bodyBg = getComputedStyle(document.body).backgroundColor;
        if (bodyBg) {
          const color = rgbToHex(bodyBg);
          updateMetaThemeColor(color);
        }
      }
    };

    // Update immediately
    updateThemeColor();

    // Update when theme changes (small delay to ensure CSS is applied)
    const timer = setTimeout(updateThemeColor, 100);

    return () => clearTimeout(timer);
  }, []);
}

/**
 * Update the theme-color meta tag
 */
function updateMetaThemeColor(color: string) {
  let metaTag = document.querySelector('meta[name="theme-color"]');

  if (!metaTag) {
    metaTag = document.createElement("meta");
    metaTag.setAttribute("name", "theme-color");
    document.head.appendChild(metaTag);
  }

  metaTag.setAttribute("content", color);
}

/**
 * Convert HSL to Hex color
 */
function hslToHex(h: number, s: number, l: number): string {
  s /= 100;
  l /= 100;

  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;

  let r = 0;
  let g = 0;
  let b = 0;

  if (h >= 0 && h < 60) {
    r = c;
    g = x;
    b = 0;
  } else if (h >= 60 && h < 120) {
    r = x;
    g = c;
    b = 0;
  } else if (h >= 120 && h < 180) {
    r = 0;
    g = c;
    b = x;
  } else if (h >= 180 && h < 240) {
    r = 0;
    g = x;
    b = c;
  } else if (h >= 240 && h < 300) {
    r = x;
    g = 0;
    b = c;
  } else if (h >= 300 && h < 360) {
    r = c;
    g = 0;
    b = x;
  }

  const toHex = (n: number) => {
    const hex = Math.round((n + m) * 255).toString(16);
    return hex.length === 1 ? "0" + hex : hex;
  };

  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

/**
 * Convert RGB/RGBA string to Hex color
 */
function rgbToHex(rgb: string): string {
  const match = rgb.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*[\d.]+)?\)$/);

  if (!match) return "#000000";

  const toHex = (n: number) => {
    const hex = n.toString(16);
    return hex.length === 1 ? "0" + hex : hex;
  };

  return `#${toHex(Number(match[1]))}${toHex(Number(match[2]))}${toHex(
    Number(match[3])
  )}`;
}
