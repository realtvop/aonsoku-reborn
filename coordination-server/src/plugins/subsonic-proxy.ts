import { Elysia } from "elysia";

const HOP_BY_HOP_HEADERS = [
  "connection",
  "keep-alive",
  "transfer-encoding",
  "te",
  "upgrade",
];

function cleanRequestHeaders(headers: Headers, targetHost: string): Headers {
  const cleaned = new Headers(headers);
  cleaned.set("host", targetHost);
  for (const header of HOP_BY_HOP_HEADERS) {
    cleaned.delete(header);
  }
  return cleaned;
}

export const subsonicProxy = () =>
  new Elysia({ name: "subsonic-proxy", prefix: "/subsonic" }).all(
      "/*",
      async ({ request, params }) => {
        const targetUrl = process.env.SUBSONIC_SERVER_URL;
        if (!targetUrl) {
          return new Response("Subsonic server URL not configured", {
            status: 503,
          });
        }

        const subPath = params["*"] ?? "";
        const url = new URL(request.url);
        const target = new URL(`/${subPath}?${url.search}`, targetUrl);

        const targetHost = new URL(targetUrl).host;
        const headers = cleanRequestHeaders(request.headers, targetHost);

        const proxyRequest = new Request(target.toString(), {
          method: request.method,
          headers,
          body: request.body,
        });

        try {
          return await fetch(proxyRequest);
        } catch {
          return new Response("Subsonic server unreachable", { status: 502 });
        }
      },
    );