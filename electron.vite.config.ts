import react from "@vitejs/plugin-react";
import { defineConfig } from "electron-vite";
import { resolve } from "path";
import { createManualChunks } from "./manual-chunks";

export default defineConfig(() => {
  const buildTimestamp = Date.now();
  return {
    main: {
      build: {
        minify: "terser",
        sourcemap: true,
        rollupOptions: {
          input: {
            index: resolve(__dirname, "electron/main/index.ts"),
          },
        },
      },
    },
    preload: {
      build: {
        minify: "terser",
        sourcemap: true,
        rollupOptions: {
          input: {
            index: resolve(__dirname, "electron/preload/index.ts"),
          },
        },
      },
    },
    renderer: {
      root: ".",
      plugins: [react()],
      define: {
        __BUILD_HASH__: JSON.stringify(buildTimestamp.toString(36)),
        __BUILD_TIME__: buildTimestamp,
      },
      resolve: {
        alias: {
          "@aonsoku/audio-contract": resolve(
            __dirname,
            "./packages/audio-contract/src",
          ),
          "@": resolve(__dirname, "./src"),
        },
      },
      build: {
        sourcemap: true,
        minify: "terser",
        rollupOptions: {
          input: {
            index: resolve(__dirname, "index.html"),
            "native-debug": resolve(
              __dirname,
              "electron/renderer/native-debug/index.html",
            ),
          },
          output: {
            manualChunks: createManualChunks,
          },
        },
      },
    },
  };
});
