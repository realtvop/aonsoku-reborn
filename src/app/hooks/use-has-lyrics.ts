import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import {
  getCustomLyricsSongKey,
  getSelectedCustomLyrics,
} from "@/service/lyrics";
import { subsonic } from "@/service/subsonic";
import { useIsOnline } from "@/store/cache.store";
import { useLyricsSettings, usePlayerSonglist } from "@/store/player.store";
import { areLyricsSynced } from "@/utils/lrc-converter";
import { queryKeys } from "@/utils/queryKeys";

const STALE_TIME = 5 * 60 * 1000;

export function useHasLyrics() {
  const { currentSong: localCurrentSong } = usePlayerSonglist();
  const remoteProjection = useRemotePlaybackProjection();
  const currentSong = remoteProjection.song ?? localCurrentSong;
  const {
    sourcePriority,
    customServerEnabled,
    customServerUrl,
    selectedCustomLyrics,
  } = useLyricsSettings();

  const isOnline = useIsOnline();

  const {
    id: songId,
    artist,
    title,
    album,
    duration,
    path,
  } = currentSong || {};
  const selectedCustomLyricsKey = currentSong
    ? getSelectedCustomLyrics(
        selectedCustomLyrics,
        getCustomLyricsSongKey({
          artist: currentSong.artist,
          title: currentSong.title,
          album: currentSong.album,
          duration: currentSong.duration,
          path: currentSong.path,
        }),
      )?.key
    : undefined;
  const lyricsSettingsKey = [
    sourcePriority.join(","),
    customServerEnabled,
    customServerUrl,
    selectedCustomLyricsKey,
  ];

  const { data: lyrics, isLoading: isLoadingLyrics } = useQuery({
    queryKey: [
      ...queryKeys.lyrics.plain,
      artist,
      title,
      album,
      duration,
      path,
      ...lyricsSettingsKey,
    ],
    queryFn: () =>
      artist && title
        ? subsonic.lyrics.getLyrics({ artist, title, album, duration, path })
        : Promise.resolve(null),
    enabled: isOnline && !!artist && !!title,
    staleTime: STALE_TIME,
  });

  const { data: structuredLyrics, isLoading: isLoadingStructured } = useQuery({
    queryKey: [...queryKeys.lyrics.structured, songId],
    queryFn: () =>
      songId
        ? subsonic.lyrics.getStructuredLyrics(songId)
        : Promise.resolve([]),
    enabled: !!songId,
    staleTime: STALE_TIME,
  });

  const hasLyrics = useMemo(() => {
    if (!currentSong) return false;
    if (isLoadingLyrics || isLoadingStructured) return undefined;

    if (structuredLyrics && structuredLyrics.length > 0) return true;
    if (lyrics?.value) {
      if (areLyricsSynced(lyrics.value)) return true;
      const plainLines = lyrics.value
        .split("\n")
        .filter((l) => l.trim().length > 0);
      return plainLines.length > 0;
    }

    return false;
  }, [
    structuredLyrics,
    lyrics,
    isLoadingLyrics,
    isLoadingStructured,
    currentSong,
  ]);

  return { hasLyrics };
}
