import { QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import "react-lazy-load-image-component/src/effects/opacity.css";
import "react-toastify/dist/ReactToastify.css";
import "@/fonts.css";
import "@/themes.css";
import "@/index.css";

import "@/i18n";

import { ErrorBoundary } from "@/app/components/error-boundary";
import { queryClient } from "@/lib/queryClient";
import {
  flushNativeWrites,
  initNativePrefsCache,
} from "@/store/native-storage";
import { blockFeatures } from "@/utils/browser";

blockFeatures();

if (import.meta.env.DEV) {
  installAudioSidecarDebugHarnessForDev().catch((error) => {
    console.warn("[AudioSidecarDebug] install failed", error);
  });
}

window.addEventListener("beforeunload", flushNativeWrites);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) flushNativeWrites();
});

async function bootstrap() {
  await initNativePrefsCache();
  const { default: App } = await import("@/App");

  createRoot(document.getElementById("root") as HTMLElement).render(
    <StrictMode>
      <ErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </ErrorBoundary>
    </StrictMode>,
  );
}

bootstrap();

async function installAudioSidecarDebugHarnessForDev() {
  const { installAudioSidecarDebugHarness } = await import(
    "@/native/audio/sidecar-debug"
  );
  await installAudioSidecarDebugHarness(window, {
    isDev: true,
    log: console,
  });
}
