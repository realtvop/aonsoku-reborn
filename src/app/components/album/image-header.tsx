import randomCSSHexColor from "@chriscodesthings/random-css-hex-color";
import clsx from "clsx";
import { useState } from "react";
import { LazyLoadImage } from "react-lazy-load-image-component";

import { getCoverArtUrl } from "@/api/httpClient";
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

interface HeaderSubtitleSectionProps {
  isPlaylist: boolean;
  artists?: IFeaturedArtist[];
  subtitle?: string;
  artistId?: string;
  badges: BadgesData;
  className?: string;
}

function HeaderSubtitleSection({
  isPlaylist,
  artists,
  subtitle,
  artistId,
  badges,
  className,
}: HeaderSubtitleSectionProps) {
  const hasMultipleArtists = artists ? artists.length > 1 : false;

  return (
    <div className={className}>
      {!isPlaylist && artists && hasMultipleArtists && (
        <div className="flex items-center mt-1 sm:mt-2">
          <AlbumMultipleArtistsInfo artists={artists} />
          <HeaderInfoGenerator badges={badges} />
        </div>
      )}

      {!isPlaylist && subtitle && !hasMultipleArtists && (
        <>
          {artistId ? (
            <div className="flex items-center mt-1 sm:mt-2">
              <AlbumArtistInfo id={artistId} name={subtitle} />
              <HeaderInfoGenerator badges={badges} />
            </div>
          ) : (
            <p className="opacity-80 text-xs sm:text-sm font-medium">
              {subtitle}
            </p>
          )}
        </>
      )}

      {isPlaylist && subtitle && (
        <>
          <p className="text-xs sm:text-sm opacity-80 drop-shadow line-clamp-2 mt-1 mb-1 sm:mb-2">
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
  coverArtSize: string;
  coverArtAlt: string;
  badges: BadgesData;
  isPlaylist?: boolean;
}

export default function ImageHeader({
  type,
  title,
  subtitle,
  artistId,
  artists,
  coverArtId,
  coverArtType,
  coverArtSize,
  coverArtAlt,
  badges,
  isPlaylist = false,
}: ImageHeaderProps) {
  const [loaded, setLoaded] = useState(false);
  const [open, setOpen] = useState(false);
  const [bgColor, setBgColor] = useState("");

  function getImage() {
    return document.getElementById("cover-art-image") as HTMLImageElement;
  }

  async function handleLoadImage() {
    const img = getImage();
    if (!img) return;

    let color = randomCSSHexColor(true);

    try {
      color = (await getAverageColor(img)).hex;
    } catch (_) {
      console.warn(
        "handleLoadImage: unable to get image color. Using a random color."
      );
    }

    setBgColor(color);
    setLoaded(true);
  }

  function handleError() {
    const img = getImage();
    if (!img) return;

    img.crossOrigin = null;

    setLoaded(true);
  }

  return (
    <div className="flex flex-col relative w-full" key={`header-${coverArtId}`}>
      <div className="relative w-full h-[calc(3rem+130px)] sm:h-[calc(3rem+160px)] md:h-[calc(3rem+200px)] 2xl:h-[calc(3rem+250px)]">
        {!loaded && (
          <div className="absolute inset-0 z-20">
            <AlbumHeaderFallback />
          </div>
        )}
        <div
          className={cn(
            "w-full px-3 py-3 sm:px-4 sm:py-4 md:px-8 md:py-6 flex gap-2 sm:gap-3 md:gap-4 absolute inset-0",
            "bg-gradient-to-b from-background/20 to-background/50",
            "flex-col"
          )}
          style={{ backgroundColor: bgColor }}
        >
          <div className="flex flex-row sm:flex-nowrap items-end sm:items-center w-full gap-3 sm:gap-4 md:gap-6 lg:gap-8">
            <div
              className={cn(
                "w-[120px] h-[120px] min-w-[120px] min-h-[120px]",
                "sm:w-[160px] sm:h-[160px] sm:min-w-[160px] sm:min-h-[160px]",
                "md:w-[200px] md:h-[200px] md:min-w-[200px] md:min-h-[200px]",
                "2xl:w-[250px] 2xl:h-[250px] 2xl:min-w-[250px] 2xl:min-h-[250px]",
                "bg-skeleton aspect-square bg-cover bg-center rounded",
                "shadow-header-image overflow-hidden",
                "hover:scale-[1.02] ease-linear duration-100"
              )}
            >
              <LazyLoadImage
                key={coverArtId}
                effect="opacity"
                crossOrigin="anonymous"
                id="cover-art-image"
                src={getCoverArtUrl(coverArtId, coverArtType, coverArtSize)}
                alt={coverArtAlt}
                className="aspect-square object-cover w-full h-full cursor-pointer"
                width="100%"
                height="100%"
                onLoad={handleLoadImage}
                onError={handleError}
                onClick={() => setOpen(true)}
              />
            </div>

            <div className="flex w-full max-w-[calc(100%-128px)] sm:max-w-[calc(100%-172px)] md:max-w-[calc(100%-216px)] 2xl:max-w-[calc(100%-266px)] flex-col justify-end z-10">
              <p className="text-[10px] sm:text-xs 2xl:text-sm font-medium drop-shadow">
                {type}
              </p>
              <h1
                className={clsx(
                  "max-w-full scroll-m-20 font-bold tracking-tight antialiased drop-shadow-md break-words",
                  "line-clamp-5 sm:line-clamp-2 text-xl leading-none sm:text-[2em] mb-2",
                  getTextSizeClass(title)
                )}
              >
                {title}
              </h1>

              <HeaderSubtitleSection
                isPlaylist={isPlaylist}
                artists={artists}
                subtitle={subtitle}
                artistId={artistId}
                badges={badges}
                className="hidden sm:flex"
              />
            </div>
          </div>

          <div className="sm:hidden bg-transparent">
            <HeaderSubtitleSection
              isPlaylist={isPlaylist}
              artists={artists}
              subtitle={subtitle}
              artistId={artistId}
              badges={badges}
            />
          </div>
        </div>

        {!loaded ? (
          <ImageHeaderEffect className="bg-muted-foreground" />
        ) : (
          <ImageHeaderEffect style={{ backgroundColor: bgColor }} />
        )}
      </div>

      <CustomLightBox
        open={open}
        close={setOpen}
        src={getCoverArtUrl(coverArtId, coverArtType, coverArtSize)}
        alt={coverArtAlt}
      />
    </div>
  );
}
