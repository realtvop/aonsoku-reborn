import { create } from "zustand";
import type { QueueSourceId } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";

export type PlaybackReplacementRequest =
  | {
      kind: "songList";
      songs: ISong[];
      index?: number | null;
      shuffle: boolean;
      sourceId?: QueueSourceId | { albumId: string } | { playlistId: string };
      sourceName?: string;
    }
  | {
      kind: "song";
      song: ISong;
      sourceName?: string;
    };

interface PlaybackReplacementState {
  open: boolean;
  request: PlaybackReplacementRequest | null;
  show: (request: PlaybackReplacementRequest) => void;
  reset: () => void;
  setOpen: (open: boolean) => void;
}

export const usePlaybackReplacementStore = create<PlaybackReplacementState>(
  (set) => ({
    open: false,
    request: null,
    show: (request) => set({ open: true, request }),
    reset: () => set({ open: false, request: null }),
    setOpen: (open) =>
      set((state) => ({
        open,
        request: open ? state.request : null,
      })),
  }),
);
