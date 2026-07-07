import type { LyricLine } from "@applemusic-like-lyrics/core";
import type { LyricPlayerRef } from "@applemusic-like-lyrics/react";
import { lazy, Suspense } from "react";
import "@applemusic-like-lyrics/core/style.css";
import { useQuery } from "@tanstack/react-query";
import clsx from "clsx";
import {
  ComponentPropsWithoutRef,
  TouchEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";
import {
  useRemotePlaybackProjection,
  useSmoothRemoteProgress,
} from "@/app/components/remote-control/use-remote-playback-projection";
import {
  ScrollArea,
  scrollAreaViewportSelector,
} from "@/app/components/ui/scroll-area";
import { shouldUseNativePlaybackBackend } from "@/player/playback";
import {
  getCustomLyricsSongKey,
  getSelectedCustomLyrics,
} from "@/service/lyrics";
import { subsonic } from "@/service/subsonic";
import { useIsOnline } from "@/store/cache.store";
import {
  useIsRemoteControlActive,
  useLyricsSettings,
  usePlayerActions,
  usePlayerIsPlaying,
  usePlayerIsScrubbing,
  usePlayerRef,
  usePlayerSonglist,
  usePlayerStore,
} from "@/store/player.store";
import type { IStructuredLyric } from "@/types/responses/song";
import { logger } from "@/utils/logger";
import {
  areLyricsSynced,
  convertLrcToAMLL,
  convertStructuredToAMLL,
  LRC_METADATA_REGEX,
  LRC_TIMESTAMP_REGEX,
} from "@/utils/lrc-converter";
import { queryKeys } from "@/utils/queryKeys";

const LyricPlayer = lazy(() =>
  import("@applemusic-like-lyrics/react").then((m) => ({
    default: m.LyricPlayer,
  })),
);

type ResolvedSynced = {
  type: "synced";
  lyricLines: LyricLine[];
  /** True when lines carry a romaji/romaja track and need the 3-row layout. */
  hasRomaji?: boolean;
};

type ResolvedUnsynced = {
  type: "unsynced";
  lines: string[];
  translationLines?: string[];
};

type ResolvedLyrics = ResolvedSynced | ResolvedUnsynced;

type InternalLyricLineObject = {
  getElement(): HTMLElement;
};

type InternalLyricPlayerHandle = {
  getElement(): HTMLElement;
  resetScroll(): void;
  setIsSeeking(isSeeking: boolean): void;
  alignAnchor?: "top" | "center" | "bottom" | string;
  alignPosition?: number;
  currentLyricLineObjects?: InternalLyricLineObject[];
  lyricLineElementMap?: WeakMap<HTMLElement, InternalLyricLineObject>;
  lyricLinesIndexes?: WeakMap<InternalLyricLineObject, number>;
  size?: [number, number];
  targetAlignIndex?: number;
};

type TouchTapState = {
  moved: boolean;
  startedAt: number;
  target: EventTarget | null;
  x: number;
  y: number;
};

const LYRIC_TAP_MAX_DISTANCE_PX = 10;
const LYRIC_TAP_MAX_DURATION_MS = 250;
const LYRIC_SEEK_DEDUP_MS = 400;
const LYRIC_TOUCH_SCROLL_BLUR_RESET_MS = 500;

function resolveLyricLineIndexFromTarget(
  player: InternalLyricPlayerHandle | undefined,
  target: EventTarget | null,
): number | null {
  if (!(target instanceof Node) || !player) return null;

  const playerElement = player.getElement();
  let currentNode: Node | null = target;

  while (currentNode && currentNode !== playerElement) {
    if (
      currentNode instanceof HTMLElement &&
      currentNode.parentElement === playerElement
    ) {
      const lyricLine = player.lyricLineElementMap?.get(currentNode);
      if (!lyricLine) return null;

      const lineIndex = player.lyricLinesIndexes?.get(lyricLine);
      return typeof lineIndex === "number" ? lineIndex : null;
    }

    currentNode = currentNode.parentNode;
  }

  return null;
}

function getInternalLyricPlayer(
  playerRef: React.RefObject<LyricPlayerRef | null>,
): InternalLyricPlayerHandle | undefined {
  return playerRef.current?.lyricPlayer as
    | InternalLyricPlayerHandle
    | undefined;
}

function cleanUnsyncedLyrics(raw: string): string[] {
  return raw
    .split("\n")
    .filter((line) => !LRC_METADATA_REGEX.test(line))
    .map((line) => line.replace(LRC_TIMESTAMP_REGEX, "").trim())
    .filter((line) => line.length > 0);
}

/**
 * Pick the primary and (optional) translation tracks from
 * structured lyrics. The first entry is the primary; the
 * second entry (if present) is the translation.
 */
function pickStructuredTracks(structured: IStructuredLyric[]): {
  primary: IStructuredLyric;
  translation?: IStructuredLyric;
} {
  const primary = structured[0];
  const translation = structured.length >= 2 ? structured[1] : undefined;
  return { primary, translation };
}

export function LyricsTab() {
  const { currentSong: localCurrentSong } = usePlayerSonglist();
  const remoteProjection = useRemotePlaybackProjection();
  const currentSong = remoteProjection.song ?? localCurrentSong;
  const { t } = useTranslation();
  const {
    showTranslation,
    sourcePriority,
    customServerEnabled,
    customServerUrl,
    selectedCustomLyrics,
  } = useLyricsSettings();
  const { setAreLyricsAligned } = usePlayerActions();

  useEffect(() => {
    return () => {
      setAreLyricsAligned(true);
    };
  }, [setAreLyricsAligned]);

  const {
    id: songId,
    artist,
    title,
    album,
    duration,
    path,
  } = currentSong || {};
  const songDurationMs = duration ? duration * 1000 : undefined;
  const selectedCustomLyricsEntry = currentSong
    ? getSelectedCustomLyrics(
        selectedCustomLyrics,
        getCustomLyricsSongKey({
          artist: currentSong.artist,
          title: currentSong.title,
          album: currentSong.album,
          duration: currentSong.duration,
          path: currentSong.path,
        }),
      )
    : undefined;
  const selectedCustomLyricsKey = selectedCustomLyricsEntry?.key;
  const lyricsDisabled = selectedCustomLyricsEntry?.disabled === true;
  const lyricsOffsetMs = (selectedCustomLyricsEntry?.offset ?? 0) * 1000;
  const isOnline = useIsOnline();
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
    staleTime: 5 * 60 * 1000,
  });

  const { data: structuredLyrics, isLoading: isLoadingStructured } = useQuery({
    queryKey: [...queryKeys.lyrics.structured, songId],
    queryFn: () =>
      songId
        ? subsonic.lyrics.getStructuredLyrics(songId)
        : Promise.resolve([]),
    enabled: !!songId,
    staleTime: 5 * 60 * 1000,
  });

  // Resolve the best lyrics source into a render-ready format.
  // Priority: structured (synced) > structured (unsynced)
  //           > /getLyrics (LRC) > /getLyrics (plain)
  const resolved: ResolvedLyrics | null = useMemo(() => {
    if (!currentSong || lyricsDisabled) return null;
    // Priority 1 & 2: Structured lyrics
    if (structuredLyrics && structuredLyrics.length > 0) {
      const { primary, translation } = pickStructuredTracks(structuredLyrics);

      if (primary.synced) {
        // Priority 1: Structured + synced
        const lyricLines = convertStructuredToAMLL(
          primary,
          translation,
          songDurationMs,
        );
        return {
          type: "synced",
          lyricLines: showTranslation
            ? lyricLines
            : lyricLines.map((l) => ({
                ...l,
                translatedLyric: "",
              })),
        };
      }

      // Priority 2: Structured but unsynced
      const mainLines = primary.line.map((l) => l.value);
      const translationLines = showTranslation
        ? translation?.line.map((l) => l.value)
        : undefined;
      return {
        type: "unsynced",
        lines: mainLines,
        translationLines,
      };
    }

    // Priority 3 & 4: /getLyrics result
    if (lyrics?.value) {
      if (areLyricsSynced(lyrics.value)) {
        // Priority 3: LRC synced (custom servers may attach a romaji track)
        const hasRomaji = !!lyrics.romaji?.trim();
        return {
          type: "synced",
          lyricLines: convertLrcToAMLL(
            lyrics.value,
            songDurationMs,
            lyrics.romaji,
          ),
          hasRomaji,
        };
      }

      // Priority 4: Plain text
      return {
        type: "unsynced",
        lines: cleanUnsyncedLyrics(lyrics.value),
      };
    }

    return null;
  }, [
    structuredLyrics,
    lyrics,
    showTranslation,
    songDurationMs,
    currentSong,
    lyricsDisabled,
  ]);

  const noLyricsFound = t("fullscreen.noLyrics");
  const loadingLyrics = t("fullscreen.loadingLyrics");
  const noSongPlaying = t("player.noSongPlaying");

  if (!currentSong) {
    return <CenteredMessage>{noSongPlaying}</CenteredMessage>;
  }

  if (isLoadingLyrics && isLoadingStructured) {
    return <CenteredMessage>{loadingLyrics}</CenteredMessage>;
  }

  if (!resolved) {
    return <CenteredMessage>{noLyricsFound}</CenteredMessage>;
  }

  if (resolved.type === "synced") {
    return (
      <SyncedLyrics
        lyricLines={resolved.lyricLines}
        offsetMs={lyricsOffsetMs}
        hasRomaji={resolved.hasRomaji}
      />
    );
  }

  return (
    <UnsyncedLyrics
      lines={resolved.lines}
      translationLines={resolved.translationLines}
    />
  );
}

