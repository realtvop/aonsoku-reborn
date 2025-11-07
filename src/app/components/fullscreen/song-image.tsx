import { useMemo } from "react";
import { LazyLoadImage } from "react-lazy-load-image-component";
import { getCoverArtUrl } from "@/api/httpClient";
import { AspectRatio } from "@/app/components/ui/aspect-ratio";
import { usePlayerStore } from "@/store/player.store";

export function FullscreenSongImage() {
  const { coverArt, artist, title } = usePlayerStore(({ songlist }) => {
    return songlist.currentSong;
  });
  const imageUrl = useMemo(() => {
    return getCoverArtUrl(coverArt, "song", "800");
  }, [coverArt]);

  return (
    <div className="w-full sm:w-auto sm:2xl:w-[33%] h-auto sm:h-full max-w-[240px] max-h-[240px] sm:max-w-[450px] sm:max-h-[450px] 2xl:max-w-[550px] 2xl:max-h-[550px] items-end flex aspect-square mx-auto sm:mx-0">
      <AspectRatio
        ratio={1 / 1}
        className="rounded-lg 2xl:rounded-2xl overflow-hidden bg-accent"
      >
        <LazyLoadImage
          src={imageUrl}
          effect="opacity"
          alt={`${artist} - ${title}`}
          className="aspect-square object-cover shadow-custom-5"
          width="100%"
          height="100%"
        />
      </AspectRatio>
    </div>
  );
}
