const CORE_VENDOR_EXTRAS = ["comlink"];

// Patterns that identify "heavy" vendor packages — optional features
// loaded on demand (lyrics visualizer, PixiJS, audio context, etc.)
const HEAVY_VENDOR_PATTERNS = [
  // PixiJS visualizer
  "@pixi",
  "pixi",
  // Apple Music-like lyrics
  "@applemusic-like-lyrics",
  // Audio context (visualizer)
  "standardized-audio-context",
  "automation-events",
  // HTML-to-text and its dependency tree
  "html-to-text",
  "linkify-it",
  "htmlparser2",
  "domelementtype",
  "domhandler",
  "domutils",
  "dom-serializer",
  "entities",
  "selderee",
  "@selderee",
  "parseley",
  "leac",
  "peberminta",
  "void-elements",
  "detect-node-es",
  // Lightbox
  "yet-another-react-lightbox",
  // Markdown rendering
  "markdown",
  "remark",
  // JSS (CSS-in-JS for lyrics)
  "jss",
  // Animation library (loaded with fullscreen player)
  "framer-motion",
];

export function createManualChunks(id: string) {
  // 1. All lazy-loaded pages and layout → single async "pages" chunk
  if (id.includes("/src/app/pages/") || id.includes("/src/app/layout/")) {
    return "pages";
  }

  if (!id.includes("node_modules")) return undefined;

  const modulePath = id.split("node_modules/")[1];
  const topLevelFolder = modulePath.split("/")[0];
  const pkgName =
    topLevelFolder === ".pnpm" ? modulePath.split("/")[1] : topLevelFolder;
  const has = (s: string) => pkgName.includes(s);

  // 2. Heavy vendor — optional features loaded on demand
  if (HEAVY_VENDOR_PATTERNS.some(has)) return "heavy-vendor";

  // 3. Core vendor extras — should load early with core vendor
  if (CORE_VENDOR_EXTRAS.some(has)) return "core-vendor";

  // 4. Everything else in node_modules → core-vendor
  return "core-vendor";
}
