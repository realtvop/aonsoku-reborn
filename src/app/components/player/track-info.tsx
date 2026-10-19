import randomCSSHexColor from "@chriscodesthings/random-css-hex-color";
import { AudioLines, Maximize2 } from "lucide-react";
import {
  type MouseEvent,
  type PointerEvent,
  type ReactNode,
  type TouchEvent,
  useCallback,
  useRef,
} from "react";
import { Fragment } from "react/jsx-runtime";
import { useTranslation } from "react-i18next";
import { Link, type LinkProps } from "react-router-dom";

import { CachedImage } from "@/app/components/cover-image/cached-image";
import FullscreenMode from "@/app/components/fullscreen/page";
import { ScrollingText } from "@/app/components/scrolling-text/scrolling-text";

import { useIsMobile } from "@/app/hooks/use-mobile";
import { cn } from "@/lib/utils";
import { openFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";
import { ROUTES } from "@/routes/routesList";
import { useFullscreenPlayerState, useSongColor } from "@/store/player.store";
import { ISong } from "@/types/responses/song";
import { getAverageColor } from "@/utils/getAverageColor";
import { logger } from "@/utils/logger";
import { ALBUM_ARTISTS_MAX_NUMBER } from "@/utils/multipleArtists";

function handleError(e: React.SyntheticEvent<HTMLImageElement>) {
  e.currentTarget.crossOrigin = null;
}

type TouchGuardedLinkProps = LinkProps & {
  children: ReactNode;
};

function TouchGuardedLink({
  children,
  onClick,
  onPointerCancel,
  onPointerDownCapture,
  onTouchCancel,
  onTouchStartCapture,
  ...props
}: TouchGuardedLinkProps) {
  const wasTouchActivatedRef = useRef(false);

  const handlePointerDownCapture = useCallback(
    (event: PointerEvent<HTMLAnchorElement>) => {
      wasTouchActivatedRef.current = event.pointerType === "touch";
      onPointerDownCapture?.(event);
    },
    [onPointerDownCapture],
  );

  const handleTouchStartCapture = useCallback(
    (event: TouchEvent<HTMLAnchorElement>) => {
      wasTouchActivatedRef.current = true;
      onTouchStartCapture?.(event);
    },
    [onTouchStartCapture],
  );

  const handlePointerCancel = useCallback(
    (event: PointerEvent<HTMLAnchorElement>) => {
      wasTouchActivatedRef.current = false;
      onPointerCancel?.(event);
    },
    [onPointerCancel],
  );

  const handleTouchCancel = useCallback(
    (event: TouchEvent<HTMLAnchorElement>) => {
      wasTouchActivatedRef.current = false;
      onTouchCancel?.(event);
    },
    [onTouchCancel],
  );

  const handleClick = useCallback(
    (event: MouseEvent<HTMLAnchorElement>) => {
      if (wasTouchActivatedRef.current) {
        wasTouchActivatedRef.current = false;
        event.preventDefault();
        return;
      }

      onClick?.(event);
    },
    [onClick],
  );

  return (
    <Link
      {...props}
      onClick={handleClick}
      onPointerCancel={handlePointerCancel}
      onPointerDownCapture={handlePointerDownCapture}
      onTouchCancel={handleTouchCancel}
      onTouchStartCapture={handleTouchStartCapture}
    >
      {children}
    </Link>
  );
}

export function TrackInfo({ song }: { song: ISong | undefined }) {
  const { t } = useTranslation();
  const isMobile = useIsMobile();
  const { setCurrentSongColor } = useSongColor();
  const { fullscreenPlayerOpen } = useFullscreenPlayerState();

  const getImageColor = useCallback(
    async (e: React.SyntheticEvent<HTMLImageElement>) => {
      // e.currentTarget avoids races when the cover art URL swaps.
      const img = e.currentTarget;

      let color = randomCSSHexColor(true);

      try {
        color = (await getAverageColor(img)).hex;
        logger.info("[TrackInfo] - Getting Image Average Color", {
          color,
        });
      } catch {
        logger.error("[TrackInfo] - Unable to get image average color.");
      }

      setCurrentSongColor(color);
    },
    [setCurrentSongColor],
  );

  if (!song) {
    return (
      <Fragment>
        <div className="w-12 h-12 md:w-[70px] md:h-[70px] flex justify-center items-center bg-muted rounded">
          <AudioLines
            data-testid="song-no-playing-icon"
            className="size-5 md:size-6"
          />
        </div>
        <div className="flex flex-col justify-center">
          <span
            className="text-xs md:text-sm font-medium"
            data-testid="song-no-playing-label"
          >
            {t("player.noSongPlaying")}
          </span>
        </div>
      </Fragment>
    );
  }

  return (
    <Fragment>
      <div className="group relative">
        <div className="w-12 h-12 md:w-[70px] md:h-[70px] md:min-w-[70px] md:max-w-[70px] aspect-square bg-cover bg-center bg-skeleton rounded overflow-hidden shadow-md">
          <CachedImage
            key={song.id}
            id="track-song-image"
            coverArtId={song.coverArt}
            coverArtType="song"
            albumId={song.albumId}
            width="100%"
            height="100%"
            crossOrigin="anonymous"
            className="aspect-square object-cover w-full h-full cursor-pointer bg-skeleton text-transparent"
            data-testid="track-image"
            alt={`${song.artist} - ${song.title}`}
            onLoad={getImageColor}
            onError={handleError}
          />
        </div>
        <FullscreenMode
          open={fullscreenPlayerOpen}
          onOpenChange={(open) => {
            if (open) openFullscreenPlayerWithHistory("playing");
          }}
        >
          <div
            className="hidden md:flex absolute inset-0 items-center justify-center bg-black/0 group-hover-supported:bg-black/40 cursor-pointer rounded"
            tabIndex={-1}
            data-testid="track-fullscreen-button"
          >
            <Maximize2 className="w-5 h-5 text-white opacity-0 group-hover-supported:opacity-100" />
          </div>
        </FullscreenMode>
      </div>
      <div className="flex flex-col justify-center w-full overflow-hidden ml-1">
        <ScrollingText loop={2} pauseOnHover>
          {isMobile ? (
            <span
              className="text-xs md:text-sm font-medium"
              data-testid="track-title"
            >
              {song.title}
            </span>
          ) : (
            <TouchGuardedLink
              to={ROUTES.ALBUM.PAGE(song.albumId)}
              tabIndex={-1}
            >
              <span
                className={cn(
                  "text-xs md:text-sm font-medium",
                  "hover-supported:underline cursor-pointer",
                )}
                data-testid="track-title"
              >
                {song.title}
              </span>
            </TouchGuardedLink>
          )}
        </ScrollingText>
        <TrackInfoArtistsLinks disableNavigation={isMobile} song={song} />
      </div>
    </Fragment>
  );
}

type TrackInfoArtistsLinksProps = {
  song: ISong;
  disableNavigation?: boolean;
};

function TrackInfoArtistsLinks({
  song,
  disableNavigation = false,
}: TrackInfoArtistsLinksProps) {
  const { artists, artistId, artist } = song;

  if (artists && artists.length > 1) {
    const reducedArtists = artists.slice(0, ALBUM_ARTISTS_MAX_NUMBER);

    return (
      <div className="flex items-center gap-1 text-[10px] md:text-xs text-muted-foreground w-full maskImage-marquee-fade-finished">
        {reducedArtists.map(({ id, name }, index) => (
          <div key={id} className="flex items-center">
            <ArtistLink
              disableNavigation={disableNavigation}
              id={id}
              name={name}
            />
            {index < reducedArtists.length - 1 && ","}
          </div>
        ))}
      </div>
    );
  }

  return (
    <ArtistLink
      disableNavigation={disableNavigation}
      id={artistId}
      name={artist}
    />
  );
}

type ArtistLinkProps = {
  id?: string;
  name: string;
  disableNavigation?: boolean;
};

function ArtistLink({ id, name, disableNavigation = false }: ArtistLinkProps) {
  if (disableNavigation || !id) {
    return (
      <span
        className="w-fit inline-flex text-[10px] md:text-xs text-muted-foreground text-nowrap"
        data-testid="track-artist-url"
      >
        {name}
      </span>
    );
  }

  return (
    <TouchGuardedLink
      to={ROUTES.ARTIST.PAGE(id)}
      className="w-fit inline-flex"
      data-testid="track-artist-url"
    >
      <span
        className={cn(
          "text-[10px] md:text-xs text-muted-foreground text-nowrap",
          "hover-supported:underline hover-supported:text-foreground cursor-pointer",
        )}
      >
        {name}
      </span>
    </TouchGuardedLink>
  );
}
