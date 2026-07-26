import {
  flushNativeWrites,
  initNativePrefsCache,
} from "@/store/native-storage";

const nativePrefsReady = initNativePrefsCache();
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
