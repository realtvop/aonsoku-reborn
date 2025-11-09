/**
 * LAN Control types and interfaces
 */

export interface LanControlConfig {
  enabled: boolean;
  port: number;
  password: string;
  allowNavidromeAuth: boolean;
}

export enum LanControlMessageType {
  // Authentication
  AUTH_REQUEST = "auth_request",
  AUTH_RESPONSE = "auth_response",

  // Player control
  PLAY_PAUSE = "play_pause",
  PLAY = "play",
  PAUSE = "pause",
  NEXT = "next",
  PREVIOUS = "previous",
  SEEK = "seek",
  SET_VOLUME = "set_volume",

  // Playlist control
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

  // Shuffle & Repeat
  TOGGLE_SHUFFLE = "toggle_shuffle",
  TOGGLE_REPEAT = "toggle_repeat",
  SET_SHUFFLE = "set_shuffle",
  SET_REPEAT = "set_repeat",

  // State requests
  GET_STATE = "get_state",
  GET_QUEUE = "get_queue",
  GET_CURRENT_SONG = "get_current_song",

  // State updates (server to client)
  STATE_UPDATE = "state_update",
  QUEUE_UPDATE = "queue_update",
  CURRENT_SONG_UPDATE = "current_song_update",

  // Error
  ERROR = "error",
}

export interface LanControlMessage {
  type: LanControlMessageType;
  data?: unknown;
  timestamp?: number;
}

export interface AuthRequestData {
  username?: string;
  password: string;
  authType: "navidrome" | "lan";
}

export interface RemoteDeviceInfo {
  name?: string;
  version?: string;
}

export interface AuthResponseData {
  success: boolean;
  message?: string;
  deviceInfo?: RemoteDeviceInfo;
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
  coverArt?: string;
  duration: number;
}

export interface QueueData {
  songs: CurrentSongData[];
  currentIndex: number;
}

export interface SeekData {
  time: number;
}

export interface VolumeData {
  volume: number;
}

export interface PlaySongData {
  songId: string;
}

export interface PlayAlbumData {
  albumId: string;
  songIndex?: number;
}

export interface PlayPlaylistData {
  playlistId: string;
  songIndex?: number;
}

export interface AddToQueueData {
  songIds: string[];
}

export interface AddAlbumToQueueData {
  albumId: string;
}

export interface AddPlaylistToQueueData {
  playlistId: string;
}

export interface SetShuffleData {
  enabled: boolean;
}

export interface SetRepeatData {
  mode: "off" | "one" | "all";
}

export interface ErrorData {
  message: string;
  code?: string;
}

export interface LanControlServerInfo {
  running: boolean;
  port: number;
  address?: string;
  addresses?: string[];
  error?: string;
}
