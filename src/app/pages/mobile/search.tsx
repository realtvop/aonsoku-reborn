import { Play, SearchIcon } from "lucide-react";
import { startTransition, useRef } from "react";
import { useTranslation } from "react-i18next";
import { Link, useNavigate } from "react-router-dom";
import { useDebouncedCallback } from "use-debounce";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { MobilePageHeader } from "@/app/components/header/mobile-page-header";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { useSongList } from "@/app/hooks/use-song-list";
import {
  getOfflineSearchResults,
  useOfflineQuery,
} from "@/lib/offlineQueryClient";
import { AonsokuNativeData, isNativeDataAvailable } from "@/native/data/facade";
import { ROUTES } from "@/routes/routesList";
import { subsonic } from "@/service/subsonic";
import { usePlayerActions } from "@/store/player.store";
import { useMobileSearch } from "@/store/ui.store";
import { CoverArt } from "@/types/coverArtType";
import { Albums } from "@/types/responses/album";
import { ISimilarArtist } from "@/types/responses/artist";
import { Search } from "@/types/responses/search";
import { ISong } from "@/types/responses/song";
import { byteLength } from "@/utils/byteLength";
import { convertMinutesToMs } from "@/utils/convertSecondsToTime";
import { queryKeys } from "@/utils/queryKeys";

interface MobileResultItemProps {
  coverArt: string;
  coverArtType: CoverArt;
  albumId?: string;
  title: string;
  subtitle: string;
  onRowClick: () => void;
  onPlayClick: () => void;
}

function MobileResultItem({
  coverArt,
  coverArtType,
  albumId,
  title,
  subtitle,
  onRowClick,
  onPlayClick,
}: MobileResultItemProps) {
  return (
    <button
      type="button"
      className="flex min-h-14 w-full items-center gap-3 px-4 py-2 active:bg-accent/50 text-left"
      onClick={() => startTransition(onRowClick)}
    >
      <CachedImage
        coverArtId={coverArt}
        coverArtType={coverArtType}
        albumId={albumId}
        alt={`${subtitle} - ${title}`}
        width={44}
        height={44}
        className="aspect-square object-cover rounded shadow flex-shrink-0"
      />
      <div className="flex flex-col justify-center flex-1 min-w-0">
        <span className="font-medium text-sm truncate">{title}</span>
        <span className="text-xs text-muted-foreground truncate">
          {subtitle}
        </span>
      </div>
      <Button
        variant="ghost"
        size="sm"
        className="size-11 p-0 rounded-full flex-shrink-0"
        onClick={(e) => {
          e.stopPropagation();
          startTransition(onPlayClick);
        }}
      >
        <Play className="w-4 h-4 fill-foreground" />
      </Button>
    </button>
  );
}

interface SectionProps {
  title: string;
  seeMoreHref?: string;
  children: React.ReactNode;
}

function ResultSection({ title, seeMoreHref, children }: SectionProps) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col">
      <div className="flex justify-between items-center px-4 py-2">
        <span className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
          {title}
        </span>
        {seeMoreHref && (
          <Link
            to={seeMoreHref}
            className="text-xs text-primary underline-offset-1 hover-supported:underline"
          >
            {t("generic.seeMore")}
          </Link>
        )}
      </div>
      {children}
    </div>
  );
}

async function nativeSearch(query: string, count: number): Promise<Search> {
  if (isNativeDataAvailable()) {
    const result = await AonsokuNativeData.search({
      query,
      artistCount: count,
      albumCount: count,
      songCount: count,
    });
    return {
      artist: result.artists as unknown as ISimilarArtist[],
      album: result.albums as unknown as Albums[],
      song: result.songs as unknown as ISong[],
    };
  }
  return getOfflineSearchResults({
    query,
    artistCount: count,
    albumCount: count,
    songCount: count,
  });
}

