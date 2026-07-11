import { Agent } from "undici";

/**
 * Dedicated undici dispatcher for the Subsonic/Navidrome origin.
 *
 * Node's global `fetch` uses undici's default `Agent`, which caps connections
 * per origin at a low value and has no `headersTimeout`/`bodyTimeout` by
 * default. Every image proxy, stream, metadata request, and sync call in the
 * Electron main process targets the *same* server origin, so the default pool
 * is easily exhausted: a 50-item cover grid alone can open 50 simultaneous
 * fetches, and a single stalled connection never times out, producing
 * async-starvation of every other IPC handler on the main event loop.
 *
 * This agent raises the per-origin connection ceiling and gives undici
 * permission to reclaim stalled headers/bodies itself. It is passed
 * *explicitly* (`{ dispatcher }`) to the Subsonic-facing fetches so it does
 * not affect unrelated main-process fetches.
 *
 * `headersTimeout`/`bodyTimeout` are intentionally generous so that slow
 * servers and large covers are not aborted prematurely; the media-protocol
 * image proxy layers a shorter `AbortSignal.timeout` on top for the display
 * path.
 */
export const subsonicDispatcher = new Agent({
  // Per-origin connection ceiling. The Subsonic origin is shared by image
  // and metadata traffic (the long-lived `stream` stays on Node's default
  // global fetch to avoid body-timeout aborts during buffered playback); 16
  // leaves ample headroom for concurrent metadata/cover fetches.
  connections: 16,
  // Abort if the server does not send response headers within 30s.
  headersTimeout: 30_000,
  // Abort if the body stalls for more than 60s between reads.
  bodyTimeout: 60_000,
  // Keep idle HTTP/1.1 connections alive for reuse.
  keepAliveTimeout: 30_000,
  keepAliveMaxTimeout: 120_000,
});

/**
 * Fetch against the Subsonic origin using the dedicated dispatcher.
 *
 * Wraps the global `fetch` (Node's built-in undici) and injects
 * `subsonicDispatcher` as the `dispatcher` option. The dispatcher is
 * duck-typed by Node's fetch, so an `Agent` from the `undici` npm package is
 * accepted. The `dispatcher` field is not on the standard `RequestInit` type,
 * so it is added via a narrow cast.
 */
export function subsonicFetch(
  input: string | URL,
  init: RequestInit = {},
): Promise<Response> {
  return fetch(input, {
    ...init,
    dispatcher: subsonicDispatcher,
  } as RequestInit & { dispatcher: unknown });
}
