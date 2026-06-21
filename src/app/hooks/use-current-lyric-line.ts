import { useQuery } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  getCustomLyricsSongKey,
  getSelectedCustomLyrics,
} from "@/service/lyrics";
import { subsonic } from "@/service/subsonic";
import { useIsOnline } from "@/store/cache.store";
import {
  useIsRemoteControlActive,
  useLyricsSettings,
  usePlayerCurrentSong,
  usePlayerIsPlaying,
  usePlayerRef,
  usePlayerStore,
} from "@/store/player.store";
import type { IStructuredLyric } from "@/types/responses/song";
import {
  areLyricsSynced,
  convertLrcToAMLL,
  convertStructuredToAMLL,
} from "@/utils/lrc-converter";
import { queryKeys } from "@/utils/queryKeys";

const STALE_TIME = 5 * 60 * 1000;

interface SyncedLine {
  startTime: number;
  endTime: number;
  text: string;
}

function extractSyncedLinesFromStructured(
  structured: IStructuredLyric[],
  songDurationMs?: number,
): SyncedLine[] {
  const synced = structured.find((s) => s.synced);
  if (!synced) return [];

  const amlLines = convertStructuredToAMLL(synced, undefined, songDurationMs);
  return amlLines.map((l) => ({
    startTime: l.startTime,
    endTime: l.endTime,
    text: l.words.map((w) => w.word).join(""),
  }));
}

function extractSyncedLinesFromLrc(
  lrc: string,
  songDurationMs?: number,
): SyncedLine[] {
  const lines = convertLrcToAMLL(lrc, songDurationMs);
  return lines.map((line) => ({
    startTime: line.startTime,
    endTime: line.endTime,
    text: line.words.map((w) => w.word).join(""),
  }));
}

function findCurrentLine(
  lines: SyncedLine[],
  currentTimeMs: number,
): string | null {
  let bestLine: SyncedLine | null = null;

  for (const line of lines) {
    if (currentTimeMs >= line.startTime && currentTimeMs < line.endTime) {
      return line.text || null;
    }
    if (line.startTime <= currentTimeMs) {
      bestLine = line;
    }
  }

  // Return the closest previous line when no exact match is found
  // (covers gaps between lyrics, before first line, and after last line)
  return bestLine?.text || lines[0]?.text || null;
}

export function useCurrentLyricLine() {
  const currentSong = usePlayerCurrentSong();
  const playerRef = usePlayerRef();
  const isOnline = useIsOnline();
  const isPlaying = usePlayerIsPlaying();
  const isRemoteControlActive = useIsRemoteControlActive();
  const {
    sourcePriority,
    customServerEnabled,
    customServerUrl,
    selectedCustomLyrics,
  } = useLyricsSettings();

  const {
    id: songId,
    artist,
    title,
    album,
    duration,
    path,
  } = currentSong || {};
  const songDurationMs = duration ? duration * 1000 : undefined;
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

  const { data: lyrics } = useQuery({
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

  const { data: structuredLyrics } = useQuery({
    queryKey: [...queryKeys.lyrics.structured, songId],
    queryFn: () =>
      songId
        ? subsonic.lyrics.getStructuredLyrics(songId)
        : Promise.resolve([]),
    enabled: !!songId,
    staleTime: STALE_TIME,
  });

  const syncedLines = useMemo((): SyncedLine[] => {
    if (!currentSong) return [];

    if (structuredLyrics && structuredLyrics.length > 0) {
      const lines = extractSyncedLinesFromStructured(
        structuredLyrics,
        songDurationMs,
      );
      if (lines.length > 0) return lines;
    }

    if (lyrics?.value && areLyricsSynced(lyrics.value)) {
      return extractSyncedLinesFromLrc(lyrics.value, songDurationMs);
    }

    return [];
  }, [structuredLyrics, lyrics, currentSong, songDurationMs]);

  const [currentLine, setCurrentLine] = useState<string | null>(null);
  const animationFrameRef = useRef<number>();
  const lastLineRef = useRef<string | null>(null);
  const syncedLinesRef = useRef(syncedLines);
  syncedLinesRef.current = syncedLines;

  const lastProgressRef = useRef(0);
  const lastProgressTimeRef = useRef(0);

  useEffect(() => {
    const currentProgress = usePlayerStore.getState().playerProgress.progress;
    lastProgressRef.current = currentProgress * 1000;
    lastProgressTimeRef.current = performance.now();

    return usePlayerStore.subscribe(
      (state) => state.playerProgress.progress,
      (progress) => {
        lastProgressRef.current = progress * 1000;
        lastProgressTimeRef.current = performance.now();
      },
    );
  }, []);

  const tick = useCallback(() => {
    if (!playerRef && !isRemoteControlActive) return;

    const lines = syncedLinesRef.current;
    if (lines.length === 0) {
      if (lastLineRef.current !== null) {
        lastLineRef.current = null;
        setCurrentLine(null);
      }
      return;
    }

    let timeMs = 0;
    if (isRemoteControlActive) {
      if (isPlaying) {
        const elapsed = performance.now() - lastProgressTimeRef.current;
        // Clamp to 500ms so a long gap (tab was hidden, rAF paused, and the
        // progress-store subscription hasn't fired yet) doesn't make lyrics
        // jump far ahead. The store subscription will refresh lastProgressRef
        // shortly after, correcting any small residual error.
        timeMs = Math.floor(
          lastProgressRef.current + Math.min(elapsed, 500),
        );
      } else {
        timeMs = Math.floor(lastProgressRef.current);
      }
    } else {
      timeMs = Math.floor((playerRef?.currentTime || 0) * 1000);
    }

    const line = findCurrentLine(lines, timeMs);
    if (line !== lastLineRef.current) {
      lastLineRef.current = line;
      setCurrentLine(line);
    }

    animationFrameRef.current = requestAnimationFrame(tick);
  }, [playerRef, isPlaying, isRemoteControlActive]);

  useEffect(() => {
    if (!isPlaying || syncedLines.length === 0) {
      if (animationFrameRef.current) {
        cancelAnimationFrame(animationFrameRef.current);
        animationFrameRef.current = undefined;
      }
      return;
    }

    animationFrameRef.current = requestAnimationFrame(tick);
    return () => {
      if (animationFrameRef.current) {
        cancelAnimationFrame(animationFrameRef.current);
      }
    };
  }, [isPlaying, syncedLines.length, tick]);

  // Set initial line position when paused with synced lyrics available
  useEffect(() => {
    if (
      isPlaying ||
      (!playerRef && !isRemoteControlActive) ||
      syncedLines.length === 0
    )
      return;

    const updatePausedLine = () => {
      let timeMs = 0;
      if (isRemoteControlActive) {
        timeMs = Math.floor(
          usePlayerStore.getState().playerProgress.progress * 1000,
        );
      } else {
        timeMs = Math.floor((playerRef?.currentTime || 0) * 1000);
      }
      const line = findCurrentLine(syncedLines, timeMs);
      if (line !== lastLineRef.current) {
        lastLineRef.current = line;
        setCurrentLine(line);
      }
    };

    updatePausedLine();

    if (isRemoteControlActive) {
      return usePlayerStore.subscribe(
        (state) => state.playerProgress.progress,
        () => {
          if (!usePlayerStore.getState().playerState.isPlaying) {
            updatePausedLine();
          }
        },
      );
    }
  }, [isPlaying, playerRef, syncedLines, isRemoteControlActive]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: reset on song change
  useEffect(() => {
    lastLineRef.current = null;
    setCurrentLine(null);
  }, [songId]);

  return { currentLine };
}
