import { clsx } from "clsx";
import { AnimatePresence, motion } from "framer-motion";
import { memo } from "react";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { usePlayerStore } from "@/store/player.store";
import { ISong } from "@/types/responses/song";
import { ALBUM_ARTISTS_MAX_NUMBER } from "@/utils/multipleArtists";
import { ScrollingTitle } from "./scrolling-title";
import { CompactSongArtwork } from "./song-artwork";

const TEXT_TRANSITION = { duration: 0.25, ease: [0.4, 0, 0.2, 1] } as const;
const TEXT_TRANSITION_DELAYED = {
  duration: 0.25,
  ease: [0.4, 0, 0.2, 1],
  delay: 0.05,
} as const;

export const SongInfo = memo(function SongInfo() {
  const currentSong = usePlayerStore(
    (state) => state.songlist.currentSong,
    (a, b) => a?.id === b?.id,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;

  if (!displaySong?.id) return null;

  return (
    <div className="flex w-full min-w-0 flex-col gap-1">
      <AnimatePresence mode="wait">
        <motion.div
          key={displaySong.id ?? "no-song"}
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8 }}
          transition={TEXT_TRANSITION}
          className="w-full min-w-0 overflow-hidden"
        >
          <ScrollingTitle>
            <h2 className="font-bold tracking-tight text-2xl md:text-3xl">
              {displaySong.title}
            </h2>
          </ScrollingTitle>
        </motion.div>
      </AnimatePresence>
      <AnimatePresence mode="wait">
        <motion.div
          key={displaySong.id ?? "no-song-sub"}
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -8 }}
          transition={TEXT_TRANSITION_DELAYED}
          className="w-full min-w-0 overflow-hidden"
        >
          <ScrollingTitle>
            <div className="text-sm text-foreground/70">
              <ArtistNames song={displaySong} />
            </div>
          </ScrollingTitle>
        </motion.div>
      </AnimatePresence>
    </div>
  );
});

export const AlbumName = memo(function AlbumName({
  className,
}: {
  className?: string;
}) {
  const currentSong = usePlayerStore(
    (state) => state.songlist.currentSong,
    (a, b) => a?.id === b?.id,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;

  if (!displaySong?.id) return null;

  return (
    <AnimatePresence mode="wait">
      <motion.div
        key={displaySong.id ?? "no-album"}
        initial={{ opacity: 0, y: -8 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: 8 }}
        transition={TEXT_TRANSITION}
        className={clsx(
          "w-full min-w-0 overflow-hidden text-center",
          className,
        )}
      >
        <ScrollingTitle>
          <p className="text-sm text-foreground/70">{displaySong.album}</p>
        </ScrollingTitle>
      </motion.div>
    </AnimatePresence>
  );
});

export const CompactSongInfo = memo(function CompactSongInfo() {
  const currentSong = usePlayerStore(
    (state) => state.songlist.currentSong,
    (a, b) => a?.id === b?.id,
  );
  const remoteProjection = useRemotePlaybackProjection();
  const displaySong = remoteProjection.song ?? currentSong;

  if (!displaySong?.id) return null;

  return (
    <div className="flex items-center gap-2 min-w-0 flex-1">
      <CompactSongArtwork />
      <div className="flex flex-col min-w-0">
        <p className="text-sm font-medium truncate">{displaySong.title}</p>
        <p className="text-xs text-foreground/70 truncate">
          {displaySong.artist}
        </p>
      </div>
    </div>
  );
});

const ArtistNames = memo(
  function ArtistNames({ song }: { song: ISong }) {
    const { artist, artists } = song;

    if (artists && artists.length > 1) {
      const data = artists.slice(0, ALBUM_ARTISTS_MAX_NUMBER);
      return <p>{data.map(({ name }) => name).join(", ")}</p>;
    }

    return <p>{artist}</p>;
  },
  (prev, next) => prev.song.id === next.song.id,
);
