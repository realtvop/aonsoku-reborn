import { devtools, subscribeWithSelector } from "zustand/middleware";
import { immer } from "zustand/middleware/immer";
import { createWithEqualityFn } from "zustand/traditional";
import { IPlaylistsContext, PlaylistData } from "@/types/playlistsContext";

export const usePlaylistsStore = createWithEqualityFn<IPlaylistsContext>()(
  subscribeWithSelector(
    devtools(
      immer((set) => ({
        playlistDialogState: false,
        data: {} as PlaylistData,
        setPlaylistDialogState: (dialogState) => {
          set((state) => {
            state.playlistDialogState = dialogState;
          });
        },
        setData: (data) => {
          set((state) => {
            state.data = data;
          });
        },
        removeSong: {
          confirmDialogState: false,
          setConfirmDialogState: (status) => {
            set((state) => {
              state.removeSong.confirmDialogState = status;
            });
          },
          actionData: {
            playlistId: "",
            songIndexes: [],
          },
          setActionData: (data) => {
            set((state) => {
              state.removeSong.actionData = data;
            });
          },
        },
        removePlaylist: {
          confirmDialogState: false,
          setConfirmDialogState: (status) => {
            set((state) => {
              state.removePlaylist.confirmDialogState = status;
            });
          },
          playlistId: "",
          setPlaylistId: (id) => {
            set((state) => {
              state.removePlaylist.playlistId = id;
            });
          },
        },
        playbackConfirmation: {
          open: false,
          playlist: null,
          request: (playlist) => {
            set((state) => {
              state.playbackConfirmation.open = true;
              state.playbackConfirmation.playlist = playlist;
            });
          },
          reset: () => {
            set((state) => {
              state.playbackConfirmation.open = false;
              state.playbackConfirmation.playlist = null;
            });
          },
          setOpen: (open) => {
            set((state) => {
              state.playbackConfirmation.open = open;
              if (!open) {
                state.playbackConfirmation.playlist = null;
              }
            });
          },
        },
      })),
      {
        name: "playlists_store",
      },
    ),
  ),
);

export const usePlaylists = () => usePlaylistsStore((state) => state);

export const usePlaylistRemoveSong = () =>
  usePlaylistsStore((state) => state.removeSong);

export const useRemovePlaylist = () =>
  usePlaylistsStore((state) => state.removePlaylist);

export const usePlaylistPlaybackConfirmation = () =>
  usePlaylistsStore((state) => state.playbackConfirmation);
