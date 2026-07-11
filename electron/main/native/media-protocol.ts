import { protocol } from "electron";
import { AsyncLimiter } from "./concurrency";
import { desktopNativeBridgeService } from "./bridge/ipc";
import { subsonicFetch } from "./bridge/http-agent";
import { getDesktopNativeDataService } from "./data/ipc";

export const DESKTOP_MEDIA_SCHEME = "aonsoku-media";

/**
 * Bounded-concurrency limiter for the `aonsoku-media://` image proxy.
 *
 * A 50-item album grid fires up to 50 `getCoverArt` requests at once; without
 * a cap they saturate the Subsonic origin's connection pool and starve every
 * other IPC handler on the main event loop (metadata reads, stream setup, …).
 * The limiter queues excess requests — the renderer `<img>` retries on its
 * own, so a short queue delay is harmless and far better than a stalled pool.
 *
 * 6 leaves ample headroom for the long-lived `stream` connection and metadata
 * traffic that share the same origin/dispatcher.
 */
const imageProxyLimiter = new AsyncLimiter(6);

/** Abort image-proxy fetches that stall (display path must not hang forever). */
const IMAGE_PROXY_TIMEOUT_MS = 15_000;

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

    // Image operations: bounded-concurrency fetch with a stall timeout.
    // Stream stays unthrottled (long-lived, streaming).
    if (operation === "getCoverArt" || operation === "getAvatar") {
      try {
        return await imageProxyLimiter.run(() =>
          proxyImage(operation, query, request),
        );
      } catch (error) {
        return new Response(
          error instanceof Error ? error.message : String(error),
          { status: 502 },
        );
      }
    }

    // stream.view — long-lived streaming response. It stays on Node's default
    // global `fetch` (no body timeout) so backpressure during buffered playback
    // never aborts the connection. Pool separation is still achieved: images
    // and metadata were moved off the default agent onto `subsonicDispatcher`,
    // so the stream no longer competes with an unbounded image flood for the
    // default pool's connections.
    try {
      return await fetch(
        desktopNativeBridgeService.getMediaUrl(path, query),
        { headers: request.headers, signal: request.signal },
      );
    } catch (error) {
      return new Response(
        error instanceof Error ? error.message : String(error),
        { status: 502 },
      );
    }
  });
}

/**
 * Fetch a single `getCoverArt`/`getAvatar` from the server through the
 * dedicated Subsonic dispatcher, with a stall timeout layered on top of
 * `request.signal`.
 */
async function proxyImage(
  operation: "getCoverArt" | "getAvatar",
  query: Record<string, string>,
  request: Request,
): Promise<Response> {
  const path =
    operation === "getCoverArt" ? "/getCoverArt.view" : "/getAvatar.view";
  const timeoutSignal = AbortSignal.any([
    request.signal,
    AbortSignal.timeout(IMAGE_PROXY_TIMEOUT_MS),
  ]);
  return subsonicFetch(desktopNativeBridgeService.getMediaUrl(path, query), {
    headers: request.headers,
    signal: timeoutSignal,
  });
}