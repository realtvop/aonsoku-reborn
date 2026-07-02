import type { PlaybackErrorEvent, PlaybackErrorKind } from "./types";

export const PLAYBACK_MEDIA_ERROR_CODES = {
  aborted: 1,
  network: 2,
  decode: 3,
  sourceNotSupported: 4,
} as const;

const nativeErrorKindByCode = new Map<string, PlaybackErrorKind>([
  ["aborted", "aborted"],
  ["cancelled", "aborted"],
  ["seek_cancelled", "aborted"],
  ["network", "network"],
  ["network_error", "network"],
  ["network_unreachable", "network"],
  ["not_connected_to_internet", "network"],
  ["timed_out", "network"],
  ["cannot_connect_to_host", "network"],
  ["cannot_find_host", "network"],
  ["data_not_allowed", "network"],
  ["load_failed", "network"],
  ["playback_failed", "network"],
  ["decode", "decode"],
  ["decode_error", "decode"],
  ["decode_failed", "decode"],
  ["invalid_source", "source-not-supported"],
  ["unsupported_source", "source-not-supported"],
  ["source_not_supported", "source-not-supported"],
  ["src_not_supported", "source-not-supported"],
  ["no_source", "source-not-supported"],
]);

export function playbackErrorKindFromCode(
  code: PlaybackErrorEvent["code"],
): PlaybackErrorKind {
  switch (code) {
    case PLAYBACK_MEDIA_ERROR_CODES.aborted:
      return "aborted";
    case PLAYBACK_MEDIA_ERROR_CODES.network:
      return "network";
    case PLAYBACK_MEDIA_ERROR_CODES.decode:
      return "decode";
    case PLAYBACK_MEDIA_ERROR_CODES.sourceNotSupported:
      return "source-not-supported";
    default:
      return typeof code === "string"
        ? (nativeErrorKindByCode.get(code) ?? "unknown")
        : "unknown";
  }
}

export function playbackErrorCodeFromKind(
  kind: PlaybackErrorKind,
): number | undefined {
  switch (kind) {
    case "aborted":
      return PLAYBACK_MEDIA_ERROR_CODES.aborted;
    case "network":
      return PLAYBACK_MEDIA_ERROR_CODES.network;
    case "decode":
      return PLAYBACK_MEDIA_ERROR_CODES.decode;
    case "source-not-supported":
      return PLAYBACK_MEDIA_ERROR_CODES.sourceNotSupported;
    case "unknown":
      return undefined;
  }
}

export function nativePlaybackErrorKind(
  nativeCode?: string,
): PlaybackErrorKind {
  if (!nativeCode) return "unknown";

  return nativeErrorKindByCode.get(nativeCode.toLowerCase()) ?? "unknown";
}

export function getPlaybackErrorKind(
  event: PlaybackErrorEvent,
): PlaybackErrorKind {
  if (event.kind) return event.kind;

  const nativeKind = nativePlaybackErrorKind(event.nativeCode);
  if (nativeKind !== "unknown") return nativeKind;

  return playbackErrorKindFromCode(event.code);
}

export function shouldRetryPlaybackError(
  event: PlaybackErrorEvent,
  options: { isRadio?: boolean } = {},
) {
  switch (getPlaybackErrorKind(event)) {
    case "aborted":
    case "source-not-supported":
      return false;
    case "decode":
      return options.isRadio === true;
    case "network":
    case "unknown":
      return true;
  }
}
