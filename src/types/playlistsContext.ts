import type { Playlist, PlaylistWithEntries } from "@/types/responses/playlist";

export interface PlaylistData {
  id: string;
  name: string;
  comment: string;
  public: boolean;
}

interface RemoveSongFromPlaylistData {
  playlistId: string;
  songIndexes: string[];
}

interface RemoveSong {
  confirmDialogState: boolean;
  setConfirmDialogState: (status: boolean) => void;
  actionData: RemoveSongFromPlaylistData;
  setActionData: (data: RemoveSongFromPlaylistData) => void;
}

interface RemovePlaylist {
  confirmDialogState: boolean;
  setConfirmDialogState: (status: boolean) => void;
  playlistId: string;
  setPlaylistId: (id: string) => void;
}

interface PlaylistPlaybackConfirmation {
  open: boolean;
  playlist: Playlist | PlaylistWithEntries | null;
  request: (playlist: Playlist | PlaylistWithEntries) => void;
  reset: () => void;
  setOpen: (open: boolean) => void;
}

export interface IPlaylistsContext {
  playlistDialogState: boolean;
  setPlaylistDialogState: (state: boolean) => void;
  data: PlaylistData;
  setData: (data: PlaylistData) => void;
  removeSong: RemoveSong;
  removePlaylist: RemovePlaylist;
  playbackConfirmation: PlaylistPlaybackConfirmation;
}
