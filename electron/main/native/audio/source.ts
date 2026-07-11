import { fileURLToPath } from "node:url";
import type {
  NativeAudioCachedAudioFile,
  NativeAudioSource,
} from "@aonsoku/audio-contract";
import type { ResolvedNativeAudioSource } from "./types";

export class DesktopNativeAudioUnsupportedSourceError extends Error {
  readonly code = "unsupported-source";

  constructor(message: string) {
    super(message);
    this.name = "DesktopNativeAudioUnsupportedSourceError";
  }
}

export type DesktopAudioFileResolver = {
  resolveAudioFile(songId: string): Promise<NativeAudioCachedAudioFile | null>;
};

export interface ResolveNativeAudioSourceOptions {
  streamUrlResolver?: (url: string) => string;
  audioFileResolver?: DesktopAudioFileResolver;
}

export function resolveNativeAudioSource(
  source: NativeAudioSource,
  streamUrlResolver: (url: string) => string = (url) => url,
): ResolvedNativeAudioSource {
  switch (source.kind) {
    case "stream":
      return {
        kind: "stream",
        target: streamUrlResolver(source.url),
      };
    case "radio":
      return {
        kind: "radio",
        target: source.url,
      };
    case "native-file":
      return {
        kind: "native-file",
        target: normalizeNativeFileUri(source.uri),
      };
    case "blob":
      throw new DesktopNativeAudioUnsupportedSourceError(
        "Desktop native audio does not support blob sources yet.",
      );
  }
}

function normalizeNativeFileUri(uri: string): string {
  if (!uri.startsWith("file:")) return uri;

  return fileURLToPath(uri);
}

// Cache-first source resolution, mirroring the mobile NativeSourceResolver
// behavior: for stream sources that carry a songId, prefer a locally cached
// audio file (downloaded/offline copy) over the network stream URL. On a
// cache hit the engine receives a native-file target; on a miss (or when no
// songId/resolver is available) it falls back to the authenticated stream
// URL. Radio/blob/native-file sources keep their existing synchronous
// semantics and are unaffected.
export async function resolveNativeAudioSourceWithCache(
  source: NativeAudioSource,
  options: ResolveNativeAudioSourceOptions = {},
): Promise<ResolvedNativeAudioSource> {
  if (source.kind === "stream" && source.songId) {
    const cached = await options.audioFileResolver?.resolveAudioFile(
      source.songId,
    );
    if (cached) {
      return {
        kind: "native-file",
        target: normalizeNativeFileUri(cached.uri),
      };
    }
  }

  return resolveNativeAudioSource(source, options.streamUrlResolver);
}
