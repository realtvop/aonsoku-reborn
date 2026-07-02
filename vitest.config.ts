import path from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "@aonsoku/audio-contract": path.resolve(
        __dirname,
        "./packages/audio-contract/src",
      ),
      "@": path.resolve(__dirname, "./src"),
    },
  },
  define: {
    __BUILD_HASH__: JSON.stringify("test-hash"),
    __BUILD_TIME__: 1714128000000,
  },
  test: {
    environment: "node",
    setupFiles: ["./vitest.setup.ts"],
    globals: false,
    include: ["src/**/*.test.{ts,tsx}", "electron/**/*.test.ts"],
  },
});
