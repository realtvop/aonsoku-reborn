import { subsonic } from "@/service/subsonic";
import type { IContextQueue } from "@/types/playerContext";
import type { Playlist, PlaylistWithEntries } from "@/types/responses/playlist";
import type { ISong } from "@/types/responses/song";

export function shouldConfirmPlaylistPlayback(
  contextQueue: IContextQueue,
  playlistId: string,
): boolean {
  if (contextQueue.songs.length === 0) return false;

  return !(
    contextQueue.sourceId?.type === "playlist" &&
    contextQueue.sourceId.id === playlistId
  );
}

export async function resolvePlaylistSongs(
  playlist: Playlist | PlaylistWithEntries,
): Promise<ISong[] | null> {
  if ("entry" in playlist) return playlist.entry;

  const playlistWithEntries = await subsonic.playlists.getOne(playlist.id);
  return playlistWithEntries?.entry ?? null;
}
