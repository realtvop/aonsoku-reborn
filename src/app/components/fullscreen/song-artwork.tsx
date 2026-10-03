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
  const currentSong = usePlayerStore(({ songlist }) => songlist.currentSong);
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;

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
          key={displaySong?.id ?? "no-song"}
          initial={{ opacity: 0, scale: 0.92 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 1.05 }}
          transition={{ duration: 0.3, ease: [0.4, 0, 0.2, 1] }}
          className="relative flex size-full items-center justify-center"
        >
          <CachedImage
            coverArtId={displaySong?.coverArt}
            coverArtType="song"
            albumId={displaySong?.albumId}
            coverArtSize="700"
            effect="opacity"
            alt={`${displaySong?.artist ?? ""} - ${displaySong?.title ?? ""}`}
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
  const currentSong = usePlayerStore(({ songlist }) => songlist.currentSong);
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;

  return (
    <CachedImage
      coverArtId={displaySong?.coverArt}
      coverArtType="song"
      albumId={displaySong?.albumId}
      coverArtSize="100"
      effect="opacity"
      alt={`${displaySong?.artist ?? ""} - ${displaySong?.title ?? ""}`}
      className="size-11 rounded object-cover"
      width="44"
      height="44"
    />
  );
});
