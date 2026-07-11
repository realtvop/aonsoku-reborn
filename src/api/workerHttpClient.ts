import type { CoverArt } from "@/types/coverArtType";
import { AppRequestError } from "./errors";
import {
  buildCoverArtUrl as _buildCoverArtUrl,
  buildSongStreamUrl as _buildSongStreamUrl,
  buildUrl,
  type ServerAuthConfig,
} from "./urlBuilder";

export type { QueryType, ServerAuthConfig } from "./urlBuilder";

export interface FetchOptions extends RequestInit {
  query?: Record<string, string | number | undefined>;
}

let authConfig: ServerAuthConfig | null = null;

export function initAuth(config: ServerAuthConfig): void {
  authConfig = config;
}

export function updateAuth(config: ServerAuthConfig): void {
  authConfig = config;
}

export function ensureAuth(): ServerAuthConfig {
  if (!authConfig) {
    throw new Error("workerHttpClient: auth config not initialized");
  }
  return authConfig;
}

async function workerFetch<T>(url: string, options: RequestInit) {
  try {
    const response = await fetch(url, options);

    if (!response.ok) {
      throw new AppRequestError("http_error", `HTTP ${response.status}`, {
        status: response.status,
        url,
      });
    }

    let data: Record<string, unknown>;

    try {
      data = (await response.json()) as Record<string, unknown>;
    } catch {
      throw new AppRequestError("parse_error", "Failed to parse response", {
        url,
      });
    }

    const parsed = data["subsonic-response"] as
      | (T & { status?: string; error?: { message?: string } })
      | undefined;

    if (!parsed) {
      throw new AppRequestError(
        "parse_error",
        "Missing subsonic response payload",
        { url },
      );
    }

    if (parsed.status === "failed") {
      throw new AppRequestError(
        "server_error",
        parsed.error?.message || "Server returned a failed response",
        { url },
      );
    }

    return {
      count: parseInt(response.headers.get("x-total-count") || "0", 10),
      data: parsed as T,
    };
  } catch (error) {
    if (error instanceof AppRequestError) {
      throw error;
    }

    if (error instanceof TypeError) {
      throw new AppRequestError(
        "network_unreachable",
        "The configured server is unreachable",
        { url },
      );
    }

    throw new AppRequestError("server_error", "Unexpected request error", {
      url,
    });
  }
}

export async function workerHttpClient<T>(
  path: string,
  options: FetchOptions = {},
): Promise<{ count: number; data: T }> {
  const config = ensureAuth();
  const url = buildUrl(
    path,
    config,
    options.query as Record<string, string | number | undefined> | undefined,
  );

  const { query: _, ...init } = options;
  return workerFetch<T>(url, init as RequestInit);
}

export function getCoverArtUrl(
  id?: string,
  type: CoverArt = "album",
  size = "300",
): string | undefined {
  return _buildCoverArtUrl(ensureAuth(), id, type, size);
}

export function getSongStreamUrl(
  id: string,
  maxBitRate?: string,
  format?: string,
): string {
  return _buildSongStreamUrl(ensureAuth(), id, maxBitRate, format);
}
