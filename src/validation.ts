import type {
  Envelope,
  PlaybackSnapshot,
  RemoteCommand,
} from "./protocol";
import { fail, integer, MAX_BYTES, object, string, uuid } from "./security";

function finite(value: unknown, min = 0, max = Number.MAX_VALUE) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < min ||
    value > max
  )
    fail("bad_message", "invalid number");
}
function boolean(value: unknown) {
  if (typeof value !== "boolean") fail("bad_message", "invalid boolean");
}
function songs(value: unknown) {
  if (!Array.isArray(value)) fail("bad_message", "invalid song list");
  if (value.length > 2000) fail("payload_too_large", "too many songs");
  for (const id of value) string(id);
  return value.length;
}
export function snapshot(value: unknown): PlaybackSnapshot {
  const s = object(value);
  uuid(s.sessionId);
  uuid(s.logicalPlaybackSessionId);
  string(s.songId);
  if (s.mediaKind !== "song")
    fail("unsupported_media", "only songs are supported");
  for (const field of [
    "progressSeconds",
    "durationSeconds",
    "sampledAt",
    "accumulatedPlaySeconds",
  ])
    finite(s[field]);
  for (const field of [
    "isPlaying",
    "inUserQueue",
    "shuffle",
    "historyWritten",
    "nowPlayingSent",
    "scrobbleSent",
  ])
    boolean(s[field]);
  const total =
    songs(s.contextQueue) + songs(s.userQueue) + songs(s.restorePrevious);
  if (total > 2000)
    fail("payload_too_large", "snapshot exceeds song count limit");
  s.contextIndex ??= null;
  s.volume ??= null;
  s.sourceId ??= null;
  s.sourceName ??= null;
  if (s.contextIndex !== null)
    integer(
      s.contextIndex,
      0,
      Math.max(0, (s.contextQueue as string[]).length - 1),
    );
  if (s.volume !== null) finite(s.volume, 0, 1);
  for (const field of ["sourceId", "sourceName"])
    if (s[field] !== null && typeof s[field] !== "string")
      fail("bad_message", "invalid source metadata");
  if (!["off", "one", "all"].includes(string(s.repeat)))
    fail("bad_message", "invalid repeat mode");
  return s as unknown as PlaybackSnapshot;
}
export function command(value: unknown): RemoteCommand {
  const c = object(value);
  const type = string(c.type);
  switch (type) {
    case "play":
    case "pause":
    case "toggle_play_pause":
    case "previous":
    case "next":
    case "toggle_like":
    case "clear_queue":
      break;
    case "seek":
      finite(c.seconds);
      break;
    case "set_volume":
      finite(c.volume, 0, 1);
      break;
    case "set_shuffle":
      boolean(c.enabled);
      break;
    case "set_repeat":
      if (!["off", "one", "all"].includes(string(c.mode)))
        fail("bad_message", "invalid repeat mode");
      break;
    case "play_song":
      string(c.song_id);
      break;
    case "play_album":
    case "play_playlist":
      string(type === "play_album" ? c.album_id : c.playlist_id);
      if (c.index !== undefined && c.index !== null) integer(c.index);
      if (c.shuffle !== undefined && c.shuffle !== null) boolean(c.shuffle);
      break;
    case "add_to_queue_next":
    case "add_to_queue_last":
    case "remove_from_queue":
      songs(c.song_ids);
      break;
    case "play_at_index":
      integer(c.index, 0, songs(c.song_ids) - 1);
      break;
    case "reorder_queue":
      integer(c.from);
      integer(c.to);
      break;
    default:
      fail("bad_message", "unknown command");
  }
  return c as unknown as RemoteCommand;
}
export function envelope(raw: string | ArrayBuffer): Envelope {
  if (typeof raw !== "string") fail("bad_message", "expected text message");
  if (new TextEncoder().encode(raw).byteLength > MAX_BYTES)
    fail("payload_too_large", "message too large");
  let value: Record<string, unknown>;
  try {
    value = object(JSON.parse(raw));
  } catch {
    fail("bad_message", "invalid JSON");
  }
  if (value.version !== 1)
    fail("protocol_incompatible", "server protocol is 1");
  uuid(value.messageId);
  string(value.type);
  if (value.seq !== undefined && value.seq !== null) integer(value.seq);
  return value as unknown as Envelope;
}