interface SyncedLyricsProps {
  lyricLines: LyricLine[];
  offsetMs: number;
  hasRomaji?: boolean;
}

function SyncedLyrics({ lyricLines, offsetMs, hasRomaji }: SyncedLyricsProps) {
  const playerRef = usePlayerRef();
  const localIsPlaying = usePlayerIsPlaying();
  const isScrubbing = usePlayerIsScrubbing();
  const { setAreLyricsAligned, setProgress } = usePlayerActions();
  const isRemoteControlActive = useIsRemoteControlActive();
  const remoteProjection = useRemotePlaybackProjection();
  const smoothRemoteProgress = useSmoothRemoteProgress({
    active: remoteProjection.active,
    isPlaying: remoteProjection.isPlaying,
    progress: remoteProjection.progress,
    duration: remoteProjection.duration,
  });
  const isPlaying = remoteProjection.active
    ? remoteProjection.isPlaying
    : localIsPlaying;
  const [currentTime, setCurrentTime] = useState(0);
  const currentTimeRef = useRef(0);
  // Keep the latest offset in a ref so the rAF loop reads it without
  // re-subscribing to the animation frame on every offset change.
  const offsetMsRef = useRef(offsetMs);
  offsetMsRef.current = offsetMs;
  const [isTouchScrolling, setIsTouchScrolling] = useState(false);
  const animationFrameRef = useRef<number>();
  const isTouchScrollingRef = useRef(false);
  const lyricPlayerRef = useRef<LyricPlayerRef>(null);
  const seekingTimerRef = useRef<ReturnType<typeof setTimeout>>();
  const touchScrollBlurTimerRef = useRef<ReturnType<typeof setTimeout>>();
  const lastManualSeekRef = useRef<{
    lineIndex: number;
    timestamp: number;
  } | null>(null);
  const touchTapStateRef = useRef<TouchTapState | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const [isSeekingState, setIsSeekingState] = useState(false);
  const isScrubbingRef = useRef(isScrubbing);
  const scrubbingProgressRef = useRef(
    usePlayerStore.getState().playerProgress.scrubbingProgress,
  );
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

  useEffect(() => {
    if (!remoteProjection.active) return;
    lastProgressRef.current = smoothRemoteProgress * 1000;
    lastProgressTimeRef.current = performance.now();
  }, [remoteProjection.active, smoothRemoteProgress]);

  useEffect(() => {
    isScrubbingRef.current = isScrubbing;
  }, [isScrubbing]);

  useEffect(() => {
    return usePlayerStore.subscribe(
      (state) => state.playerProgress.scrubbingProgress,
      (progress) => {
        scrubbingProgressRef.current = progress;
      },
    );
  }, []);

  const clearTouchScrollBlurTimer = useCallback(() => {
    clearTimeout(touchScrollBlurTimerRef.current);
  }, []);

  const setTouchScrolling = useCallback(
    (next: boolean) => {
      isTouchScrollingRef.current = next;
      setIsTouchScrolling((prev) => (prev === next ? prev : next));
      setAreLyricsAligned(!next);
    },
    [setAreLyricsAligned],
  );

  const scheduleTouchScrollBlurRestore = useCallback(() => {
    clearTouchScrollBlurTimer();
    touchScrollBlurTimerRef.current = setTimeout(() => {
      setTouchScrolling(false);
    }, LYRIC_TOUCH_SCROLL_BLUR_RESET_MS);
  }, [clearTouchScrollBlurTimer, setTouchScrolling]);

  const handleWheel = useCallback(() => {
    if (!isTouchScrollingRef.current) {
      setTouchScrolling(true);
    }
    scheduleTouchScrollBlurRestore();
  }, [setTouchScrolling, scheduleTouchScrollBlurRestore]);

  const seekToLyricLine = useCallback(
    (lineIndex: number) => {
      const lyricLine = lyricLines[lineIndex];

      if (!lyricLine || !Number.isFinite(lyricLine.startTime)) {
        return;
      }

      if (!playerRef && !isRemoteControlActive) {
        return;
      }

      const now = Date.now();
      const lastManualSeek = lastManualSeekRef.current;

      if (
        lastManualSeek &&
        lastManualSeek.lineIndex === lineIndex &&
        now - lastManualSeek.timestamp < LYRIC_SEEK_DEDUP_MS
      ) {
        return;
      }

      lastManualSeekRef.current = {
        lineIndex,
        timestamp: now,
      };

      // The lyric line time lives on the (offset-adjusted) lyric timeline;
      // translate it back to the real audio timeline before seeking.
      const seekSeconds = (lyricLine.startTime + offsetMsRef.current) / 1000;
      setProgress(seekSeconds, true);
      if (!isRemoteControlActive && playerRef) {
        playerRef.currentTime = seekSeconds;
        if (isPlaying) {
          playerRef.play().catch((e) => {
            if (e.name !== "AbortError") {
              logger.warn("Lyric seek play failed", e);
            }
          });
        }
      }

      const player = getInternalLyricPlayer(lyricPlayerRef);
      if (player) {
        player.resetScroll();
      }
      setIsSeekingState(true);
      clearTimeout(seekingTimerRef.current);
      seekingTimerRef.current = setTimeout(() => {
        setIsSeekingState(false);
      }, 200);

      setCurrentTime(lyricLine.startTime);
      currentTimeRef.current = lyricLine.startTime;
    },
    [isPlaying, lyricLines, playerRef, isRemoteControlActive, setProgress],
  );

  const handleTouchStart = useCallback(
    (event: TouchEvent<HTMLDivElement>) => {
      clearTouchScrollBlurTimer();

      if (event.touches.length !== 1) {
        touchTapStateRef.current = null;
        return;
      }

      const touch = event.touches[0];
      touchTapStateRef.current = {
        moved: false,
        startedAt: Date.now(),
        target: event.target,
        x: touch.clientX,
        y: touch.clientY,
      };
    },
    [clearTouchScrollBlurTimer],
  );

  const handleTouchMove = useCallback(
    (event: TouchEvent<HTMLDivElement>) => {
      const touchTapState = touchTapStateRef.current;

      if (!touchTapState || event.touches.length !== 1) {
        return;
      }

      const touch = event.touches[0];
      const movedX = Math.abs(touch.clientX - touchTapState.x);
      const movedY = Math.abs(touch.clientY - touchTapState.y);

      if (
        !touchTapState.moved &&
        (movedX > LYRIC_TAP_MAX_DISTANCE_PX ||
          movedY > LYRIC_TAP_MAX_DISTANCE_PX)
      ) {
        touchTapState.moved = true;
        setTouchScrolling(true);
      }
    },
    [setTouchScrolling],
  );

  const handleTouchEnd = useCallback(() => {
    const touchTapState = touchTapStateRef.current;
    touchTapStateRef.current = null;

    if (!touchTapState) return;

    if (touchTapState.moved) {
      scheduleTouchScrollBlurRestore();
      return;
    }

    if (Date.now() - touchTapState.startedAt > LYRIC_TAP_MAX_DURATION_MS) {
      return;
    }

    const player = getInternalLyricPlayer(lyricPlayerRef);
    const lineIndex = resolveLyricLineIndexFromTarget(
      player,
      touchTapState.target,
    );

    if (lineIndex !== null) {
      seekToLyricLine(lineIndex);
    }
  }, [scheduleTouchScrollBlurRestore, seekToLyricLine]);

  const handleTouchCancel = useCallback(() => {
    if (touchTapStateRef.current?.moved || isTouchScrollingRef.current) {
      scheduleTouchScrollBlurRestore();
    }

    touchTapStateRef.current = null;
  }, [scheduleTouchScrollBlurRestore]);

  // Use requestAnimationFrame for smooth time updates
  useEffect(() => {
    const isNative = shouldUseNativePlaybackBackend();
    const useStoreTime = isNative || isRemoteControlActive;
    if (!playerRef && !useStoreTime) return;

    const updateTime = () => {
      if (isScrubbingRef.current) {
        const timeMs = Math.floor(
          scrubbingProgressRef.current * 1000 - offsetMsRef.current,
        );
        if (currentTimeRef.current !== timeMs) {
          currentTimeRef.current = timeMs;
          setCurrentTime(timeMs);
        }
        animationFrameRef.current = requestAnimationFrame(updateTime);
        return;
      }

      let timeMs = 0;
      if (useStoreTime) {
        timeMs = Math.floor(lastProgressRef.current - offsetMsRef.current);
      } else {
        timeMs = Math.floor(
          (playerRef?.currentTime || 0) * 1000 - offsetMsRef.current,
        );
      }

      if (currentTimeRef.current !== timeMs) {
        const delta = timeMs - currentTimeRef.current;
        if (Math.abs(delta) > 500) {
          const player = getInternalLyricPlayer(lyricPlayerRef);
          if (player) {
            player.resetScroll();
          }
          setIsSeekingState(true);
          clearTimeout(seekingTimerRef.current);
          seekingTimerRef.current = setTimeout(() => {
            setIsSeekingState(false);
          }, 200);
        }
        currentTimeRef.current = timeMs;
        setCurrentTime(timeMs);
      }

      animationFrameRef.current = requestAnimationFrame(updateTime);
    };

    animationFrameRef.current = requestAnimationFrame(updateTime);

    return () => {
      if (animationFrameRef.current) {
        cancelAnimationFrame(animationFrameRef.current);
      }
      clearTimeout(seekingTimerRef.current);
      clearTouchScrollBlurTimer();
    };
  }, [clearTouchScrollBlurTimer, playerRef, isRemoteControlActive]);

  return (
    <div
      ref={containerRef}
      className="w-full h-full text-left lrc-box"
      data-vaul-no-drag
      data-romaji={hasRomaji ? "true" : undefined}
      data-seeking={isSeekingState}
      data-scrubbing={isScrubbing}
      onClick={(e) => e.stopPropagation()}
      onWheel={handleWheel}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
      onTouchCancel={handleTouchCancel}
    >
      <Suspense fallback={null}>
        <LyricPlayer
          ref={lyricPlayerRef}
          style={{
            width: "100%",
            height: "100%",
            maxWidth: "100%",
            maxHeight: "100%",
            contain: "paint layout",
            overflow: "hidden",
          }}
          lyricLines={lyricLines}
          currentTime={currentTime}
          alignAnchor="left"
          enableBlur={!isTouchScrolling}
          enableSpring={!isSeekingState && !isScrubbing}
          onLyricLineClick={(line) => {
            if (line.lineIndex !== undefined) {
              seekToLyricLine(line.lineIndex);
            }
          }}
        />
      </Suspense>
    </div>
  );
}

