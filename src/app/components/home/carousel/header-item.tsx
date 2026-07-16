import clsx from "clsx";
import { Play } from "lucide-react";
import { isFirefox } from "react-device-detect";
import { Link } from "react-router-dom";
import { getCoverArtUrl } from "@/api/httpClient";
import {
  CachedImage,
  useCachedCoverUrl,
} from "@/app/components/cover-image/cached-image";
import { Badge } from "@/app/components/ui/badge";
import { Button } from "@/app/components/ui/button";
import { useIsMobile } from "@/app/hooks/use-mobile";
import { ROUTES } from "@/routes/routesList";
import { subsonic } from "@/service/subsonic";
import { usePlayerActions } from "@/store/player.store";
import { Albums } from "@/types/responses/album";
import { convertSecondsToTime } from "@/utils/convertSecondsToTime";

export function HeaderItem({ album }: { album: Albums }) {
  const isMobile = useIsMobile();
  const { setSongList } = usePlayerActions();
  const coverArtFallback = getCoverArtUrl(album.coverArt, "album", "300");
  const coverArtUrl = useCachedCoverUrl(
    album.coverArt,
    "album",
    album.id,
    coverArtFallback,
  );
  const backgroundImageStyle = coverArtUrl ? `url(${coverArtUrl})` : undefined;

  async function handlePlayAlbum(album: Albums) {
    const response = await subsonic.albums.getOne(album.id);

    if (response?.song && response.song.length > 0) {
      setSongList(
        response.song,
        0,
        false,
        {
          albumId: album.id,
        },
        album.name,
      );
    }
  }

  const innerContent = (
    <>
      <div
        data-testid="header-bg"
        className="absolute -inset-10 bg-cover bg-center z-0 bg-skeleton"
        style={{
          backgroundImage: backgroundImageStyle,
          filter: isFirefox ? "blur(24px)" : undefined,
        }}
      />
      <div
        className={clsx(
          "absolute -inset-10 bg-gradient-to-b from-background/40 to-background/80 z-10",
          !isFirefox && "backdrop-blur-xl",
        )}
      />
      <div className="absolute inset-0 z-20 w-full h-full">
        <div className="flex h-full p-4 2xl:p-6 gap-4">
          <div
            className="h-full aspect-square relative group bg-skeleton rounded-lg"
            data-testid="header-image-container"
          >
            <CachedImage
              coverArtId={album.coverArt}
              coverArtType="album"
              albumId={album.id}
              alt={album.name}
              effect="opacity"
              width="100%"
              height="100%"
              className="aspect-square rounded-lg object-cover bg-center absolute inset-0 z-0"
              data-testid="header-image"
            />
            <div className="hidden sm:flex w-full h-full items-center justify-center rounded-lg bg-black bg-opacity-0 group-hover-supported:bg-opacity-50 absolute inset-0 z-10">
              <Button
                className="opacity-0 group-hover-supported:opacity-100 rounded-full w-14 h-14"
                variant="outline"
                onClick={() => handlePlayAlbum(album)}
                data-testid="header-play-button"
              >
                <Play className="fill-foreground" />
              </Button>
            </div>
          </div>
          <div className="flex flex-1 h-full flex-col justify-end">
            {isMobile ? (
              <h1
                data-testid="header-title"
                className="w-full scroll-m-20 text-xl sm:text-3xl 2xl:text-4xl font-bold tracking-tight mb-0 2xl:mb-1 line-clamp-2"
              >
                {album.name}
              </h1>
            ) : (
              <Link
                to={ROUTES.ALBUM.PAGE(album.id)}
                className="w-fit max-w-full"
              >
                <h1
                  data-testid="header-title"
                  className="w-full scroll-m-20 text-xl sm:text-3xl 2xl:text-4xl font-bold tracking-tight mb-0 2xl:mb-1 hover-supported:underline line-clamp-2"
                >
                  {album.name}
                </h1>
              </Link>
            )}
            {!album.artistId ? (
              <h4
                data-testid="header-artist"
                className="scroll-m-20 text-base sm:text-lg 2xl:text-xl font-semibold tracking-tight opacity-70 line-clamp-1"
              >
                {album.artist}
              </h4>
            ) : isMobile ? (
              <h4
                data-testid="header-artist"
                className="scroll-m-20 text-base sm:text-lg 2xl:text-xl font-semibold tracking-tight opacity-70 line-clamp-1"
              >
                {album.artist}
              </h4>
            ) : (
              <Link
                to={ROUTES.ARTIST.PAGE(album.artistId)}
                className="w-fit max-w-full"
              >
                <h4
                  data-testid="header-artist"
                  className="scroll-m-20 text-base sm:text-lg 2xl:text-xl font-semibold tracking-tight opacity-70 hover-supported:underline line-clamp-1"
                >
                  {album.artist}
                </h4>
              </Link>
            )}
            <div className="hidden sm:flex gap-2 mt-1 2xl:mt-2">
              {album.genre !== undefined && (
                <Link to={ROUTES.ALBUMS.GENRE(album.genre)} className="flex">
                  <Badge
                    variant="neutral"
                    className="border"
                    data-testid="header-genre"
                  >
                    {album.genre}
                  </Badge>
                </Link>
              )}
              {album.year && (
                <Badge
                  variant="neutral"
                  className="border"
                  data-testid="header-year"
                >
                  {album.year}
                </Badge>
              )}
              <Badge
                variant="neutral"
                className="border"
                data-testid="header-duration"
              >
                {convertSecondsToTime(album.duration)}
              </Badge>
            </div>
          </div>
        </div>
      </div>
    </>
  );

  if (isMobile) {
    return (
      <Link
        to={ROUTES.ALBUM.PAGE(album.id)}
        className={clsx(
          "w-full h-[140px] sm:h-[250px] 2xl:h-[300px] relative block overflow-hidden",
          isFirefox && "bg-black/60",
        )}
      >
        {innerContent}
      </Link>
    );
  }

  return (
    <div
      className={clsx(
        "w-full h-[140px] sm:h-[250px] 2xl:h-[300px] relative overflow-hidden",
        isFirefox && "bg-black/60",
      )}
    >
      {innerContent}
    </div>
  );
}
