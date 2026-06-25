import { FastAverageColor } from "fast-average-color";

export async function getAverageColor(img: HTMLImageElement | null) {
  const fac = new FastAverageColor();

  return await fac.getColorAsync(img, {
    mode: "precision",
    algorithm: "sqrt",
    defaultColor: [16, 183, 127, 1],
  });
}

export function hexToRgb(hex: string) {
  hex = hex.replace(/^#/, "");

  let red: number;
  let green: number;
  let blue: number;

  if (hex.length === 3) {
    red = parseInt(hex[0] + hex[0], 16);
    green = parseInt(hex[1] + hex[1], 16);
    blue = parseInt(hex[2] + hex[2], 16);
  } else if (hex.length === 6) {
    red = parseInt(hex.substring(0, 2), 16);
    green = parseInt(hex.substring(2, 4), 16);
    blue = parseInt(hex.substring(4, 6), 16);
  } else {
    return undefined;
  }

  return [red, green, blue];
}

export function hexToRgba(hex: string, alpha: number = 1) {
  const colors = hexToRgb(hex);
  if (!colors) return undefined;

  const [r, g, b] = colors;

  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

export function hslToRgb(hsl: string): [number, number, number] | undefined {
  if (!hsl) return undefined;

  const [h, s, l] = hsl.split(" ");

  if (!h || !s || !l) return undefined;

  const hue = parseInt(h);
  let saturation = parseFloat(s.replace("%", ""));
  let lightness = parseFloat(l.replace("%", ""));

  // Convert HSL to RGB
  saturation /= 100;
  lightness /= 100;

  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
  const secondComponent = chroma * (1 - Math.abs(((hue / 60) % 2) - 1));
  const matchLightness = lightness - chroma / 2;

  let red: number;
  let green: number;
  let blue: number;

  if (hue < 60) {
    red = chroma;
    green = secondComponent;
    blue = 0;
  } else if (hue < 120) {
    red = secondComponent;
    green = chroma;
    blue = 0;
  } else if (hue < 180) {
    red = 0;
    green = chroma;
    blue = secondComponent;
  } else if (hue < 240) {
    red = 0;
    green = secondComponent;
    blue = chroma;
  } else if (hue < 300) {
    red = secondComponent;
    green = 0;
    blue = chroma;
  } else {
    red = chroma;
    green = 0;
    blue = secondComponent;
  }

  red = (red + matchLightness) * 255;
  green = (green + matchLightness) * 255;
  blue = (blue + matchLightness) * 255;

  return [red, green, blue];
}

function toHex(value: number) {
  const hex = Math.round(value).toString(16);
  return hex.length === 1 ? "0" + hex : hex;
}

export function blendColors(
  baseHex: string,
  overlayHex: string,
  alpha: number,
) {
  const base = hexToRgb(baseHex);
  const overlay = hexToRgb(overlayHex);
  if (!base || !overlay) return baseHex;

  const r = Math.round(base[0] * (1 - alpha) + overlay[0] * alpha);
  const g = Math.round(base[1] * (1 - alpha) + overlay[1] * alpha);
  const b = Math.round(base[2] * (1 - alpha) + overlay[2] * alpha);

  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

export function hslToHex(hsl: string) {
  const rgb = hslToRgb(hsl);
  if (!rgb) return "#000000";

  const [red, green, blue] = rgb;

  return `#${toHex(red)}${toHex(green)}${toHex(blue)}`;
}

export function isDarkColor(hsl: string) {
  const rgb = hslToRgb(hsl);
  if (!rgb) return true;

  const [r, g, b] = rgb;
  const getLinear = (val: number) => {
    const s = val / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  const L =
    0.2126 * getLinear(r) + 0.7152 * getLinear(g) + 0.0722 * getLinear(b);
  return L < 0.43;
}

export function isDarkHex(hex: string) {
  const rgb = hexToRgb(hex);
  if (!rgb) return false;

  const [r, g, b] = rgb;
  const getLinear = (val: number) => {
    const s = val / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  const L =
    0.2126 * getLinear(r) + 0.7152 * getLinear(g) + 0.0722 * getLinear(b);
  return L < 0.43;
}

/**
 * Convert HSL values like "240 10% 3.9%" to "hsla(240, 10%, 3.9%, 1)".
 * @param hsl - The HSL string.
 * @param [alpha=1] - The alpha value (opacity), default is 1.
 */
export function hslToHsla(hsl: string, alpha = 1) {
  if (!hsl) return `hsla(0, 0%, 0%, ${alpha})`;

  const parts = hsl.split(" ");
  if (parts.length < 3) return `hsla(0, 0%, 0%, ${alpha})`;

  const hslBaseString = parts.join(", ");

  return `hsla(${hslBaseString}, ${alpha})`;
}
