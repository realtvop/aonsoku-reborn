import type { DragEndEvent, DragStartEvent } from "@dnd-kit/core";
import { closestCenter, DndContext, DragOverlay } from "@dnd-kit/core";
import {
  SortableContext,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { LucideIcon } from "lucide-react";
import { Repeat, Shuffle } from "lucide-react";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";
import { useTranslation } from "react-i18next";
import RepeatOne from "@/app/components/icons/repeat-one";
import { useQueueDndSensors } from "@/app/components/queue/dnd-sensors";
import {
  QueueItemRow,
  SortableQueueItem,
} from "@/app/components/queue/queue-item-row";
import { QueueSourceLabel } from "@/app/components/queue/queue-source-label";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { Button } from "@/app/components/ui/button";
import {
  ScrollArea,
  scrollAreaViewportSelector,
} from "@/app/components/ui/scroll-area";
import { useHaptic } from "@/app/hooks/use-haptic";
import { useIsMobile } from "@/app/hooks/use-mobile";
import { useScrollEndListener } from "@/app/hooks/use-scroll-end-listener";
import { cn } from "@/lib/utils";
import {
  useContextQueue,
  useHasQueueSongs,
  usePlayerActions,
  usePlayerCurrentSong,
  usePlayerCurrentSongIndex,
  usePlayerLoop,
  usePlayerShuffle,
  useUserQueue,
} from "@/store/player.store";
import {
  usePlayHistory,
  usePlayHistoryActions,
} from "@/store/playHistory.store";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import { FULLSCREEN_QUEUE_BG_CLASS } from "./constants";
import { QueueCurrentSong, QueueModeButtons } from "./queue-current-song";

function syncQueueCurrentSongPosition({
  container,
  el,
  spacer,
  behavior,
}: {
  container: HTMLDivElement;
  el: HTMLDivElement;
  spacer: HTMLDivElement;
  behavior?: ScrollBehavior;
}) {
  if (container.clientHeight === 0) return;

  const distance = Math.abs(
    el.getBoundingClientRect().top - container.getBoundingClientRect().top,
  );
  const resolvedBehavior: ScrollBehavior =
    behavior ??
    (distance > container.clientHeight * 0.5 ? "instant" : "smooth");

  const currentTop =
    el.getBoundingClientRect().top -
    container.getBoundingClientRect().top +
    container.scrollTop;

  spacer.style.height = "0px";

  let contentBelowTop = 0;
  let foundCurrent = false;
  for (const child of container.children) {
    if (child === el) foundCurrent = true;
    if (foundCurrent) {
      const styled = child as HTMLElement;
      if (styled.offsetParent === null) continue;
      const computed = getComputedStyle(styled);
      if (computed.position === "fixed") continue;
      contentBelowTop += styled.offsetHeight;
    }
  }

  const scrollPad = Math.max(0, container.clientHeight - contentBelowTop);
  spacer.style.height = `${scrollPad}px`;

  if (resolvedBehavior === "instant") {
    container.scrollTop = currentTop;
  } else {
    container.scrollTo({ top: currentTop, behavior: "smooth" });
  }
}

interface FullscreenSongQueueProps {
  hideModeButtons?: boolean;
  hideHistory?: boolean;
  hideCurrentSong?: boolean;
  hideCurrentSongContent?: boolean;
  hideRepeatIndicator?: boolean;
  useVirtualization?: boolean;
  scrollAreaClassName?: string;
  thumbClassName?: string;
  onCurrentSongClick?: () => void;
}

export const FullscreenSongQueue = memo(function FullscreenSongQueue({
  hideModeButtons = false,
  hideHistory = false,
  hideCurrentSong = false,
  hideCurrentSongContent = false,
  hideRepeatIndicator = false,
  useVirtualization = false,
  scrollAreaClassName,
  thumbClassName,
  onCurrentSongClick,
}: FullscreenSongQueueProps) {
  const isMobile = useIsMobile();
  const hasSongs = useHasQueueSongs();
  const currentSongIndex = usePlayerCurrentSongIndex();
  const localCurrentSong = usePlayerCurrentSong();
  const localContextQueue = useContextQueue();
  const localUserQueue = useUserQueue();
  const remoteProjection = useRemotePlaybackProjection();
  const isRemoteQueue = remoteProjection.active;
  const currentSong = isRemoteQueue
    ? remoteProjection.song
    : localCurrentSong;
  const contextSongs = isRemoteQueue
    ? remoteProjection.contextSongs
    : localContextQueue.contextSongs;
  const contextIndex = isRemoteQueue
    ? remoteProjection.contextIndex
    : localContextQueue.contextIndex;
  const userQueueSongs = isRemoteQueue
    ? remoteProjection.userQueueSongs
    : localUserQueue.userQueueSongs;
  const clearUserQueue = localUserQueue.clearUserQueue;
  const { t } = useTranslation();
  const playHistory = usePlayHistory();
  const filteredHistory = useMemo(() => {
    if (hideHistory) return [];
    if (
      playHistory.length > 0 &&
      currentSong &&
      playHistory[0].id === currentSong.id
    ) {
      return playHistory.slice(1);
    }
    return playHistory;
  }, [playHistory, currentSong, hideHistory]);

  const { clearHistory: clearPlayHistory } = usePlayHistoryActions();

  const { trigger: hapticTrigger } = useHaptic();
  const snapHaptic = hapticTrigger ? () => hapticTrigger("heavy") : undefined;

  const upcomingContext = useMemo(
    () => contextSongs.slice(contextIndex + 1),
    [contextSongs, contextIndex],
  );

  if (
    !isRemoteQueue &&
    !hasSongs &&
    filteredHistory.length === 0 &&
    userQueueSongs.length === 0
  ) {
    return (
      <div className="flex justify-center items-center h-full">
        <span className="text-foreground/70">{t("fullscreen.emptyQueue")}</span>
      </div>
    );
  }

  return (
    <UnifiedQueueView
      playHistory={filteredHistory}
      userQueueSongs={userQueueSongs}
      upcomingContext={upcomingContext}
      currentSong={currentSong}
      currentSongIndex={currentSongIndex}
      contextIndex={contextIndex}
      contextSongs={contextSongs}
      hideModeButtons={hideModeButtons}
      hideHistory={hideHistory}
      hideCurrentSong={hideCurrentSong}
      hideCurrentSongContent={hideCurrentSongContent}
      hideRepeatIndicator={hideRepeatIndicator}
      useVirtualization={useVirtualization}
      scrollAreaClassName={scrollAreaClassName}
      thumbClassName={thumbClassName}
      clearPlayHistory={clearPlayHistory}
      clearUserQueue={clearUserQueue}
      isRemoteQueue={isRemoteQueue}
      remoteSourceName={remoteProjection.sourceName}
      onCurrentSongClick={onCurrentSongClick}
      isMobile={isMobile}
      snapHaptic={snapHaptic}
    />
  );
});

function UnifiedQueueView({
  playHistory,
  userQueueSongs,
  upcomingContext,
  currentSong,
  currentSongIndex,
  contextIndex,
  contextSongs,
  hideModeButtons,
  hideHistory,
  hideCurrentSong,
  hideCurrentSongContent,
  hideRepeatIndicator,
  useVirtualization,
  scrollAreaClassName,
  thumbClassName,
  clearPlayHistory,
  clearUserQueue,
  isRemoteQueue,
  remoteSourceName,
  onCurrentSongClick,
  isMobile,
  snapHaptic,
}: {
  playHistory: ISong[];
  userQueueSongs: ISong[];
  upcomingContext: ISong[];
  currentSong: ISong | null;
  currentSongIndex: number;
  contextIndex: number;
  contextSongs: ISong[];
  hideModeButtons: boolean;
  hideHistory: boolean;
  hideCurrentSong: boolean;
  hideCurrentSongContent: boolean;
  hideRepeatIndicator: boolean;
  useVirtualization: boolean;
  scrollAreaClassName?: string;
  thumbClassName?: string;
  clearPlayHistory: () => void;
  clearUserQueue: () => void;
  isRemoteQueue: boolean;
  remoteSourceName: string | null;
  onCurrentSongClick?: () => void;
  isMobile: boolean;
  snapHaptic?: () => void;
}) {
  const { t } = useTranslation();
  const { playFromQueue, playFromUserQueue, setNextOnQueue, reorderQueue } =
    usePlayerActions();
  const loopState = usePlayerLoop();
  const isShuffleActive = usePlayerShuffle();
  const remoteProjection = useRemotePlaybackProjection();
  const effectiveLoopState = isRemoteQueue
    ? remoteProjection.loopState
    : loopState;
  const effectiveShuffleActive = isRemoteQueue
    ? remoteProjection.isShuffleActive
    : isShuffleActive;
  const [activeItem, setActiveItem] = useState<ISong | null>(null);

  const playHistorySong = useCallback(
    (song: ISong) => {
      setNextOnQueue([song]);
      playFromUserQueue(0);
    },
    [setNextOnQueue, playFromUserQueue],
  );

  const queueItemProps = {
    hideDownload: true as const,
    hideDuration: isMobile,
    hideDropdownButton: isMobile,
    isMobile,
  };

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const currentSongRef = useRef<HTMLDivElement>(null);
  const spacerRef = useRef<HTMLDivElement>(null);
  const [dragOverlayBg, setDragOverlayBg] = useState<string>("");

  const sensors = useQueueDndSensors();
  const queueScrollKey = `${currentSong?.id}:${currentSongIndex}:${contextSongs.length + userQueueSongs.length}:${effectiveLoopState}`;

  const userSortableItems = useMemo(
    () =>
      userQueueSongs
        .filter((song) => song.id !== currentSong?.id)
        .map((song) => song.id),
    [userQueueSongs, currentSong],
  );

  const upcomingSortableItems = useMemo(
    () => upcomingContext.map((song) => song.id),
    [upcomingContext],
  );

  useLayoutEffect(() => {
    if (useVirtualization) return;
    if (!queueScrollKey) return;
    const el = currentSongRef.current;
    const container = scrollContainerRef.current;
    const spacer = spacerRef.current;
    if (!el || !container || !spacer) return;
    syncQueueCurrentSongPosition({ container, el, spacer });
  }, [queueScrollKey, useVirtualization]);

  useEffect(() => {
    if (useVirtualization) return;
    let rafId = 0;
    const observer = new ResizeObserver(() => {
      cancelAnimationFrame(rafId);
      rafId = requestAnimationFrame(() => {
        const el = currentSongRef.current;
        const container = scrollContainerRef.current;
        const spacer = spacerRef.current;
        if (!el || !container || !spacer) return;
        syncQueueCurrentSongPosition({
          container,
          el,
          spacer,
          behavior: "instant",
        });
      });
    });
    const container = scrollContainerRef.current;
    if (!container) return;
    observer.observe(container);
    return () => {
      cancelAnimationFrame(rafId);
      observer.disconnect();
    };
  }, [useVirtualization]);

  useScrollEndListener(() =>
    useVirtualization ? null : scrollContainerRef.current, () => {
    const container = scrollContainerRef.current;
    const el = currentSongRef.current;
    const spacer = spacerRef.current;
    if (!el || !container || !spacer) return;
    if (container.scrollTop <= 1) return;
    const containerRect = container.getBoundingClientRect();
    const historySection = container.querySelector<HTMLElement>(
      "[data-history-section]",
    );
    let visibleHistoryCount = 0;
    if (historySection) {
      const sectionRect = historySection.getBoundingClientRect();
      const visibleTop = Math.max(sectionRect.top, containerRect.top);
      const visibleBottom = Math.min(sectionRect.bottom, containerRect.bottom);
      const visibleHeight = Math.max(0, visibleBottom - visibleTop);
      const headerHeight = 32;
      const itemHeight = 64;
      const itemsVisibleHeight = visibleHeight - headerHeight;
      if (itemsVisibleHeight > 0) {
        visibleHistoryCount = Math.ceil(itemsVisibleHeight / itemHeight);
      }
    }
    if (visibleHistoryCount >= 1 && visibleHistoryCount <= 3) {
      syncQueueCurrentSongPosition({
        container,
        el,
        spacer,
        behavior: "smooth",
      });
      snapHaptic?.();
    }
  }, [useVirtualization, snapHaptic]);

  const contextPlayedCount = contextIndex + 1;
  const userQueueStart = contextPlayedCount;

  function handleUserDragStart(event: DragStartEvent) {
    const song = userQueueSongs.find((s) => s.id === event.active.id);
    setActiveItem(song ?? null);
    const el = scrollContainerRef.current;
    if (el) {
      const beforeBg = getComputedStyle(el, "::before").backgroundColor;
      setDragOverlayBg(beforeBg !== "transparent" ? beforeBg : "");
    }
  }

  function handleUserDragEnd(event: DragEndEvent) {
    setActiveItem(null);
    setDragOverlayBg("");
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const fromLocal = userQueueSongs.findIndex((s) => s.id === active.id);
    const toLocal = userQueueSongs.findIndex((s) => s.id === over.id);
    if (fromLocal === -1 || toLocal === -1) return;
    const fromGlobal = userQueueStart + fromLocal;
    const toGlobal = userQueueStart + toLocal;
    if (!isRemoteQueue) {
      reorderQueue(fromGlobal, toGlobal);
    }
  }

  function handleUpcomingDragStart(event: DragStartEvent) {
    const song = upcomingContext.find((s) => s.id === event.active.id);
    setActiveItem(song ?? null);
    const el = scrollContainerRef.current;
    if (el) {
      const beforeBg = getComputedStyle(el, "::before").backgroundColor;
      setDragOverlayBg(beforeBg !== "transparent" ? beforeBg : "");
    }
  }

  function handleUpcomingDragEnd(event: DragEndEvent) {
    setActiveItem(null);
    setDragOverlayBg("");
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const fromLocal = upcomingContext.findIndex((s) => s.id === active.id);
    const toLocal = upcomingContext.findIndex((s) => s.id === over.id);
    if (fromLocal === -1 || toLocal === -1) return;
    const fromGlobal = contextPlayedCount + userQueueSongs.length + fromLocal;
    const toGlobal = contextPlayedCount + userQueueSongs.length + toLocal;
    if (!isRemoteQueue) {
      reorderQueue(fromGlobal, toGlobal);
    }
  }

  const playUserQueueSong = useCallback(
    (userQueueIndex: number) => {
      if (isRemoteQueue) {
        playFromQueue(
          [...contextSongs, ...userQueueSongs],
          contextSongs.length + userQueueIndex,
        );
        return;
      }
      playFromUserQueue(userQueueIndex);
    },
    [
      contextSongs,
      isRemoteQueue,
      playFromQueue,
      playFromUserQueue,
      userQueueSongs,
    ],
  );

  const isRepeatOne = effectiveLoopState === LoopState.One;
  const isRepeatAll = effectiveLoopState === LoopState.All;
  const hasNoUpcoming =
    upcomingContext.length === 0 && userQueueSongs.length === 0;

  if (useVirtualization) {
    return (
      <VirtualizedQueueView
        playHistory={playHistory}
        userQueueSongs={userQueueSongs}
        upcomingContext={upcomingContext}
        currentSong={currentSong}
        contextSongs={contextSongs}
        contextIndex={contextIndex}
        contextPlayedCount={contextPlayedCount}
        hideModeButtons={hideModeButtons}
        hideHistory={hideHistory}
        hideCurrentSong={hideCurrentSong}
        hideCurrentSongContent={hideCurrentSongContent}
        hideRepeatIndicator={hideRepeatIndicator}
        isRepeatOne={isRepeatOne}
        isRepeatAll={isRepeatAll}
        isShuffleActive={effectiveShuffleActive}
        hasNoUpcoming={hasNoUpcoming}
        sourceName={remoteSourceName}
        scrollAreaClassName={scrollAreaClassName}
        thumbClassName={thumbClassName}
        sensors={sensors}
        userSortableItems={userSortableItems}
        upcomingSortableItems={upcomingSortableItems}
        activeItem={activeItem}
        dragOverlayBg={dragOverlayBg}
        onUserDragStart={handleUserDragStart}
        onUserDragEnd={handleUserDragEnd}
        onUpcomingDragStart={handleUpcomingDragStart}
        onUpcomingDragEnd={handleUpcomingDragEnd}
        playHistorySong={playHistorySong}
        playFromQueue={playFromQueue}
        playFromUserQueue={playUserQueueSong}
        clearPlayHistory={clearPlayHistory}
        clearUserQueue={clearUserQueue}
        onCurrentSongClick={onCurrentSongClick}
        t={t}
        queueItemProps={queueItemProps}
        snapHaptic={snapHaptic}
      />
    );
  }

  return (
    <div
      className={cn(
        "flex flex-col h-full overflow-hidden",
        FULLSCREEN_QUEUE_BG_CLASS,
      )}
    >
      <div
        className="flex-1 overflow-y-auto no-scrollbar px-2"
        data-vaul-no-drag
        ref={scrollContainerRef}
      >
        {playHistory.length > 0 && (
          <div data-history-section>
            <div
              className={cn(
                FULLSCREEN_QUEUE_BG_CLASS,
                "sticky top-0 z-10 flex items-center justify-between px-2 py-1",
              )}
            >
              <h3 className="text-xs font-semibold text-foreground/70 uppercase tracking-wider">
                {t("fullscreen.queueHistory")}
              </h3>
              <Button
                variant="ghost"
                size="sm"
                className="h-6 px-2 text-xs text-foreground/50 hover-supported:text-foreground"
                onClick={clearPlayHistory}
              >
                {t("generic.clear")}
              </Button>
            </div>
            {playHistory.map((song, idx) => {
              const displayIdx = playHistory.length - 1 - idx;
              const displaySong = playHistory[displayIdx];
              const isCurrent = currentSong?.id === displaySong.id;
              return (
                <QueueItemRow
                  key={`${displaySong.id}-${displayIdx}`}
                  song={displaySong}
                  isActive={isCurrent}
                  onPlay={() => playHistorySong(displaySong)}
                  tier="context"
                  {...queueItemProps}
                />
              );
            })}
          </div>
        )}

        {!hideCurrentSong && (
          <div
            ref={currentSongRef}
            className={cn(
              "shrink-0",
              hideCurrentSongContent ? "h-0 overflow-hidden" : "pt-2 pb-1",
            )}
            aria-hidden={hideCurrentSongContent || undefined}
          >
            {!hideCurrentSongContent && (
              <QueueCurrentSong onClick={onCurrentSongClick} />
            )}
          </div>
        )}

        {!hideModeButtons && (
          <div className="pt-1 pb-1">
            <QueueModeButtons />
          </div>
        )}

        {userQueueSongs.length > 0 && (
          <div>
            <UserQueueSection
              userQueueSongs={userQueueSongs}
              userSortableItems={userSortableItems}
              currentSong={currentSong}
              sensors={sensors}
              onDragStart={handleUserDragStart}
              onDragEnd={handleUserDragEnd}
              clearUserQueue={clearUserQueue}
              activeItem={activeItem}
              dragOverlayBg={dragOverlayBg}
              onPlaySong={playUserQueueSong}
              t={t}
              sticky
              queueItemProps={queueItemProps}
            />
          </div>
        )}

        {hasNoUpcoming && !isRepeatAll ? (
          <div>
            <div className="flex items-center justify-center py-4">
              <span className="text-foreground/50 text-xs">
                {t("fullscreen.emptyQueue")}
              </span>
            </div>
            {isRepeatOne && !hideRepeatIndicator && (
              <RepeatIndicator
                icon={RepeatOne}
                label={t("fullscreen.queueRepeating")}
              />
            )}
            {isShuffleActive && !hideRepeatIndicator && (
              <RepeatIndicator
                icon={Shuffle}
                label={t("fullscreen.queueShuffling")}
              />
            )}
          </div>
        ) : (
          <div>
            <div
              className={cn(
                FULLSCREEN_QUEUE_BG_CLASS,
                "sticky top-0 z-10 pt-1 pb-1",
              )}
            >
              <div className="flex items-center justify-between px-2 pt-1">
                <h3 className="text-xs font-semibold text-foreground/70 uppercase tracking-wider">
                  {t("fullscreen.queueContinue")}
                </h3>
              </div>
              <QueueSourceLabel sourceName={remoteSourceName} />
            </div>

            <DndContext
              sensors={sensors}
              collisionDetection={closestCenter}
              onDragStart={handleUpcomingDragStart}
              onDragEnd={handleUpcomingDragEnd}
            >
              <SortableContext
                items={upcomingSortableItems}
                strategy={verticalListSortingStrategy}
              >
                {upcomingContext.length > 0 &&
                  upcomingContext.map((song, idx) => {
                    const contextIdx = contextIndex + 1 + idx;
                    return (
                      <SortableQueueItem
                        key={song.id}
                        id={song.id}
                        song={song}
                        isActive={false}
                        onPlay={() => playFromQueue(contextSongs, contextIdx)}
                        tier="context"
                        {...queueItemProps}
                      />
                    );
                  })}
              </SortableContext>
              {createPortal(
                <DragOverlay>
                  {activeItem && (
                    <div
                      className="rounded-md shadow-lg"
                      style={{ background: dragOverlayBg || undefined }}
                    >
                      <QueueItemRow
                        song={activeItem}
                        isActive={currentSong?.id === activeItem.id}
                        onPlay={() => {}}
                        {...queueItemProps}
                      />
                    </div>
                  )}
                </DragOverlay>,
                document.body,
              )}
            </DndContext>

            {(isRepeatOne || isRepeatAll) && !hideRepeatIndicator && (
              <RepeatIndicator
                icon={isRepeatOne ? RepeatOne : Repeat}
                label={t("fullscreen.queueRepeating")}
              />
            )}
            {isShuffleActive && !hideRepeatIndicator && (
              <RepeatIndicator
                icon={Shuffle}
                label={t("fullscreen.queueShuffling")}
              />
            )}
          </div>
        )}
        <div ref={spacerRef} className="shrink-0" aria-hidden="true" />
      </div>
    </div>
  );
}

function VirtualizedQueueView({
  playHistory,
  userQueueSongs,
  upcomingContext,
  currentSong,
  contextSongs,
  contextIndex,
  contextPlayedCount,
  hideModeButtons,
  hideHistory,
  hideCurrentSong,
  hideCurrentSongContent,
  hideRepeatIndicator,
  isRepeatOne,
  isRepeatAll,
  isShuffleActive,
  hasNoUpcoming,
  sourceName,
  scrollAreaClassName,
  thumbClassName,
  sensors,
  userSortableItems,
  upcomingSortableItems,
  activeItem,
  dragOverlayBg,
  onUserDragStart,
  onUserDragEnd,
  onUpcomingDragStart,
  onUpcomingDragEnd,
  playHistorySong,
  playFromQueue,
  playFromUserQueue,
  clearPlayHistory,
  clearUserQueue,
  onCurrentSongClick,
  t,
  queueItemProps,
  snapHaptic,
}: {
  playHistory: ISong[];
  userQueueSongs: ISong[];
  upcomingContext: ISong[];
  currentSong: ISong | null;
  contextSongs: ISong[];
  contextIndex: number;
  contextPlayedCount: number;
  hideModeButtons: boolean;
  hideHistory: boolean;
  hideCurrentSong: boolean;
  hideCurrentSongContent: boolean;
  hideRepeatIndicator: boolean;
  isRepeatOne: boolean;
  isRepeatAll: boolean;
  isShuffleActive: boolean;
  hasNoUpcoming: boolean;
  sourceName: string | null;
  scrollAreaClassName?: string;
  thumbClassName?: string;
  sensors: ReturnType<typeof useQueueDndSensors>;
  userSortableItems: string[];
  upcomingSortableItems: string[];
  activeItem: ISong | null;
  dragOverlayBg: string;
  onUserDragStart: (e: DragStartEvent) => void;
  onUserDragEnd: (e: DragEndEvent) => void;
  onUpcomingDragStart: (e: DragStartEvent) => void;
  onUpcomingDragEnd: (e: DragEndEvent) => void;
  playHistorySong: (song: ISong) => void;
  playFromQueue: (songs: ISong[], index: number) => void;
  playFromUserQueue: (index: number) => void;
  clearPlayHistory: () => void;
  clearUserQueue: () => void;
  onCurrentSongClick?: () => void;
  t: (key: string) => string;
  queueItemProps: {
    hideDownload: boolean;
    hideDuration: boolean;
    hideDropdownButton: boolean;
    isMobile: boolean;
  };
  snapHaptic?: () => void;
}) {
  const parentRef = useRef<HTMLDivElement>(null);
  const prevSongIdRef = useRef<string | null>(null);

  const getScrollElement = useCallback(() => {
    if (!parentRef.current) return null;
    return parentRef.current.querySelector(scrollAreaViewportSelector);
  }, []);

  type VirtualItem =
    | { type: "history"; song: ISong; key: string }
    | { type: "currentSong" }
    | { type: "modeButtons" }
    | { type: "queueHeader" }
    | { type: "userQueueSong"; song: ISong; userQueueIndex: number }
    | { type: "queueDivider" }
    | { type: "continueHeader" }
    | { type: "emptyQueueMessage" }
    | { type: "upcomingSong"; song: ISong; contextIdx: number }
    | { type: "repeatIndicator"; icon: LucideIcon; label: string };

  const virtualItems = useMemo(() => {
    const items: VirtualItem[] = [];

    if (!hideHistory) {
      for (let i = playHistory.length - 1; i >= 0; i--) {
        items.push({
          type: "history",
          song: playHistory[i],
          key: `history-${playHistory[i].id}-${i}`,
        });
      }
    }

    if (!hideCurrentSong) {
      items.push({ type: "currentSong" });
    }

    if (!hideModeButtons) {
      items.push({ type: "modeButtons" });
    }

    const filteredUserQueueSongs = userQueueSongs.filter(
      (song) => song.id !== currentSong?.id,
    );

    if (filteredUserQueueSongs.length > 0) {
      items.push({ type: "queueHeader" });
      for (const song of filteredUserQueueSongs) {
        const userQueueIndex = userQueueSongs.findIndex(
          (s) => s.id === song.id,
        );
        items.push({
          type: "userQueueSong",
          song,
          userQueueIndex,
        });
      }
    }

    if (filteredUserQueueSongs.length > 0 && upcomingContext.length > 0) {
      items.push({ type: "queueDivider" });
    }

    if (hasNoUpcoming && !isRepeatAll) {
      items.push({ type: "emptyQueueMessage" });
    } else {
      items.push({ type: "continueHeader" });
    }

    for (let idx = 0; idx < upcomingContext.length; idx++) {
      const song = upcomingContext[idx];
      const contextIdx = contextIndex + 1 + idx;
      items.push({ type: "upcomingSong", song, contextIdx });
    }

    if (!hideRepeatIndicator) {
      if (isRepeatOne) {
        items.push({
          type: "repeatIndicator",
          icon: RepeatOne,
          label: t("fullscreen.queueRepeating"),
        });
      } else if (isRepeatAll) {
        items.push({
          type: "repeatIndicator",
          icon: Repeat,
          label: t("fullscreen.queueRepeating"),
        });
      }
      if (isShuffleActive) {
        items.push({
          type: "repeatIndicator",
          icon: Shuffle,
          label: t("fullscreen.queueShuffling"),
        });
      }
    }

    return items;
  }, [
    hideHistory,
    hideCurrentSong,
    hideModeButtons,
    hideRepeatIndicator,
    playHistory,
    userQueueSongs,
    upcomingContext,
    currentSong,
    contextIndex,
    hasNoUpcoming,
    isRepeatOne,
    isRepeatAll,
    isShuffleActive,
    t,
  ]);

  const virtualizer = useVirtualizer({
    count: virtualItems.length,
    getScrollElement,
    estimateSize: (index) => {
      const item = virtualItems[index];
      if (!item) return 64;
      switch (item.type) {
        case "history":
        case "userQueueSong":
        case "upcomingSong":
          return 64;
        case "currentSong":
          return hideCurrentSongContent ? 1 : 56;
        case "modeButtons":
          return 40;
        case "queueHeader":
          return 36;
        case "queueDivider":
          return 20;
        case "continueHeader":
          return 52;
        case "emptyQueueMessage":
          return 48;
        case "repeatIndicator":
          return 36;
        default:
          return 64;
      }
    },
    overscan: 5,
  });

  const currentSongVirtualIndex = useMemo(() => {
    const idx = virtualItems.findIndex((item) => item.type === "currentSong");
    return idx >= 0 ? idx : -1;
  }, [virtualItems]);

  useEffect(() => {
    if (currentSong?.id && currentSong?.id !== prevSongIdRef.current) {
      prevSongIdRef.current = currentSong.id;
      if (currentSongVirtualIndex >= 0) {
        virtualizer.scrollToIndex(currentSongVirtualIndex, { align: "center" });
      }
    }
  }, [currentSong?.id, currentSongVirtualIndex, virtualizer]);

  useScrollEndListener(getScrollElement, () => {
    const scrollEl = getScrollElement();
    if (!scrollEl) return;
    if (scrollEl.scrollTop <= 1) return;
    const containerHeight = scrollEl.clientHeight;
    const scrollTop = scrollEl.scrollTop;
    const visibleVirtualItems = virtualizer.getVirtualItems();
    let visibleHistoryCount = 0;
    for (const vItem of visibleVirtualItems) {
      const item = virtualItems[vItem.index];
      if (item?.type === "history") {
        const itemTop = vItem.start;
        const itemBottom = vItem.start + vItem.size;
        if (itemTop < scrollTop + containerHeight && itemBottom > scrollTop) {
          visibleHistoryCount++;
        }
      }
    }
    if (visibleHistoryCount >= 1 && visibleHistoryCount <= 3) {
      if (currentSongVirtualIndex >= 0) {
        virtualizer.scrollToIndex(currentSongVirtualIndex, {
          align: "start",
          behavior: "smooth",
        });
        snapHaptic?.();
      }
    }
  }, [
    currentSongVirtualIndex,
    virtualizer,
    getScrollElement,
    snapHaptic,
    virtualItems,
  ]);

  if (virtualItems.length === 0) {
    return (
      <div className="flex flex-1 flex-col h-full min-w-0 items-center justify-center">
        <span className="text-foreground/70">{t("fullscreen.emptyQueue")}</span>
      </div>
    );
  }

  return (
    <>
      <DndContext
        sensors={sensors}
        collisionDetection={closestCenter}
        onDragStart={onUserDragStart}
        onDragEnd={onUserDragEnd}
      >
        <SortableContext
          items={userSortableItems}
          strategy={verticalListSortingStrategy}
        >
          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            onDragStart={onUpcomingDragStart}
            onDragEnd={onUpcomingDragEnd}
          >
            <SortableContext
              items={upcomingSortableItems}
              strategy={verticalListSortingStrategy}
            >
              <ScrollArea
                ref={parentRef}
                type="always"
                className={cn(
                  scrollAreaClassName ?? "w-full h-full overflow-auto",
                  FULLSCREEN_QUEUE_BG_CLASS,
                )}
                thumbClassName={thumbClassName}
                data-vaul-no-drag
              >
                <div
                  className="px-2"
                  style={{
                    height: `${virtualizer.getTotalSize()}px`,
                    width: "100%",
                    position: "relative",
                  }}
                >
                  {virtualizer.getVirtualItems().map((virtualRow) => {
                    const item = virtualItems[virtualRow.index];
                    if (!item) return null;

                    return (
                      <div
                        key={virtualRow.key}
                        style={{
                          position: "absolute",
                          top: 0,
                          left: 0,
                          width: "100%",
                          height: `${virtualRow.size}px`,
                          transform: `translateY(${virtualRow.start}px)`,
                        }}
                      >
                        {item.type === "history" && (
                          <QueueItemRow
                            song={item.song}
                            isActive={currentSong?.id === item.song.id}
                            onPlay={() => playHistorySong(item.song)}
                            tier="context"
                            {...queueItemProps}
                          />
                        )}

                        {item.type === "currentSong" && (
                          <div
                            data-current-song
                            className={cn(
                              hideCurrentSongContent
                                ? "h-px overflow-hidden"
                                : "px-0 pt-2 pb-0.5",
                            )}
                            aria-hidden={hideCurrentSongContent || undefined}
                          >
                            {!hideCurrentSongContent && (
                              <QueueCurrentSong onClick={onCurrentSongClick} />
                            )}
                          </div>
                        )}

                        {item.type === "modeButtons" && (
                          <div className="pt-1 pb-1">
                            <QueueModeButtons />
                          </div>
                        )}

                        {item.type === "queueHeader" && (
                          <div className="flex items-center justify-between px-2 py-1">
                            <h3 className="text-xs font-semibold text-foreground/70 uppercase tracking-wider">
                              Queue
                            </h3>
                            <Button
                              variant="ghost"
                              size="sm"
                              className="h-6 px-2 text-xs text-foreground/50 hover-supported:text-foreground"
                              onClick={clearUserQueue}
                            >
                              {t("generic.clear")}
                            </Button>
                          </div>
                        )}

                        {item.type === "userQueueSong" && (
                          <SortableQueueItem
                            id={item.song.id}
                            song={item.song}
                            isActive={currentSong?.id === item.song.id}
                            onPlay={() =>
                              playFromUserQueue(item.userQueueIndex)
                            }
                            tier="user"
                            {...queueItemProps}
                          />
                        )}

                        {item.type === "queueDivider" && (
                          <div className="flex items-center gap-2 px-1 py-0.5 mb-0.5">
                            <div className="h-px flex-1 bg-foreground/10" />
                            <span className="text-[10px] font-medium text-foreground/40 uppercase tracking-wider whitespace-nowrap">
                              {t("fullscreen.queueContinue")}
                            </span>
                            <div className="h-px flex-1 bg-foreground/10" />
                          </div>
                        )}

                        {item.type === "continueHeader" && (
                          <div>
                            <div className="flex items-center justify-between px-2 pt-1">
                              <h3 className="text-xs font-semibold text-foreground/70 uppercase tracking-wider">
                                {t("fullscreen.queueContinue")}
                              </h3>
                            </div>
                            <QueueSourceLabel sourceName={sourceName} />
                          </div>
                        )}

                        {item.type === "emptyQueueMessage" && (
                          <div>
                            <div className="flex items-center justify-center py-4">
                              <span className="text-foreground/50 text-xs">
                                {t("fullscreen.emptyQueue")}
                              </span>
                            </div>
                          </div>
                        )}

                        {item.type === "upcomingSong" && (
                          <SortableQueueItem
                            id={item.song.id}
                            song={item.song}
                            isActive={false}
                            onPlay={() =>
                              playFromQueue(contextSongs, item.contextIdx)
                            }
                            tier="context"
                            {...queueItemProps}
                          />
                        )}

                        {item.type === "repeatIndicator" && (
                          <RepeatIndicator
                            icon={item.icon}
                            label={item.label}
                          />
                        )}
                      </div>
                    );
                  })}
                </div>
              </ScrollArea>
            </SortableContext>
          </DndContext>
        </SortableContext>
      </DndContext>
      {createPortal(
        <DragOverlay>
          {activeItem && (
            <div
              className="rounded-md shadow-lg"
              style={{ background: dragOverlayBg || undefined }}
            >
              <QueueItemRow
                song={activeItem}
                isActive={currentSong?.id === activeItem.id}
                onPlay={() => {}}
                {...queueItemProps}
              />
            </div>
          )}
        </DragOverlay>,
        document.body,
      )}
    </>
  );
}

function RepeatIndicator({
  icon: Icon,
  label,
}: {
  icon: LucideIcon;
  label: string;
}) {
  return (
    <div className="flex items-center justify-center gap-2 py-2 opacity-30 select-none">
      <Icon size={14} />
      <span className="text-xs font-medium uppercase tracking-widest">
        {label}
      </span>
    </div>
  );
}

function UserQueueSection({
  userQueueSongs,
  userSortableItems,
  currentSong,
  sensors,
  onDragStart,
  onDragEnd,
  clearUserQueue,
  activeItem,
  dragOverlayBg,
  onPlaySong,
  t,
  sticky = false,
  queueItemProps,
}: {
  userQueueSongs: ISong[];
  userSortableItems: string[];
  currentSong: ISong | null;
  sensors: ReturnType<typeof useQueueDndSensors>;
  onDragStart: (e: DragStartEvent) => void;
  onDragEnd: (e: DragEndEvent) => void;
  clearUserQueue: () => void;
  activeItem: ISong | null;
  dragOverlayBg: string;
  onPlaySong: (userQueueIndex: number) => void;
  t: (key: string) => string;
  sticky?: boolean;
  queueItemProps: {
    hideDownload: boolean;
    hideDuration: boolean;
    hideDropdownButton: boolean;
    isMobile: boolean;
  };
}) {
  const filteredUserQueueSongs = userQueueSongs.filter(
    (song) => song.id !== currentSong?.id,
  );

  if (filteredUserQueueSongs.length === 0) return null;

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
    >
      <SortableContext
        items={userSortableItems}
        strategy={verticalListSortingStrategy}
      >
        <div className="pt-1">
          <div
            className={cn(
              sticky && `${FULLSCREEN_QUEUE_BG_CLASS} sticky top-0 z-10`,
              "flex items-center justify-between px-2 py-1",
            )}
          >
            <h3 className="text-xs font-semibold text-foreground/70 uppercase tracking-wider">
              Queue
            </h3>
            <Button
              variant="ghost"
              size="sm"
              className="h-6 px-2 text-xs text-foreground/50 hover-supported:text-foreground"
              onClick={clearUserQueue}
            >
              {t("generic.clear")}
            </Button>
          </div>
          {filteredUserQueueSongs.map((song) => {
            const userQueueIndex = userQueueSongs.findIndex(
              (s) => s.id === song.id,
            );
            const isCurrent = currentSong?.id === song.id;
            return (
              <SortableQueueItem
                key={song.id}
                id={song.id}
                song={song}
                isActive={isCurrent}
                onPlay={() => onPlaySong(userQueueIndex)}
                tier="user"
                {...queueItemProps}
              />
            );
          })}
        </div>
      </SortableContext>
      {createPortal(
        <DragOverlay>
          {activeItem && (
            <div
              className="rounded-md shadow-lg"
              style={{ background: dragOverlayBg || undefined }}
            >
              <QueueItemRow
                song={activeItem}
                isActive={currentSong?.id === activeItem.id}
                onPlay={() => {}}
                {...queueItemProps}
              />
            </div>
          )}
        </DragOverlay>,
        document.body,
      )}
    </DndContext>
  );
}