export default function MobileSearch() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const inputRef = useRef<HTMLInputElement>(null);
  const { query, setQuery } = useMobileSearch();
  const { playSong, setSongList } = usePlayerActions();
  const { getAlbumSongs, getArtistAllSongs } = useSongList();

  const enableQuery = byteLength(query) >= 3;

  const { data: searchResult } = useOfflineQuery(
    [...queryKeys.search, query],
    () =>
      subsonic.search.get({
        query,
        albumCount: 6,
        artistCount: 6,
        songCount: 6,
      }),
    {
      offlineFn: () => nativeSearch(query, 6),
      enabled: enableQuery,
      staleTime: convertMinutesToMs(5),
    },
  );

  const albums: Albums[] = searchResult?.album ?? [];
  const artists: ISimilarArtist[] = searchResult?.artist ?? [];
  const songs: ISong[] = searchResult?.song ?? [];

  const hasResults =
    albums.length > 0 || artists.length > 0 || songs.length > 0;
  const showNoResults = enableQuery && !hasResults;

  const composingRef = useRef(false);

  const debounced = useDebouncedCallback((value: string) => {
    setQuery(value);
  }, 500);

  function navigateWithFlush(to: string) {
    debounced.flush();
    navigate(to);
  }

  async function handlePlayAlbum(albumId: string, albumName: string) {
    const albumSongs = await getAlbumSongs(albumId);
    if (albumSongs) setSongList(albumSongs, 0, false, { albumId }, albumName);
  }

  async function handlePlayArtist(artist: ISimilarArtist) {
    const artistSongs = await getArtistAllSongs(artist.id);
    if (artistSongs) setSongList(artistSongs, 0, false, undefined, artist.name);
  }

  return (
    <div className="flex flex-col w-full h-full">
      <div className="sticky top-0 z-10 bg-background border-b">
        <MobilePageHeader
          variant="root"
          title={t("sidebar.miniSearch")}
          showUserDropdown
        />
        <div
          className="px-4 pb-3 pt-0"
          style={{
            paddingLeft: "max(1rem, var(--safe-area-left))",
            paddingRight: "max(1rem, var(--safe-area-right))",
          }}
        >
          <div className="relative flex items-center">
            <SearchIcon className="absolute left-3 w-4 h-4 text-muted-foreground pointer-events-none" />
            <Input
              ref={inputRef}
              data-scroll-dismiss-keyboard="true"
              autoFocus
              defaultValue={query}
              placeholder={t("command.inputPlaceholder")}
              className="pl-9"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !composingRef.current) {
                  e.preventDefault();
                  debounced.flush();
                  inputRef.current?.blur();
                }
              }}
              onCompositionStart={() => {
                composingRef.current = true;
              }}
              onCompositionEnd={(e) => {
                composingRef.current = false;
                debounced(e.currentTarget.value);
              }}
              onChange={(e) => {
                if (!composingRef.current) {
                  debounced(e.target.value);
                }
              }}
            />
          </div>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        {showNoResults && (
          <div className="flex justify-center items-center p-8">
            <p className="text-sm text-muted-foreground">
              {t("command.noResults")}
            </p>
          </div>
        )}

        {albums.length > 0 && (
          <ResultSection
            title={t("sidebar.albums")}
            seeMoreHref={ROUTES.ALBUMS.SEARCH(query)}
          >
            {albums.map((album) => (
              <MobileResultItem
                key={album.id}
                coverArt={album.coverArt}
                coverArtType="album"
                title={album.name}
                subtitle={album.artist}
                onRowClick={() =>
                  navigateWithFlush(ROUTES.ALBUM.PAGE(album.id))
                }
                onPlayClick={() => handlePlayAlbum(album.id, album.name)}
              />
            ))}
          </ResultSection>
        )}

        {songs.length > 0 && (
          <ResultSection
            title={t("sidebar.songs")}
            seeMoreHref={ROUTES.SONGS.SEARCH(query)}
          >
            {songs.map((song) => (
              <MobileResultItem
                key={song.id}
                coverArt={song.coverArt}
                coverArtType="song"
                albumId={song.albumId}
                title={song.title}
                subtitle={song.artist}
                onRowClick={() =>
                  navigateWithFlush(ROUTES.ALBUM.PAGE(song.albumId))
                }
                onPlayClick={() => playSong(song)}
              />
            ))}
          </ResultSection>
        )}

        {artists.length > 0 && (
          <ResultSection title={t("sidebar.artists")}>
            {artists.map((artist) => (
              <MobileResultItem
                key={artist.id}
                coverArt={artist.coverArt}
                coverArtType="artist"
                title={artist.name}
                subtitle={t("artist.info.albumsCount", {
                  count: artist.albumCount,
                })}
                onRowClick={() =>
                  navigateWithFlush(ROUTES.ARTIST.PAGE(artist.id))
                }
                onPlayClick={() => handlePlayArtist(artist)}
              />
            ))}
          </ResultSection>
        )}
      </div>
    </div>
  );
}
