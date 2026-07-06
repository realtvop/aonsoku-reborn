import type { RemoteCommand } from "./types";

export function mapNativeRemoteControlCommand(
  command: Record<string, unknown>,
): RemoteCommand | null {
  switch (command.type) {
    case "play":
      return { type: "play" };
    case "pause":
      return { type: "pause" };
    case "toggle":
    case "toggle_play_pause":
      return { type: "toggle_play_pause" };
    case "previous":
      return { type: "previous" };
    case "next":
      return { type: "next" };
    case "seek":
      return numberCommand(command.seconds, (seconds) => ({
        type: "seek",
        seconds: Math.max(0, seconds),
      }));
    case "set_volume":
      return numberCommand(command.volume, (volume) => ({
        type: "set_volume",
        volume: Math.max(0, Math.min(1, volume)),
      }));
    case "set_shuffle":
      return typeof command.enabled === "boolean"
        ? { type: "set_shuffle", enabled: command.enabled }
        : null;
    case "set_repeat":
      return typeof command.mode === "string"
        ? { type: "set_repeat", mode: command.mode }
        : null;
    case "toggle_like":
      return { type: "toggle_like" };
    case "play_song":
      return typeof command.song_id === "string"
        ? { type: "play_song", song_id: command.song_id }
        : null;
    case "play_album":
      return typeof command.album_id === "string"
        ? {
            type: "play_album",
            album_id: command.album_id,
            index: optionalNumber(command.index),
            shuffle: optionalBoolean(command.shuffle),
          }
        : null;
    case "play_playlist":
      return typeof command.playlist_id === "string"
        ? {
            type: "play_playlist",
            playlist_id: command.playlist_id,
            index: optionalNumber(command.index),
            shuffle: optionalBoolean(command.shuffle),
          }
        : null;
    case "add_to_queue_next":
    case "add_to_queue_last":
    case "remove_from_queue":
      return stringArrayCommand(command.type, command.song_ids);
    case "reorder_queue":
      return typeof command.from === "number" && typeof command.to === "number"
        ? { type: "reorder_queue", from: command.from, to: command.to }
        : null;
    case "clear_queue":
      return { type: "clear_queue" };
    case "play_at_index":
      return Array.isArray(command.song_ids) &&
        command.song_ids.every((id) => typeof id === "string") &&
        typeof command.index === "number"
        ? {
            type: "play_at_index",
            song_ids: command.song_ids,
            index: command.index,
          }
        : null;
    default:
      return null;
  }
}

function numberCommand<T>(
  value: unknown,
  build: (value: number) => T,
): T | null {
  return typeof value === "number" && Number.isFinite(value)
    ? build(value)
    : null;
}

function optionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function optionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function stringArrayCommand(
  type: "add_to_queue_next" | "add_to_queue_last" | "remove_from_queue",
  value: unknown,
): RemoteCommand | null {
  if (!Array.isArray(value) || !value.every((id) => typeof id === "string")) {
    return null;
  }

  return {
    type,
    song_ids: value,
  };
}
