import { fileURLToPath } from "node:url";
import type { NativeAudioSource } from "@aonsoku/audio-contract";
import type { ResolvedNativeAudioSource } from "./types";

export class DesktopNativeAudioUnsupportedSourceError extends Error {
  readonly code = "unsupported-source";

  constructor(message: string) {
    super(message);
    this.name = "DesktopNativeAudioUnsupportedSourceError";
  }
}

export function resolveNativeAudioSource(
  source: NativeAudioSource,
): ResolvedNativeAudioSource {
  switch (source.kind) {
    case "stream":
      return {
        kind: "stream",
        target: source.url,
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
