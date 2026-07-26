import { AnimatePresence, motion } from "framer-motion";
import { memo } from "react";
import { CachedImage } from "@/app/components/cover-image/cached-image";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { usePlayerStore } from "@/store/player.store";

export const FullscreenSongArtwork = memo(function FullscreenSongArtwork({
  showTouchDragSurface = false,
}: {
  showTouchDragSurface?: boolean;
}) {
  const { albumId, coverArt, artist, title, id } = usePlayerStore(
    ({ songlist }) => songlist.currentSong,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song;
  const displayAlbumId = displaySong?.albumId ?? albumId;
  const displayCoverArt = displaySong?.coverArt ?? coverArt;
  const displayArtist = displaySong?.artist ?? artist;
  const displayTitle = displaySong?.title ?? title;
  const displayId = displaySong?.id ?? id;

  return (
    <div className="relative flex size-full items-center justify-center overflow-hidden rounded-md bg-foreground/5">
      {showTouchDragSurface && (
        <div
          className="absolute inset-0 z-10 touch-none"
          data-testid="fullscreen-artwork-touch-drag-surface"
          aria-hidden="true"
        />
      )}
      <AnimatePresence mode="wait">
        <motion.div
          key={displayId ?? "no-song"}
          initial={{ opacity: 0, scale: 0.92 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 1.05 }}
          transition={{ duration: 0.3, ease: [0.4, 0, 0.2, 1] }}
          className="relative flex size-full items-center justify-center"
        >
          <CachedImage
            coverArtId={displayCoverArt}
            coverArtType="song"
            albumId={displayAlbumId}
            coverArtSize="700"
            effect="opacity"
            alt={`${displayArtist} - ${displayTitle}`}
            className="size-full object-contain rounded-md"
            wrapperClassName="size-full block overflow-hidden"
            width="100%"
            height="100%"
          />
        </motion.div>
      </AnimatePresence>
    </div>
  );
});

export const CompactSongArtwork = memo(function CompactSongArtwork() {
  const { albumId, coverArt, artist, title } = usePlayerStore(
    ({ songlist }) => songlist.currentSong,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song;

  return (
    <CachedImage
      coverArtId={displaySong?.coverArt ?? coverArt}
      coverArtType="song"
      albumId={displaySong?.albumId ?? albumId}
      coverArtSize="100"
      effect="opacity"
      alt={`${displaySong?.artist ?? artist} - ${displaySong?.title ?? title}`}
      className="size-11 rounded object-cover"
      width="44"
      height="44"
    />
  );
});
