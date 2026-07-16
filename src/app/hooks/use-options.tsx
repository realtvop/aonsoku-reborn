import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useMatches } from "react-router-dom";
import {
  resolvePlaylistSongs,
  shouldConfirmPlaylistPlayback,
} from "@/app/components/playlist/playback";
import { subsonic } from "@/service/subsonic";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import {
  usePlaylistRemoveSong,
  usePlaylistsStore,
} from "@/store/playlists.store";
import { useSongInfo } from "@/store/ui.store";
import type { QueueSourceId } from "@/types/playerContext";
import {
  Playlist,
  PlaylistWithEntries,
  UpdateParams,
} from "@/types/responses/playlist";
import { ISong } from "@/types/responses/song";
import { queryKeys } from "@/utils/queryKeys";

type SongIdToAdd = Pick<UpdateParams, "songIdToAdd">["songIdToAdd"];

export function useOptions() {
  const { setNextOnQueue, setLastOnQueue, setSongList } = usePlayerActions();
  const { setActionData, setConfirmDialogState } = usePlaylistRemoveSong();
  const matches = useMatches();
  const { setSongId, setModalOpen } = useSongInfo();

  const isOnPlaylistPage = matches.find((route) => route.id === "playlist");
  const playlistId = isOnPlaylistPage?.params.playlistId ?? "";

  const queryClient = useQueryClient();

  function play(
    list: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
    sourceName?: string,
  ) {
    setSongList(list, 0, false, sourceId, sourceName);
  }

  function playNext(
    list: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
  ) {
    setNextOnQueue(list, sourceId);
  }

  function playLast(
    list: ISong[],
    sourceId?: QueueSourceId | { albumId: string } | { playlistId: string },
  ) {
    setLastOnQueue(list, sourceId);
  }

  async function playPlaylist(playlist: Playlist | PlaylistWithEntries) {
    const { contextQueue } = usePlayerStore.getState().songlist;
    if (shouldConfirmPlaylistPlayback(contextQueue, playlist.id)) {
      usePlaylistsStore.getState().playbackConfirmation.request(playlist);
      return;
    }

    const songs = await resolvePlaylistSongs(playlist);
    if (!songs) return;

    play(songs, { playlistId: playlist.id }, playlist.name);
  }

  const updateMutation = useMutation({
    mutationFn: subsonic.playlists.update,
    onSuccess: () => {
      if (isOnPlaylistPage) {
        queryClient.invalidateQueries({
          queryKey: [...queryKeys.playlist.single, playlistId],
        });
      }
    },
  });

  async function addToPlaylist(id: string, songIdToAdd: SongIdToAdd) {
    await updateMutation.mutateAsync({
      playlistId: id,
      songIdToAdd,
    });
  }

  const createMutation = useMutation({
    mutationFn: subsonic.playlists.createWithDetails,
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.playlist.all,
      });
    },
  });

  async function createNewPlaylist(name: string, songIdToAdd: SongIdToAdd) {
    await createMutation.mutateAsync({
      name,
      comment: "",
      isPublic: "false",
      songIdToAdd,
    });
  }

  function removeSongFromPlaylist(songIndexes: string[]) {
    setActionData({
      playlistId,
      songIndexes,
    });
    setConfirmDialogState(true);
  }

  function openSongInfo(id: string) {
    setSongId(id);
    setModalOpen(true);
  }

  return {
    play,
    playPlaylist,
    playNext,
    playLast,
    addToPlaylist,
    createNewPlaylist,
    removeSongFromPlaylist,
    openSongInfo,
    isOnPlaylistPage,
    playlistId,
  };
}
