import React from "react";
import { createRoot } from "react-dom/client";

// Strategy A: reuse only shared CSS (theme variables + Tailwind base) from the
// main project so the debug window matches the app's dark theme. No other
// `src/` imports — the debug page is self-contained and never enters the
// web/Capacitor bundles.
import "@/fonts.css";
import "@/themes.css";
import "@/index.css";

import { NativeDebugApp } from "./app";

const root = document.getElementById("root");
if (!root) {
  throw new Error("Native debug root element missing");
}

// The app themes are class-based (see src/themes.css). Apply the dark theme
// directly — the debug window is a developer tool and does not follow the
// user's theme preference.
document.documentElement.classList.add("dark");

createRoot(root).render(
  <React.StrictMode>
    <NativeDebugApp />
  </React.StrictMode>,
);
