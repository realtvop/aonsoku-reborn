import {
  flushNativeWrites,
  initNativePrefsCache,
} from "@/store/native-storage";

import { ACCOUNT_RESET_KEY, finishAccountReset } from "@/lib/account-reset";

// Other open tabs must release their workers/database handles on account changes.
window.addEventListener("storage", (event) => {
  if (event.key === ACCOUNT_RESET_KEY && event.newValue)
    window.location.reload();
});
const nativePrefsReady = finishAccountReset().then(initNativePrefsCache);
import("@/utils/browser").then(({ blockFeatures }) => {
  blockFeatures();
});

window.addEventListener("beforeunload", flushNativeWrites);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) flushNativeWrites();
});

async function bootstrap() {
  await nativePrefsReady;
  const { renderApp } = await import("@/render-app");
  renderApp(document.getElementById("root") as HTMLElement);
}

bootstrap();
