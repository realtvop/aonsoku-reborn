#!/usr/bin/env node
// Generates the Android theme palettes from the web theme variables so the
// native app and the web app share one source of truth (src/themes.css).
//
// Usage: node scripts/android/generate-theme-palettes.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const cssPath = resolve(root, "src/themes.css");
const typesPath = resolve(root, "src/types/themeContext.ts");
const outPath = resolve(
  root,
  "android/app/src/main/java/github/realtvop/aonsoku/theme/ThemePalettes.kt",
);

const tokens = [
  ["background", "background"],
  ["background-foreground", "backgroundForeground"],
  ["foreground", "foreground"],
  ["card", "card"],
  ["card-foreground", "cardForeground"],
  ["popover", "popover"],
  ["popover-foreground", "popoverForeground"],
  ["primary", "primary"],
  ["primary-foreground", "primaryForeground"],
  ["secondary", "secondary"],
  ["secondary-foreground", "secondaryForeground"],
  ["muted", "muted"],
  ["muted-foreground", "mutedForeground"],
  ["accent", "accent"],
  ["accent-foreground", "accentForeground"],
  ["destructive", "destructive"],
  ["destructive-foreground", "destructiveForeground"],
  ["border", "border"],
  ["input", "input"],
  ["ring", "ring"],
];

function hslToArgb(value) {
  const [h, s, l] = value
    .trim()
    .split(/\s+/)
    .map((part) => Number.parseFloat(part));
  const sat = s / 100;
  const light = l / 100;
  const chroma = (1 - Math.abs(2 * light - 1)) * sat;
  const hue = (((h % 360) + 360) % 360) / 60;
  const x = chroma * (1 - Math.abs((hue % 2) - 1));
  let rgb = [0, 0, 0];
  if (hue < 1) rgb = [chroma, x, 0];
  else if (hue < 2) rgb = [x, chroma, 0];
  else if (hue < 3) rgb = [0, chroma, x];
  else if (hue < 4) rgb = [0, x, chroma];
  else if (hue < 5) rgb = [x, 0, chroma];
  else rgb = [chroma, 0, x];
  const m = light - chroma / 2;
  const hex = rgb
    .map((channel) =>
      Math.round((channel + m) * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("")
    .toUpperCase();
  return `0xFF${hex}`;
}

const css = readFileSync(cssPath, "utf8");
const types = readFileSync(typesPath, "utf8");

const themeIds = [...types.matchAll(/^\s+\w+ = "([a-z0-9-]+)",$/gm)]
  .map((match) => match[1])
  .filter((id) => !["system"].includes(id));
const orderedIds = [...new Set(themeIds)].filter((id) =>
  new RegExp(`^\\s*\\.${id}\\s*\\{`, "m").test(css),
);

const lightBlock = types.match(/export const lightThemes[^=]*= \[([^\]]+)\]/);
const enumNames = Object.fromEntries(
  [...types.matchAll(/^\s+(\w+) = "([a-z0-9-]+)",$/gm)].map((match) => [
    match[1],
    match[2],
  ]),
);
const lightIds = new Set(
  [...lightBlock[1].matchAll(/Theme\.(\w+)/g)].map(
    (match) => enumNames[match[1]],
  ),
);

const palettes = orderedIds.map((id) => {
  const block = css.match(new RegExp(`\\.${id}\\s*\\{([^}]+)\\}`));
  if (!block) throw new Error(`Missing theme block: ${id}`);
  const values = Object.fromEntries(
    [...block[1].matchAll(/--([a-z-]+):\s*([^;]+);/g)].map((match) => [
      match[1],
      match[2],
    ]),
  );
  for (const [cssName] of tokens) {
    if (!values[cssName]) throw new Error(`Theme ${id} is missing --${cssName}`);
  }
  return { id, isDark: !lightIds.has(id), values };
});

const lines = [
  "// GENERATED FILE — do not edit by hand.",
  "// Source: src/themes.css and src/types/themeContext.ts",
  "// Regenerate with: node scripts/android/generate-theme-palettes.mjs",
  "",
  "package github.realtvop.aonsoku.theme",
  "",
  "import androidx.compose.ui.graphics.Color",
  "",
  "/** Color tokens of one web theme, converted from HSL to sRGB. */",
  "data class ThemePalette(",
  "    val id: String,",
  "    val isDark: Boolean,",
  ...tokens.map(([, name]) => `    val ${name}: Color,`),
  ")",
  "",
  "/** Every theme of the web app, in the order of the web theme picker. */",
  "val themePalettes: List<ThemePalette> = listOf(",
  ...palettes.flatMap((palette) => [
    "    ThemePalette(",
    `        id = "${palette.id}",`,
    `        isDark = ${palette.isDark},`,
    ...tokens.map(
      ([cssName, name]) =>
        `        ${name} = Color(${hslToArgb(palette.values[cssName])}),`,
    ),
    "    ),",
  ]),
  ")",
  "",
];

writeFileSync(outPath, lines.join("\n"));
console.log(`Wrote ${palettes.length} palettes to ${outPath}`);
