import { useQuery } from "@tanstack/react-query";
import { SearchIcon } from "lucide-react";
import { KeyboardEvent, useCallback, useEffect, useState } from "react";
import { useHotkeys } from "react-hotkeys-hook";
import { useTranslation } from "react-i18next";
import { useLocation, useParams } from "react-router-dom";
import { useDebouncedCallback } from "use-debounce";
import { Keyboard } from "@/app/components/command/keyboard-key";
import { Button } from "@/app/components/ui/button";
import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandInput,
  CommandList,
} from "@/app/components/ui/command";
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { getPodcast } from "@/queries/podcasts";
import { subsonic } from "@/service/subsonic";
import { useAppStore } from "@/store/app.store";
import { byteLength } from "@/utils/byteLength";
import { convertMinutesToMs } from "@/utils/convertSecondsToTime";
import { queryKeys } from "@/utils/queryKeys";
import { CommandAlbumResult } from "./album-result";
import { CommandArtistResult } from "./artist-result";
import { CommandGotoPage } from "./goto-page";
import { CommandHome, CommandPages } from "./home";
import { CommandPlaylists } from "./playlists";
import { CommandServer } from "./server-management";
import { CommandSongResult } from "./song-result";
import { CommandThemes } from "./themes";

export type CommandItemProps = {
  runCommand: (command: () => unknown) => void;
};

