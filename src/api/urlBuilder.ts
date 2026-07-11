import type { CoverArt } from "@/types/coverArtType";
import type { AuthType } from "@/types/serverConfig";
import { appName } from "@/utils/appName";
import { type AuthParams, authQueryParams } from "./auth";

export interface ServerAuthConfig {
  url: string;
  username: string;
  password: string;
  authType: AuthType | null;
  protocolVersion?: string;
}

export function buildQueryParams(
  config: ServerAuthConfig,
): Record<string, string> {
  const { username, password, authType, protocolVersion } = config;
  const auth: AuthParams = authQueryParams(username, password, authType);

  return {
    ...auth,
    v: protocolVersion || "1.16.0",
    c: appName,
    f: "json",
  };
}

export function buildUrl(
  path: string,
  config: ServerAuthConfig,
  extraQuery?: Record<string, string | number | undefined>,
): string {
  const params = new URLSearchParams(
    buildQueryParams(config) as Record<string, string>,
  );

  if (extraQuery) {
    for (const [key, value] of Object.entries(extraQuery)) {
      if (value !== undefined) {
        params.append(key, value.toString());
      }
    }
  }

  const queries = params.toString();
  const pathWithoutSlash = path.startsWith("/") ? path.substring(1) : path;
  let url = `${config.url}/rest/${pathWithoutSlash}`;
  url += path.includes("?") ? "&" : "?";
  url += queries;

  return url;
}

export function buildCoverArtUrl(
  config: ServerAuthConfig,
  id?: string,
  type: CoverArt = "album",
  size = "300",
): string | undefined {
  if (!id) {
    return undefined;
  }
  return buildUrl("getCoverArt", config, { id, size });
}

export function buildAvatarUrl(
  config: ServerAuthConfig,
  username: string,
  size?: string,
): string {
  return buildUrl("getAvatar", config, { username, size });
}

export function buildSongStreamUrl(
  config: ServerAuthConfig,
  id: string,
  maxBitRate?: string,
  format?: string,
): string {
  return buildUrl("stream", config, {
    id,
    maxBitRate,
    format,
    // "false" avoids HTTP/2 framing issues in browsers; native AVPlayer uses "true"
    // (set in NativeSourceResolver) so it can issue Range requests for seek/buffering.
    estimateContentLength: "false",
  });
}
