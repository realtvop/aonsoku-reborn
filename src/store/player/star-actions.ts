import type { Draft } from "immer";
import { queryClient } from "@/lib/queryClient";
import { star } from "@/service/star";
import { libraryDb, withStarredAt } from "@/store/library-db";
import type { IPlayerActions, IPlayerContext } from "@/types/playerContext";
import { queryKeys } from "@/utils/queryKeys";
import { applyStarToAllLists, hasAnySongs } from "./queue-utils";

interface SharedDeps {
  set: (fn: (state: Draft<IPlayerContext>) => void) => void;
  get: () => IPlayerContext;
}

export function createStarActions(shared: SharedDeps) {
  const { set, get } = shared;

  return {
    starSongInQueue: (id: string) => {
      const {
        contextQueue,
        userQueue,
        originalContextSongs,
        playedUserQueueHistory,
      } = get().songlist;
      const { mediaType } = get().playerState;

      if (
        contextQueue.songs.length === 0 &&
        userQueue.songs.length === 0 &&
        mediaType !== "song"
      )
        return;

      let found = false;
      let newStarred: string | undefined;

      for (const list of [
        contextQueue.songs,
        userQueue.songs,
        playedUserQueueHistory,
        originalContextSongs,
      ]) {
        const song = list.find((s) => s.id === id);
        if (song && !found) {
          found = true;
          newStarred =
            typeof song.starred === "string"
              ? undefined
              : new Date().toISOString();
        }
      }

      if (!found) return;

      set((state) => {
        applyStarToAllLists(state.songlist, id, newStarred);
      });
    },

    starCurrentSong: async () => {
      const sl = get().songlist;
      const { mediaType } = get().playerState;

      if (!hasAnySongs(sl) && mediaType !== "song") return;

      const currentSong = get().songlist.currentSong;
      if (!currentSong) return;

      const { id, starred } = currentSong;
      const isSongStarred = typeof starred === "string";

      await star.handleStarItem({
        id,
        starred: isSongStarred,
      });

      const afterSong = get().songlist.currentSong;
      if (!afterSong || afterSong.id !== id) return;

      const newStarred = isSongStarred ? undefined : new Date().toISOString();

      set((state) => {
        applyStarToAllLists(state.songlist, id, newStarred);
        state.playerState.isSongStarred = !isSongStarred;
      });

      // Update local IndexedDB cache
      await libraryDb.songs.put(
        withStarredAt({
          ...currentSong,
          starred: newStarred,
        }),
      );

      // Invalidate queries so that other UI elements refresh
      queryClient.invalidateQueries({ queryKey: queryKeys.song.all });
      queryClient.invalidateQueries({
        queryKey: queryKeys.favorites.count,
      });
      queryClient.invalidateQueries({
        queryKey: queryKeys.favorites.list,
      });
      if (currentSong.albumId) {
        queryClient.invalidateQueries({
          queryKey: [...queryKeys.album.single, currentSong.albumId],
        });
      }
    },
  } satisfies Partial<IPlayerActions>;
}
