import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Search, Music, Disc, ListMusic } from "lucide-react";
import { Input } from "@/app/components/ui/input";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/app/components/ui/tabs";
import { Button } from "@/app/components/ui/button";
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { subsonic } from "@/service/subsonic";
import { ISong } from "@/types/responses/song";
import { Albums } from "@/types/responses/album";
import { Playlist } from "@/types/responses/playlist";
import { getCoverArtUrl } from "@/api/httpClient";
import { LanControlMessageType } from "@/types/lanControl";
import { useLanControlClientStore } from "@/store/lanControlClient.store";

interface LibraryBrowserProps {
  isConnected: boolean;
}

export function LibraryBrowser({ isConnected }: LibraryBrowserProps) {
  const { t } = useTranslation();
  const actions = useLanControlClientStore((state) => state.actions);

  const [searchQuery, setSearchQuery] = useState("");
  const [isSearching, setIsSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<{
    songs: ISong[];
    albums: Albums[];
  }>({ songs: [], albums: [] });

  const [albums, setAlbums] = useState<Albums[]>([]);
  const [isLoadingAlbums, setIsLoadingAlbums] = useState(false);

  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [isLoadingPlaylists, setIsLoadingPlaylists] = useState(false);

  const handleSearch = async () => {
    if (!searchQuery.trim()) return;

    setIsSearching(true);
    try {
      const results = await subsonic.search.get({
        query: searchQuery,
        songCount: 20,
        albumCount: 20,
        artistCount: 0,
      });

      setSearchResults({
        songs: results?.song || [],
        albums: results?.album || [],
      });
    } catch (error) {
      console.error("Search failed:", error);
    } finally {
      setIsSearching(false);
    }
  };

  const loadAlbums = async () => {
    setIsLoadingAlbums(true);
    try {
      const response = await subsonic.albums.getAlbumList({
        type: "newest",
        size: 50,
        offset: 0,
      });
      setAlbums(response?.list || []);
    } catch (error) {
      console.error("Failed to load albums:", error);
    } finally {
      setIsLoadingAlbums(false);
    }
  };

  const loadPlaylists = async () => {
    setIsLoadingPlaylists(true);
    try {
      const response = await subsonic.playlists.getAll();
      setPlaylists(response || []);
    } catch (error) {
      console.error("Failed to load playlists:", error);
    } finally {
      setIsLoadingPlaylists(false);
    }
  };

  const handlePlaySong = (songId: string) => {
    if (!isConnected) return;
    actions.send({
      type: LanControlMessageType.PLAY_SONG,
      data: { songId },
    });
  };

  const handlePlayAlbum = (albumId: string) => {
    if (!isConnected) return;
    actions.send({
      type: LanControlMessageType.PLAY_ALBUM,
      data: { albumId },
    });
  };

  const handlePlayPlaylist = (playlistId: string) => {
    if (!isConnected) return;
    actions.send({
      type: LanControlMessageType.PLAY_PLAYLIST,
      data: { playlistId },
    });
  };

  return (
    <div className="grid gap-4">
      <Tabs defaultValue="search" className="w-full">
        <TabsList className="grid w-full grid-cols-3">
          <TabsTrigger value="search">
            <Search className="h-4 w-4 mr-2" />
            {t("lanControl.remote.library.search")}
          </TabsTrigger>
          <TabsTrigger value="albums" onClick={loadAlbums}>
            <Disc className="h-4 w-4 mr-2" />
            {t("lanControl.remote.library.albums")}
          </TabsTrigger>
          <TabsTrigger value="playlists" onClick={loadPlaylists}>
            <ListMusic className="h-4 w-4 mr-2" />
            {t("lanControl.remote.library.playlists")}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="search" className="space-y-4">
          <div className="flex gap-2">
            <Input
              placeholder={t("lanControl.remote.library.searchPlaceholder")}
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleSearch()}
              disabled={!isConnected}
            />
            <Button
              onClick={handleSearch}
              disabled={!isConnected || isSearching}
            >
              {isSearching
                ? t("lanControl.remote.library.searching")
                : t("lanControl.remote.library.searchButton")}
            </Button>
          </div>

          <ScrollArea className="h-[400px]">
            {searchResults.songs.length > 0 && (
              <div className="space-y-2 mb-4">
                <h4 className="font-semibold text-sm flex items-center gap-2">
                  <Music className="h-4 w-4" />
                  {t("lanControl.remote.library.songs")} (
                  {searchResults.songs.length})
                </h4>
                <div className="space-y-1">
                  {searchResults.songs.map((song) => (
                    <div
                      key={song.id}
                      className="flex items-center gap-3 p-2 rounded hover:bg-muted cursor-pointer transition-colors"
                      onClick={() => handlePlaySong(song.id)}
                    >
                      <div className="shrink-0">
                        <img
                          src={getCoverArtUrl(song.coverArt, "album", "50")}
                          alt={song.title}
                          className="h-10 w-10 rounded object-cover"
                        />
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="font-medium truncate text-sm">
                          {song.title}
                        </div>
                        <div className="text-xs text-muted-foreground truncate">
                          {song.artist}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {searchResults.albums.length > 0 && (
              <div className="space-y-2">
                <h4 className="font-semibold text-sm flex items-center gap-2">
                  <Disc className="h-4 w-4" />
                  {t("lanControl.remote.library.albums")} (
                  {searchResults.albums.length})
                </h4>
                <div className="grid grid-cols-2 gap-2">
                  {searchResults.albums.map((album) => (
                    <div
                      key={album.id}
                      className="flex flex-col gap-2 p-2 rounded hover:bg-muted cursor-pointer transition-colors"
                      onClick={() => handlePlayAlbum(album.id)}
                    >
                      <img
                        src={getCoverArtUrl(album.coverArt, "album", "150")}
                        alt={album.name}
                        className="w-full aspect-square rounded object-cover"
                      />
                      <div className="space-y-1">
                        <div className="font-medium truncate text-sm">
                          {album.name}
                        </div>
                        <div className="text-xs text-muted-foreground truncate">
                          {album.artist}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {!isSearching &&
              searchQuery &&
              searchResults.songs.length === 0 &&
              searchResults.albums.length === 0 && (
                <div className="text-center text-muted-foreground py-8">
                  {t("lanControl.remote.library.noResults")}
                </div>
              )}
          </ScrollArea>
        </TabsContent>

        <TabsContent value="albums" className="space-y-4">
          <ScrollArea className="h-[400px]">
            {isLoadingAlbums ? (
              <div className="text-center text-muted-foreground py-8">
                {t("lanControl.remote.library.loading")}
              </div>
            ) : albums.length > 0 ? (
              <div className="grid grid-cols-2 gap-2">
                {albums.map((album) => (
                  <div
                    key={album.id}
                    className="flex flex-col gap-2 p-2 rounded hover:bg-muted cursor-pointer transition-colors"
                    onClick={() => handlePlayAlbum(album.id)}
                  >
                    <img
                      src={getCoverArtUrl(album.coverArt, "album", "150")}
                      alt={album.name}
                      className="w-full aspect-square rounded object-cover"
                    />
                    <div className="space-y-1">
                      <div className="font-medium truncate text-sm">
                        {album.name}
                      </div>
                      <div className="text-xs text-muted-foreground truncate">
                        {album.artist}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center text-muted-foreground py-8">
                {t("lanControl.remote.library.noAlbums")}
              </div>
            )}
          </ScrollArea>
        </TabsContent>

        <TabsContent value="playlists" className="space-y-4">
          <ScrollArea className="h-[400px]">
            {isLoadingPlaylists ? (
              <div className="text-center text-muted-foreground py-8">
                {t("lanControl.remote.library.loading")}
              </div>
            ) : playlists.length > 0 ? (
              <div className="space-y-1">
                {playlists.map((playlist) => (
                  <div
                    key={playlist.id}
                    className="flex items-center gap-3 p-3 rounded hover:bg-muted cursor-pointer transition-colors"
                    onClick={() => handlePlayPlaylist(playlist.id)}
                  >
                    <div className="shrink-0">
                      <img
                        src={getCoverArtUrl(playlist.coverArt, "album", "50")}
                        alt={playlist.name}
                        className="h-12 w-12 rounded object-cover"
                      />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="font-medium truncate">
                        {playlist.name}
                      </div>
                      <div className="text-xs text-muted-foreground">
                        {playlist.songCount}{" "}
                        {t("lanControl.remote.library.songs")}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center text-muted-foreground py-8">
                {t("lanControl.remote.library.noPlaylists")}
              </div>
            )}
          </ScrollArea>
        </TabsContent>
      </Tabs>
    </div>
  );
}