export default function CommandMenu() {
  const { t } = useTranslation();
  const { open, setOpen } = useAppStore((state) => state.command);
  const location = useLocation();
  const params = useParams();

  const [query, setQuery] = useState("");
  const [pages, setPages] = useState<CommandPages[]>(["HOME"]);
  const [pageTitle, setPageTitle] = useState<string>("Aonsoku");

  const activePage = pages[pages.length - 1];
  const isHome = activePage === "HOME";

  const enableQuery = Boolean(
    byteLength(query) >= 3 && activePage !== "PLAYLISTS"
  );

  const { data: albumData } = useQuery({
    queryKey: [queryKeys.album.single, params.albumId],
    queryFn: () => subsonic.albums.getOne(params.albumId!),
    enabled: Boolean(params.albumId),
    staleTime: convertMinutesToMs(5),
  });

  const { data: artistData } = useQuery({
    queryKey: [queryKeys.artist.single, params.artistId],
    queryFn: () => subsonic.artists.getOne(params.artistId!),
    enabled: Boolean(params.artistId),
    staleTime: convertMinutesToMs(5),
  });

  const { data: playlistData } = useQuery({
    queryKey: [queryKeys.playlist.single, params.playlistId],
    queryFn: () => subsonic.playlists.getOne(params.playlistId!),
    enabled: Boolean(params.playlistId),
    staleTime: convertMinutesToMs(5),
  });

  const { data: podcastData } = useQuery({
    queryKey: [queryKeys.podcast.one, params.podcastId],
    queryFn: () => getPodcast(params.podcastId!),
    enabled: Boolean(params.podcastId),
    staleTime: convertMinutesToMs(5),
  });

  useEffect(() => {
    const pathname = location.pathname;

    // 首页
    if (pathname === "/") {
      setPageTitle("Aonsoku");
      return;
    }

    if (pathname === "/library/artists") {
      setPageTitle(t("sidebar.artists"));
      return;
    }
    if (pathname === "/library/songs") {
      setPageTitle(t("sidebar.songs"));
      return;
    }
    if (pathname === "/library/albums") {
      setPageTitle(t("sidebar.albums"));
      return;
    }
    if (pathname === "/library/playlists") {
      setPageTitle(t("sidebar.playlists"));
      return;
    }
    if (pathname === "/library/radios") {
      setPageTitle(t("sidebar.radios"));
      return;
    }
    if (pathname === "/library/podcasts") {
      setPageTitle(t("sidebar.podcasts"));
      return;
    }
    if (pathname === "/library/episodes/latest") {
      setPageTitle(t("sidebar.podcasts"));
      return;
    }

    if (pathname.startsWith("/library/artists/") && artistData) {
      setPageTitle(artistData.name);
      return;
    }
    if (pathname.startsWith("/library/albums/") && albumData) {
      setPageTitle(albumData.name);
      return;
    }
    if (pathname.startsWith("/library/playlists/") && playlistData) {
      setPageTitle(playlistData.name);
      return;
    }
    if (pathname.startsWith("/library/podcasts/") && podcastData) {
      setPageTitle(
        podcastData.title || podcastData.description || t("sidebar.podcasts")
      );
      return;
    }
    if (pathname.startsWith("/library/episodes/")) {
      setPageTitle(t("sidebar.podcasts"));
      return;
    }

    if (pathname === "/server-config") {
      setPageTitle(t("menu.server"));
      return;
    }

    setPageTitle("Aonsoku");
  }, [location.pathname, albumData, artistData, playlistData, podcastData, t]);

  const { data: searchResult } = useQuery({
    queryKey: [queryKeys.search, query],
    queryFn: () =>
      subsonic.search.get({
        query,
        albumCount: 4,
        artistCount: 4,
        songCount: 4,
      }),
    enabled: enableQuery,
    staleTime: convertMinutesToMs(5),
  });

  const albums = searchResult?.album ?? [];
  const artists = searchResult?.artist ?? [];
  const songs = searchResult?.song ?? [];

  const showAlbumGroup = Boolean(query && albums.length > 0);
  const showArtistGroup = Boolean(query && artists.length > 0);
  const showSongGroup = Boolean(query && songs.length > 0);

  useHotkeys(["/", "mod+f", "mod+k"], () => setOpen(!open), {
    preventDefault: true,
  });

  const clear = useCallback(() => {
    setQuery("");
    setPages(["HOME"]);
  }, []);

  const runCommand = useCallback(
    (command: () => unknown) => {
      setOpen(false);
      clear();
      command();
    },
    [clear, setOpen]
  );

  const debounced = useDebouncedCallback((value: string) => {
    setQuery(value);
  }, 500);

  function handleInputKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "/") {
      event.preventDefault();
    }
  }

  function handleSearchChange(value: string) {
    if (activePage === "PLAYLISTS") {
      setQuery(value);
    } else {
      debounced(value);
    }
  }

  const removeLastPage = useCallback(() => {
    setPages((pages) => {
      const tempPages = [...pages];
      tempPages.splice(-1, 1);
      return tempPages;
    });
  }, []);

  const inputPlaceholder = () => {
    if (activePage === "PLAYLISTS") return t("options.playlist.search");

    return t("command.inputPlaceholder");
  };

  const showNotFoundMessage = Boolean(
    enableQuery && !showAlbumGroup && !showArtistGroup && !showSongGroup
  );

  return (
    <>
      <Button
        variant="outline"
        className="w-full px-2 gap-2 h-8 overflow-hidden md:relative hidden md:flex"
        onClick={() => setOpen(true)}
      >
        <SearchIcon className="h-5 w-5 text-muted-foreground" />
        <span className="inline-flex text-muted-foreground text-xs">
          {pageTitle}
        </span>

        <div className="absolute right-2">
          <Keyboard text="/" />
        </div>
      </Button>
      <Button
          variant="outline"
          className="w-full h-fit flex flex-col justify-center items-center gap-1 md:hidden"
          onClick={() => setOpen(true)}
        >
          <SearchIcon className="w-4 h-4" />
        </Button>

      <CommandDialog
        open={open}
        onOpenChange={(state) => {
          if (isHome) {
            setOpen(state);
            clear();
          } else {
            removeLastPage();
          }
        }}
      >
        <Command shouldFilter={activePage === "PLAYLISTS"} id="main-command">
          <CommandInput
            data-testid="command-menu-input"
            placeholder={inputPlaceholder()}
            autoCorrect="false"
            autoCapitalize="false"
            spellCheck="false"
            onValueChange={(value) => handleSearchChange(value)}
            onKeyDown={handleInputKeyDown}
          />
          <ScrollArea className="max-h-[500px] 2xl:max-h-[700px]">
            <CommandList className="max-h-fit pr-1">
              <CommandEmpty>{t("command.noResults")}</CommandEmpty>

              {showNotFoundMessage && (
                <div className="flex justify-center items-center p-4 mt-2 mx-2 bg-accent/40 rounded border border-border">
                  <p className="text-sm">{t("command.noResults")}</p>
                </div>
              )}

              {showAlbumGroup && (
                <CommandAlbumResult
                  query={query}
                  albums={albums}
                  runCommand={runCommand}
                />
              )}

              {showSongGroup && (
                <CommandSongResult
                  query={query}
                  songs={songs}
                  runCommand={runCommand}
                />
              )}

              {showArtistGroup && (
                <CommandArtistResult
                  artists={artists}
                  runCommand={runCommand}
                />
              )}

              {isHome && (
                <CommandHome
                  pages={pages}
                  setPages={setPages}
                  runCommand={runCommand}
                />
              )}

              {activePage === "GOTO" && (
                <CommandGotoPage runCommand={runCommand} />
              )}

              {activePage === "THEME" && (
                <CommandThemes runCommand={runCommand} />
              )}

              {activePage === "PLAYLISTS" && (
                <CommandPlaylists runCommand={runCommand} />
              )}

              {activePage === "SERVER" && <CommandServer />}
            </CommandList>
          </ScrollArea>
          <div className="flex justify-end p-2 h-10 gap-1 border-t">
            <Keyboard text="ESC" className="text-sm" />
            <Keyboard text="↓" className="text-sm" />
            <Keyboard text="↑" className="text-sm" />
            <Keyboard text="↵" className="text-sm" />
          </div>
        </Command>
      </CommandDialog>
    </>
  );
}
