import "react-lazy-load-image-component/src/effects/opacity.css";
import "react-toastify/dist/ReactToastify.css";
import "@/fonts.css";
import "@/themes.css";
import "@/index.css";
import "@/i18n";

import { QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "@/App";
import { ErrorBoundary } from "@/app/components/error-boundary";
import { queryClient } from "@/lib/queryClient";

export function renderApp(rootElement: HTMLElement) {
  createRoot(rootElement).render(
    <StrictMode>
      <ErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </ErrorBoundary>
    </StrictMode>,
  );
}
