import omit from "lodash/omit";
import { markServerUnreachable } from "@/app/hooks/use-network-status";
import { isNativeBridgeAvailable } from "@/native/bridge/facade";
import { useAppStore } from "@/store/app.store";
import type { CoverArt } from "@/types/coverArtType";
import { getRuntime } from "@/utils/capabilities";
import { AppRequestError } from "./errors";
import { nativeHttpClient } from "./nativeHttpClient";
import {
  buildAvatarUrl as _buildAvatarUrl,
  buildCoverArtUrl as _buildCoverArtUrl,
  buildSongStreamUrl as _buildSongStreamUrl,
  buildUrl,
  type ServerAuthConfig,
} from "./urlBuilder";

export type { ServerAuthConfig } from "./urlBuilder";

export type QueryType = Record<string, string | number | undefined>;

export interface FetchOptions extends RequestInit {
  query?: QueryType;
}

function getAuthConfig(): ServerAuthConfig {
  const { url, username, password, authType, protocolVersion } =
    useAppStore.getState().data;
  return { url, username, password, authType, protocolVersion };
}

async function browserFetch<T>(url: string, options: RequestInit) {
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
      markServerUnreachable();
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

export async function httpClient<T>(
  path: string,
  options: FetchOptions,
): Promise<{ count: number; data: T }> {
  if (isNativeBridgeAvailable()) {
    return nativeHttpClient<T>(path, options);
  }

  const url = buildUrl(
    path,
    getAuthConfig(),
    options.query as Record<string, string | number | undefined>,
  );

  try {
    const init = omit(options, "query");

    return await browserFetch<T>(url, init);
  } catch (error) {
    console.error("Error on httpClient request", error);

    throw error;
  }
}

export function getAvatarUrl(username: string, size?: string): string {
  if (getRuntime() === "capacitor-ios" || getRuntime() === "electron") {
    const params = new URLSearchParams({ username });
    if (size) params.set("size", size);
    return `aonsoku-media://getAvatar?${params.toString()}`;
  }
  return _buildAvatarUrl(getAuthConfig(), username, size);
}

export function getCoverArtUrl(
  id?: string,
  type: CoverArt = "album",
  size = "300",
): string {
  if (getRuntime() === "capacitor-ios" || getRuntime() === "electron") {
    if (!id) {
      type = type === "artist" ? "artist" : "album";
      return `/default_${type}_art.png`;
    }
    return `aonsoku-media://getCoverArt?id=${id}&size=${size}`;
  }
  return _buildCoverArtUrl(getAuthConfig(), id, type, size);
}

export function getSongStreamUrl(
  id: string,
  maxBitRate?: string,
  format?: string,
) {
  const runtime = getRuntime();
  if (
    runtime === "capacitor-ios" ||
    runtime === "capacitor-android" ||
    runtime === "electron"
  ) {
    const params = new URLSearchParams({ id });
    if (maxBitRate) params.set("maxBitRate", maxBitRate);
    if (format) params.set("format", format);
    return `aonsoku-media://stream?${params.toString()}`;
  }
  return _buildSongStreamUrl(getAuthConfig(), id, maxBitRate, format);
}
