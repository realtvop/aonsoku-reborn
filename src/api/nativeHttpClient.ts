import { getNativeBridge } from "@/native/bridge/facade";
import { AppRequestError } from "./errors";
import type { FetchOptions } from "./httpClient";

export async function nativeHttpClient<T>(
  path: string,
  options: FetchOptions,
): Promise<{ count: number; data: T }> {
  const query: Record<string, string | number> = {};

  if (options.query) {
    for (const [key, value] of Object.entries(options.query)) {
      if (value !== undefined) {
        query[key] = value;
      }
    }
  }

  try {
    const response = await getNativeBridge().request({
      path,
      method: (options.method as "GET" | "POST" | "PUT" | "DELETE") ?? "GET",
      query,
      body: typeof options.body === "string" ? options.body : undefined,
    });

    return {
      count: response.count,
      data: response.data as T,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Native request failed";

    if (message.includes("network_unreachable")) {
      throw new AppRequestError(
        "network_unreachable",
        "The configured server is unreachable",
        { url: path },
      );
    }
    if (message.includes("auth_failed")) {
      throw new AppRequestError("server_error", "Authentication failed", {
        url: path,
      });
    }
    if (message.includes("http_error")) {
      throw new AppRequestError("http_error", message, { url: path });
    }
    if (message.includes("parse_error")) {
      throw new AppRequestError("parse_error", message, { url: path });
    }

    throw new AppRequestError("server_error", message, { url: path });
  }
}
