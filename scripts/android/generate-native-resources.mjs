import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const target = path.join(root, "android/app/src/main/assets/native");
const locales = path.join(root, "src/i18n/locales");
function flatten(value, prefix = "", result = {}) {
  for (const [key, entry] of Object.entries(value)) {
    const name = prefix ? `${prefix}.${key}` : key;
    if (typeof entry === "string") result[name] = entry;
    else if (entry && typeof entry === "object") flatten(entry, name, result);
  }
  return result;
}
const english = flatten(JSON.parse(await readFile(path.join(locales, "en.json"), "utf8")));
const translations = {};
for (const file of (await readdir(locales)).filter((name) => name.endsWith(".json")).sort()) {
  const translated = flatten(JSON.parse(await readFile(path.join(locales, file), "utf8")));
  const code = { en: "en-US", es: "es-ES" }[file.slice(0, -5)] ?? file.slice(0, -5);
  translations[code] = Object.fromEntries(Object.entries(english).map(([key, text]) => [text, translated[key] ?? text]));
}
function hslToHex(h, s, l) {
  s /= 100;
  l /= 100;
  const a = s * Math.min(l, 1 - l);
  return `#${[0, 8, 4].map((n) => {
    const k = (n + h / 30) % 12;
    const color = l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return Math.round(color * 255).toString(16).padStart(2, "0");
  }).join("")}`;
}
const css = await readFile(path.join(root, "src/themes.css"), "utf8");
const themes = {};
for (const match of css.matchAll(/\.([\w-]+)\s*\{([^}]+)\}/g)) {
  const colors = {};
  for (const value of match[2].matchAll(/--([\w-]+):\s*([\d.]+)\s+([\d.]+)%\s+([\d.]+)%/g)) {
    colors[value[1]] = hslToHex(Number(value[2]), Number(value[3]), Number(value[4]));
  }
  if (colors.background) themes[match[1]] = colors;
}
await mkdir(target, { recursive: true });
for (const [name, value] of Object.entries({ translations, themes })) {
  await writeFile(path.join(target, `${name}.json`), `${JSON.stringify(value)}\n`);
}
console.log(`Generated ${Object.keys(themes).length} Android themes and ${Object.keys(translations).length} languages.`);
