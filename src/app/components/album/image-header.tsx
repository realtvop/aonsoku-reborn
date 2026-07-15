import randomCSSHexColor from "@chriscodesthings/random-css-hex-color";
import clsx from "clsx";
import { type ReactNode, type SyntheticEvent, useState } from "react";
import { getCoverArtUrl } from "@/api/httpClient";
import {
  CachedImage,
  useCachedCoverUrl,
} from "@/app/components/cover-image/cached-image";
import { AlbumHeaderFallback } from "@/app/components/fallbacks/album-fallbacks";
import { BadgesData, HeaderInfoGenerator } from "@/app/components/header-info";
import { CustomLightBox } from "@/app/components/lightbox";
import { cn } from "@/lib/utils";
import { CoverArt } from "@/types/coverArtType";
import { IFeaturedArtist } from "@/types/responses/artist";
import { getAverageColor } from "@/utils/getAverageColor";
import { getTextSizeClass } from "@/utils/getTextSizeClass";
import { AlbumArtistInfo, AlbumMultipleArtistsInfo } from "./artists";
import { ImageHeaderEffect } from "./header-effect";
import { IMAGE_HEADER_MAIN_GRADIENT } from "./image-header-gradients";

interface HeaderSubtitleSectionProps {
  showSimpleSubtitle: boolean;
  artists?: IFeaturedArtist[];
  subtitle?: string;
  artistId?: string;
  badges: BadgesData;
  className?: string;
}

function HeaderSubtitleSection({
  showSimpleSubtitle,
  artists,
  subtitle,
  artistId,
  badges,
  className,
}: HeaderSubtitleSectionProps) {
  const hasMultipleArtists = artists ? artists.length > 1 : false;

  return (
    <div className={className}>
      {!showSimpleSubtitle && artists && hasMultipleArtists && (
        <div className="flex flex-wrap items-center justify-center md:justify-start mt-1 md:mt-2">
          <AlbumMultipleArtistsInfo artists={artists} />
          <HeaderInfoGenerator badges={badges} />
        </div>
      )}

      {!showSimpleSubtitle && subtitle && !hasMultipleArtists && (
        <>
          {artistId ? (
            <div className="flex flex-wrap items-center justify-center md:justify-start mt-1 md:mt-2">
              <AlbumArtistInfo id={artistId} name={subtitle} />
              <HeaderInfoGenerator badges={badges} />
            </div>
          ) : (
            <p className="opacity-80 text-xs md:text-sm font-medium">
              {subtitle}
            </p>
          )}
        </>
      )}

      {showSimpleSubtitle && subtitle && (
        <>
          <p className="text-xs md:text-sm opacity-80 drop-shadow line-clamp-2 mt-1 mb-1 md:mb-2">
            {subtitle}
          </p>
          <HeaderInfoGenerator badges={badges} showFirstDot={false} />
        </>
      )}

      {!subtitle && (
        <div className="mt-1">
          <HeaderInfoGenerator badges={badges} showFirstDot={false} />
        </div>
      )}
    </div>
  );
}

interface ImageHeaderProps {
  type: string;
  title: string;
  subtitle?: string;
  artistId?: string;
  artists?: IFeaturedArtist[];
  coverArtId?: string;
  coverArtType: CoverArt;
  coverArtSize?: string;
  coverArtAlt: string;
  badges: BadgesData;
  secondaryBadges?: BadgesData;
  isPlaylist?: boolean;
  showSimpleSubtitle?: boolean;
  customIcon?: ReactNode;
  onColorExtracted?: (color: string) => void;
}

