import { protocol } from "electron";
import { desktopNativeBridgeService } from "./bridge/ipc";
import { getDesktopNativeDataService } from "./data/ipc";

export const DESKTOP_MEDIA_SCHEME = "aonsoku-media";

export function registerDesktopMediaScheme(): void {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: DESKTOP_MEDIA_SCHEME,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        stream: true,
      },
    },
  ]);
}

export function setupDesktopMediaProtocol(): void {
  protocol.handle(DESKTOP_MEDIA_SCHEME, async (request) => {
    const incoming = new URL(request.url);
    const operation = incoming.hostname || incoming.pathname.replace(/^\//, "");
    const query = Object.fromEntries(incoming.searchParams.entries());
    if (operation === "cached") {
      const cached = await getDesktopNativeDataService()?.readCover(
        query.id ?? "",
      );
      return cached
        ? new Response(cached.data, {
            headers: { "Content-Type": cached.contentType },
          })
        : new Response("Cached media not found", { status: 404 });
    }
    const path =
      operation === "getCoverArt"
        ? "/getCoverArt.view"
        : operation === "getAvatar"
          ? "/getAvatar.view"
          : operation === "stream"
            ? "/stream.view"
            : null;
    if (!path)
      return new Response("Unsupported media operation", { status: 404 });
    try {
      return await fetch(desktopNativeBridgeService.getMediaUrl(path, query), {
        headers: request.headers,
        signal: request.signal,
      });
    } catch (error) {
      return new Response(
        error instanceof Error ? error.message : String(error),
        { status: 502 },
      );
    }
  });
}
