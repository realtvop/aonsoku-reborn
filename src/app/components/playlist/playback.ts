import { subsonic } from "@/service/subsonic";
import type { Playlist, PlaylistWithEntries } from "@/types/responses/playlist";
import type { ISong } from "@/types/responses/song";

export async function resolvePlaylistSongs(
  playlist: Playlist | PlaylistWithEntries,
): Promise<ISong[] | null> {
  if ("entry" in playlist) return playlist.entry;

  const playlistWithEntries = await subsonic.playlists.getOne(playlist.id);
  return playlistWithEntries?.entry ?? null;
}
