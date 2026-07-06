/**
 * Stubs/basic types needed for player store compilation since LAN control is removed.
 */

export enum LanControlMessageType {
  PLAY_PAUSE = "play_pause",
  PLAY = "play",
  PAUSE = "pause",
  NEXT = "next",
  PREVIOUS = "previous",
  SEEK = "seek",
  SET_VOLUME = "set_volume",
  PLAY_SONG = "play_song",
  PLAY_ALBUM = "play_album",
  PLAY_PLAYLIST = "play_playlist",
  PLAY_ALBUM_SHUFFLE = "play_album_shuffle",
  PLAY_PLAYLIST_SHUFFLE = "play_playlist_shuffle",
  PLAY_ALBUM_FROM_INDEX = "play_album_from_index",
  PLAY_PLAYLIST_FROM_INDEX = "play_playlist_from_index",
  ADD_TO_QUEUE = "add_to_queue",
  ADD_ALBUM_TO_QUEUE = "add_album_to_queue",
  ADD_PLAYLIST_TO_QUEUE = "add_playlist_to_queue",
  CLEAR_QUEUE = "clear_queue",
  PLAY_AT_INDEX = "play_at_index",
  TOGGLE_SHUFFLE = "toggle_shuffle",
  TOGGLE_REPEAT = "toggle_repeat",
  SET_SHUFFLE = "set_shuffle",
  SET_REPEAT = "set_repeat",
  TOGGLE_LIKE = "toggle_like",
  GET_STATE = "get_state",
  GET_QUEUE = "get_queue",
  GET_CURRENT_SONG = "get_current_song",
  STATE_UPDATE = "state_update",
  QUEUE_UPDATE = "queue_update",
  CURRENT_SONG_UPDATE = "current_song_update",
  ERROR = "error",
}

export interface RemoteDeviceInfo {
  name?: string;
  version?: string;
}

export interface PlayerStateData {
  isPlaying: boolean;
  currentTime: number;
  duration: number;
  volume: number;
  isShuffle: boolean;
  repeatMode: "off" | "one" | "all";
  hasPrevious: boolean;
  hasNext: boolean;
}

export interface CurrentSongData {
  id: string;
  title: string;
  artist: string;
  album: string;
  albumId?: string;
  coverArt?: string;
  duration: number;
}

export interface QueueData {
  songs: CurrentSongData[];
  currentIndex: number;
}