export default function ImageHeader({
  type,
  title,
  subtitle,
  artistId,
  artists,
  coverArtId,
  coverArtType,
  coverArtSize = "300",
  coverArtAlt,
  badges,
  secondaryBadges,
  isPlaylist = false,
  showSimpleSubtitle,
  customIcon,
  onColorExtracted,
}: ImageHeaderProps) {
  const simpleSubtitle = showSimpleSubtitle ?? isPlaylist;

  const [loaded, setLoaded] = useState(!!customIcon);
  const [open, setOpen] = useState(false);
  const [bgColor, setBgColor] = useState(customIcon ? "var(--background)" : "");

  const lightboxFallback = !customIcon
    ? getCoverArtUrl(coverArtId, coverArtType, "700")
    : "";
  const cachedLightboxUrl = useCachedCoverUrl(
    customIcon ? undefined : coverArtId,
    coverArtType,
    undefined,
    lightboxFallback,
    "700",
  );
  const lightboxSrc = !customIcon ? cachedLightboxUrl : "";

  async function handleLoadImage(event: SyntheticEvent<HTMLImageElement>) {
    const img = event.currentTarget;
    setLoaded(true);

    let color = randomCSSHexColor(true);

    try {
      color = (await getAverageColor(img)).hex;
    } catch (_) {
      console.warn(
        "handleLoadImage: unable to get image color. Using a random color.",
      );
    }

    if (!img.isConnected) return;

    setBgColor(color);
    onColorExtracted?.(color);
  }

  function handleError(event: SyntheticEvent<HTMLImageElement>) {
    event.currentTarget.crossOrigin = null;

    setLoaded(true);
  }

  const hasMultipleArtists = artists ? artists.length > 1 : false;
  const showArtistAboveCover = !!(
    !simpleSubtitle &&
    (hasMultipleArtists || (subtitle && artistId))
  );
  const showMobileSubtitle = !showArtistAboveCover && !!subtitle;
  const allBadges: BadgesData = secondaryBadges
    ? [...badges, ...secondaryBadges]
    : badges;
  const hasSecondaryBadges =
    secondaryBadges && secondaryBadges.some((b) => b.content);

  return (
    <div className="flex flex-col relative w-full" key={`header-${coverArtId}`}>
      <div className="relative w-full h-auto md:h-[calc(3rem+200px)] 2xl:h-[calc(3rem+250px)]">
        {!loaded && (
          <div
            className="absolute inset-0 z-20"
            data-testid="image-header-fallback"
          >
            <AlbumHeaderFallback
              showArtistAboveCover={showArtistAboveCover}
              showMobileSubtitle={showMobileSubtitle}
              showSecondaryBadges={!!hasSecondaryBadges}
            />
          </div>
        )}
        <div
          className={cn(
            "w-full pb-3 md:py-6 flex gap-2 md:gap-4 relative md:absolute md:inset-0",
            IMAGE_HEADER_MAIN_GRADIENT,
            "flex-col",
            "pt-album-header px-album-header",
            !loaded && "bg-background-foreground",
          )}
          style={loaded ? { backgroundColor: bgColor } : undefined}
        >
          {showArtistAboveCover && (
            <div className="md:hidden flex justify-center">
              {hasMultipleArtists && artists ? (
                <AlbumMultipleArtistsInfo artists={artists} />
              ) : subtitle && artistId ? (
                <AlbumArtistInfo id={artistId} name={subtitle} />
              ) : null}
            </div>
          )}

          <div className="flex flex-col items-center md:flex-row md:items-center w-full gap-3 md:gap-6 lg:gap-8">
            <div
              className={cn(
                "w-[168px] h-[168px] min-w-[168px] min-h-[168px] sm:w-[200px] sm:h-[200px] sm:min-w-[200px] sm:min-h-[200px]",
                "2xl:w-[250px] 2xl:h-[250px] 2xl:min-w-[250px] 2xl:min-h-[250px]",
                "bg-skeleton aspect-square bg-cover bg-center rounded",
                "shadow-header-image overflow-hidden",
                !customIcon &&
                  "hover-supported:scale-[1.02] ease-linear duration-100",
              )}
            >
              {customIcon ? (
                <div className="flex items-center justify-center w-full h-full text-foreground/80">
                  {customIcon}
                </div>
              ) : (
                <CachedImage
                  key={coverArtId}
                  effect="opacity"
                  crossOrigin="anonymous"
                  coverArtId={coverArtId}
                  coverArtType={coverArtType}
                  coverArtSize={coverArtSize}
                  alt={coverArtAlt}
                  className="aspect-square object-cover w-full h-full cursor-pointer"
                  width="100%"
                  height="100%"
                  onLoad={handleLoadImage}
                  onError={handleError}
                  onFallback={() => setLoaded(true)}
                  onClick={() => setOpen(true)}
                />
              )}
            </div>

            <div className="flex w-full items-center flex-col md:items-start md:max-w-[calc(100%-216px)] 2xl:max-w-[calc(100%-266px)] md:justify-end z-10">
              <p className="text-[10px] md:text-xs 2xl:text-sm font-medium drop-shadow">
                {type}
              </p>
              <h1
                id="detail-page-title"
                className={clsx(
                  "max-w-full scroll-m-20 font-bold tracking-tight antialiased drop-shadow-md break-words text-center md:text-left",
                  "line-clamp-3 md:line-clamp-2 text-xl leading-tight md:text-[2em] md:leading-none mb-2",
                  getTextSizeClass(title),
                )}
              >
                {title}
              </h1>

              <HeaderSubtitleSection
                showSimpleSubtitle={simpleSubtitle}
                artists={artists}
                subtitle={subtitle}
                artistId={artistId}
                badges={allBadges}
                className="hidden md:flex"
              />
            </div>
          </div>

          <div className="md:hidden flex flex-col items-center">
            {!simpleSubtitle && subtitle && !showArtistAboveCover && (
              <p className="opacity-80 text-xs font-medium mb-1">{subtitle}</p>
            )}

            {simpleSubtitle && subtitle && (
              <p className="text-xs opacity-80 drop-shadow line-clamp-2 mt-1 mb-1">
                {subtitle}
              </p>
            )}

            <HeaderInfoGenerator badges={badges} showFirstDot={false} />

            {hasSecondaryBadges && (
              <HeaderInfoGenerator
                badges={secondaryBadges}
                showFirstDot={false}
              />
            )}
          </div>
        </div>

        {!loaded ? (
          <ImageHeaderEffect className="bg-background-foreground" />
        ) : (
          <ImageHeaderEffect style={{ backgroundColor: bgColor }} />
        )}
      </div>

      {!customIcon && (
        <CustomLightBox
          open={open}
          close={setOpen}
          src={lightboxSrc}
          alt={coverArtAlt}
        />
      )}
    </div>
  );
}
