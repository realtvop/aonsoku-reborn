import { create } from "zustand";
import type { QueueSourceId } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";

export type PlaybackReplacementRequest = (
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
    }
) & { targetDeviceId?: string | null };

interface PlaybackReplacementState {
  open: boolean;
  request: PlaybackReplacementRequest | null;
  show: (request: PlaybackReplacementRequest) => void;
  reset: () => void;
  takeRequest: (
    targetDeviceId: string | null,
  ) => PlaybackReplacementRequest | null;
  setOpen: (open: boolean) => void;
}

export const usePlaybackReplacementStore = create<PlaybackReplacementState>(
  (set, get) => ({
    open: false,
    request: null,
    show: (request) => set({ open: true, request }),
    reset: () => set({ open: false, request: null }),
    takeRequest: (targetDeviceId) => {
      const { request } = get();
      set({ open: false, request: null });
      return request && (request.targetDeviceId ?? null) === targetDeviceId
        ? request
        : null;
    },
    setOpen: (open) =>
      set((state) => ({
        open,
        request: open ? state.request : null,
      })),
  }),
);