interface UnsyncedLyricsProps {
  lines: string[];
  translationLines?: string[];
}

function UnsyncedLyrics({ lines, translationLines }: UnsyncedLyricsProps) {
  const { currentSong: localCurrentSong } = usePlayerSonglist();
  const remoteProjection = useRemotePlaybackProjection();
  const currentSong = remoteProjection.song ?? localCurrentSong;
  const { setAreLyricsAligned } = usePlayerActions();
  const lyricsBoxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setAreLyricsAligned(true);
  }, [setAreLyricsAligned]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: recomputed when song changes
  useEffect(() => {
    if (lyricsBoxRef.current) {
      const scrollArea = lyricsBoxRef.current.querySelector(
        scrollAreaViewportSelector,
      ) as HTMLDivElement | null;

      scrollArea?.scrollTo({
        top: 0,
        behavior: "smooth",
      });
    }
  }, [currentSong]);

  return (
    <ScrollArea
      type="always"
      className="w-full h-full overflow-y-auto text-left font-semibold text-xl 2xl:text-2xl px-2 scroll-smooth"
      thumbClassName="secondary-thumb-bar"
      ref={lyricsBoxRef}
      data-vaul-no-drag
      onClick={(e) => e.stopPropagation()}
    >
      {lines.map((line, index) => (
        <div
          key={index}
          className={clsx(
            index === 0 && "mt-6",
            index === lines.length - 1 && "mb-10",
          )}
        >
          <p className="leading-10 text-balance">{line}</p>
          {translationLines?.[index] && (
            <p className="leading-8 text-balance text-base 2xl:text-lg opacity-70">
              {translationLines[index]}
            </p>
          )}
        </div>
      ))}
    </ScrollArea>
  );
}

type CenteredMessageProps = ComponentPropsWithoutRef<"p">;

function CenteredMessage({ children }: CenteredMessageProps) {
  const { setAreLyricsAligned } = usePlayerActions();

  useEffect(() => {
    setAreLyricsAligned(true);
  }, [setAreLyricsAligned]);

  return (
    <div
      className="w-full h-full flex justify-center items-center"
      onClick={(e) => e.stopPropagation()}
    >
      <p className="leading-10 text-left font-semibold text-xl 2xl:text-2xl">
        {children}
      </p>
    </div>
  );
}
