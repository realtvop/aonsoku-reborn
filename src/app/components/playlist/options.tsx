import { OptionsButtons } from "@/app/components/options/buttons";
import { DropdownMenuSeparator } from "@/app/components/ui/dropdown-menu";
import { useOptions } from "@/app/hooks/use-options";
import { cacheManager } from "@/service/cache";
import { subsonic } from "@/service/subsonic";
import {
  useIsPinnedHomeItem,
  usePinnedHomeActions,
} from "@/store/pinned-home.store";
import { usePlayerStore } from "@/store/player.store";
import { usePlaylists, useRemovePlaylist } from "@/store/playlists.store";
import { Playlist, PlaylistWithEntries } from "@/types/responses/playlist";
import { ISong } from "@/types/responses/song";

interface PlaylistOptionsProps {
  playlist: PlaylistWithEntries | Playlist;
  variant?: "context" | "dropdown";
  showPlay?: boolean;
  disablePlayNext?: boolean;
  disableAddLast?: boolean;
  disableEdit?: boolean;
  disableDelete?: boolean;
}

export function PlaylistOptions({
  playlist,
  variant = "dropdown",
  showPlay = false,
  disablePlayNext = false,
  disableAddLast = false,
  disableEdit = false,
  disableDelete = false,
}: PlaylistOptionsProps) {
  const { setPlaylistDialogState, setData } = usePlaylists();
  const { playPlaylist, playNext, playLast } = useOptions();
  const { toggle } = usePinnedHomeActions();
  const { setPlaylistId, setConfirmDialogState } = useRemovePlaylist();
  const isUserQueueEmpty = usePlayerStore(
    (state) => state.songlist.userQueue.songs.length === 0,
  );
  const isPinned = useIsPinnedHomeItem({ id: playlist.id, type: "playlist" });
  const isAddLastDisabled = disableAddLast || isUserQueueEmpty;

  function handleEdit() {
    setData({
      id: playlist.id,
      name: playlist.name,
      comment: playlist.comment,
      public: playlist.public,
    });
    setPlaylistDialogState(true);
  }

  async function getSongsToQueue(
    callback: (songs: ISong[], sourceId?: { playlistId: string }) => void,
  ) {
    const playlistWithEntries = await subsonic.playlists.getOne(playlist.id);
    if (!playlistWithEntries) return;

    callback(playlistWithEntries.entry, { playlistId: playlist.id });
  }

  async function handlePlay() {
    await playPlaylist(playlist);
  }

  async function handlePlayNext() {
    if ("entry" in playlist) {
      playNext(playlist.entry, { playlistId: playlist.id });
    } else {
      await getSongsToQueue(playNext);
    }
  }

  async function handlePlayLast() {
    if ("entry" in playlist) {
      playLast(playlist.entry, { playlistId: playlist.id });
    } else {
      await getSongsToQueue(playLast);
    }
  }

  return (
    <>
      {variant === "context" && (
        <>
          <div className="px-2 py-0.5 max-w-64">
            <span className="text-xs text-muted-foreground break-words line-clamp-4">
              {playlist.name}
            </span>
          </div>
          <DropdownMenuSeparator />
        </>
      )}
      {showPlay && (
        <OptionsButtons.Play
          variant={variant}
          onClick={(e) => {
            e.stopPropagation();
            handlePlay();
          }}
        />
      )}
      <OptionsButtons.PlayNext
        variant={variant}
        disabled={disablePlayNext}
        onClick={(e) => {
          e.stopPropagation();
          handlePlayNext();
        }}
      />
      <OptionsButtons.PlayLast
        variant={variant}
        disabled={isAddLastDisabled}
        onClick={(e) => {
          e.stopPropagation();
          handlePlayLast();
        }}
      />
      <DropdownMenuSeparator />
      <OptionsButtons.DownloadPlaylist
        variant={variant}
        onClick={(e) => {
          e.stopPropagation();
          cacheManager.cachePlaylist(playlist.id);
        }}
      />
      {isPinned ? (
        <OptionsButtons.UnpinItem
          variant={variant}
          onClick={(e) => {
            e.stopPropagation();
            toggle({ id: playlist.id, type: "playlist" });
          }}
        />
      ) : (
        <OptionsButtons.PinItem
          variant={variant}
          onClick={(e) => {
            e.stopPropagation();
            toggle({ id: playlist.id, type: "playlist" });
          }}
        />
      )}
      <DropdownMenuSeparator />
      <OptionsButtons.EditPlaylist
        variant={variant}
        onClick={(e) => {
          e.stopPropagation();
          handleEdit();
        }}
        disabled={disableEdit}
      />
      <OptionsButtons.RemovePlaylist
        variant={variant}
        onClick={(e) => {
          e.stopPropagation();
          setPlaylistId(playlist.id);
          setConfirmDialogState(true);
        }}
        disabled={disableDelete}
      />
    </>
  );
}
