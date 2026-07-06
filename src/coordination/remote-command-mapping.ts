import { LanControlMessageType } from "@/types/lanControl";
import type { RemoteCommand } from "./types";

interface PlayerCommandState {
  isShuffleActive: boolean;
  loopState: number;
}

export function repeatModeToLoopState(mode: string | undefined): number {
  switch (mode) {
    case "all":
      return 1;
    case "one":
      return 2;
    default:
      return 0;
  }
}

export function mapLanControlToRemoteCommand(
  type: LanControlMessageType,
  data: unknown,
  getPlayerCommandState: () => PlayerCommandState,
): RemoteCommand | null {
  const d = data as Record<string, unknown> | undefined;

  switch (type) {
    case LanControlMessageType.PLAY:
      return { type: "play" };
    case LanControlMessageType.PAUSE:
      return { type: "pause" };
    case LanControlMessageType.PLAY_PAUSE:
      return { type: "toggle_play_pause" };
    case LanControlMessageType.PREVIOUS:
      return { type: "previous" };
    case LanControlMessageType.NEXT:
      return { type: "next" };
    case LanControlMessageType.SEEK:
      return typeof d?.seconds === "number"
        ? { type: "seek", seconds: d.seconds }
        : null;
    case LanControlMessageType.SET_VOLUME:
      return typeof d?.volume === "number"
        ? { type: "set_volume", volume: d.volume / 100 }
        : null;
    case LanControlMessageType.PLAY_SONG:
      return typeof d?.songId === "string"
        ? { type: "play_song", song_id: d.songId }
        : null;
    case LanControlMessageType.PLAY_ALBUM:
      return typeof d?.albumId === "string"
        ? {
            type: "play_album",
            album_id: d.albumId,
            index: typeof d.songIndex === "number" ? d.songIndex : undefined,
            shuffle: false,
          }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST:
      return typeof d?.playlistId === "string"
        ? {
            type: "play_playlist",
            playlist_id: d.playlistId,
            index: typeof d.songIndex === "number" ? d.songIndex : undefined,
            shuffle: false,
          }
        : null;
    case LanControlMessageType.PLAY_ALBUM_SHUFFLE:
      return typeof d?.albumId === "string"
        ? {
            type: "play_album",
            album_id: d.albumId,
            index: typeof d.songIndex === "number" ? d.songIndex : undefined,
            shuffle: true,
          }
        : null;
    case LanControlMessageType.PLAY_PLAYLIST_SHUFFLE:
      return typeof d?.playlistId === "string"
        ? {
            type: "play_playlist",
            playlist_id: d.playlistId,
            index: typeof d.songIndex === "number" ? d.songIndex : undefined,
            shuffle: true,
          }
        : null;
    case LanControlMessageType.ADD_TO_QUEUE:
      return Array.isArray(d?.songIds)
        ? { type: "add_to_queue_last", song_ids: d.songIds as string[] }
        : null;
    case LanControlMessageType.CLEAR_QUEUE:
      return { type: "clear_queue" };
    case LanControlMessageType.PLAY_AT_INDEX:
      return Array.isArray(d?.songIds) && typeof d.index === "number"
        ? {
            type: "play_at_index",
            song_ids: d.songIds as string[],
            index: d.index,
          }
        : null;
    case LanControlMessageType.TOGGLE_SHUFFLE:
      return {
        type: "set_shuffle",
        enabled: !getPlayerCommandState().isShuffleActive,
      };
    case LanControlMessageType.SET_SHUFFLE:
      return typeof d?.enabled === "boolean"
        ? { type: "set_shuffle", enabled: d.enabled }
        : null;
    case LanControlMessageType.TOGGLE_REPEAT: {
      const loopState = getPlayerCommandState().loopState;
      const mode = loopState === 0 ? "all" : loopState === 1 ? "one" : "off";
      return { type: "set_repeat", mode };
    }
    case LanControlMessageType.SET_REPEAT:
      return typeof d?.mode === "string"
        ? { type: "set_repeat", mode: d.mode }
        : null;
    case LanControlMessageType.TOGGLE_LIKE:
      return { type: "toggle_like" };
    default:
      return null;
  }
}
