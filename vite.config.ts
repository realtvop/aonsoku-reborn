import react from "@vitejs/plugin-react";
import fs from "fs";
import path from "path";
import { defineConfig, type Plugin } from "vite";
import { createManualChunks } from "./manual-chunks";

function swCacheVersionPlugin(buildHash: string): Plugin {
  return {
    name: "sw-cache-version",
    closeBundle() {
      const distDir = path.resolve(__dirname, "dist");
      const swPath = path.join(distDir, "sw.js");

      let content: string;
      try {
        content = fs.readFileSync(swPath, "utf-8");
      } catch {
        // sw.js not in build output — nothing to patch
        return;
      }

      // Generate precache manifest: collect all files under dist/assets/
      const assetFiles: string[] = [];
      const assetsDir = path.join(distDir, "assets");
      if (!fs.existsSync(assetsDir)) {
        return;
      }
      function walk(dir: string, prefix: string) {
        for (const entry of fs.readdirSync(dir, {
          withFileTypes: true,
        })) {
          if (entry.isDirectory()) {
            walk(path.join(dir, entry.name), `${prefix}${entry.name}/`);
          } else if (!entry.name.endsWith(".map")) {
            assetFiles.push(`${prefix}${entry.name}`);
          }
        }
      }
      walk(assetsDir, "/assets/");

      content = content
        .replace(/__SW_CACHE_VERSION__/g, buildHash)
        .replace(/"__SW_PRECACHE_MANIFEST__"/g, JSON.stringify(assetFiles));

      fs.writeFileSync(swPath, content);
    },
  };
}

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  const isMobileBuild = mode === "mobile";
  const isProductionBuild = mode === "production" || isMobileBuild;
  const buildTimestamp = isProductionBuild ? Date.now() : 0;
  const buildHash = buildTimestamp > 0 ? buildTimestamp.toString(36) : "dev";
  return {
    plugins: [
      react(),
      ...(isProductionBuild ? [swCacheVersionPlugin(buildHash)] : []),
    ],
    define: {
      __BUILD_HASH__: JSON.stringify(buildHash),
      __BUILD_TIME__: buildTimestamp,
    },
    resolve: {
      alias: {
        "@aonsoku/audio-contract": path.resolve(
          __dirname,
          "./packages/audio-contract/src",
        ),
        "@": path.resolve(__dirname, "./src"),
        cy: path.resolve(__dirname, "./cypress"),
      },
    },
    build: {
      sourcemap: true,
      minify: "terser",
      rollupOptions: {
        external: ["bufferutil", "utf-8-validate"],
        ...(isMobileBuild
          ? {}
          : {
              output: {
                manualChunks: createManualChunks,
              },
            }),
      },
    },
  };
});
