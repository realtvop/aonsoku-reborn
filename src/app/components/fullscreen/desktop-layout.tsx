import { AnimatePresence, motion } from "framer-motion";
import { ChevronDown, ListChecks, ListMusic, MicVocalIcon } from "lucide-react";
import { memo } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";

import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { useHasLyrics } from "@/app/hooks/use-has-lyrics";
import { useIsTouchPrimary } from "@/app/hooks/use-input-mode";
import { cn } from "@/lib/utils";
import { closeFullscreenPlayerWithHistory } from "@/routes/fullscreenRouter";
import { useFullscreenPlayerState } from "@/store/player.store";
import { ArtworkWithInfo } from "./artwork-with-info";
import { FullscreenControlPanel } from "./control-panel";
import { CustomLyricsSelect } from "./custom-lyrics-select";
import { LyricsTab } from "./lyrics";
import { FullscreenSongQueue } from "./queue";
import { FullscreenSettings } from "./settings";

const MemoLyricsTab = memo(LyricsTab);

export const DesktopLayout = memo(function DesktopLayout() {
  const {
    desktopFullscreenPanelView: rightPanelView,
    setDesktopFullscreenPanelView: setRightPanelView,
  } = useFullscreenPlayerState();
  const { t } = useTranslation();
  const { hasLyrics } = useHasLyrics();
  const isTouchPrimary = useIsTouchPrimary();
  const contrast = useFullscreenContrast();

  const lyricsDisabled = hasLyrics === false;

  function handleQueueClick() {
    setRightPanelView(rightPanelView === "queue" ? null : "queue");
  }

  function handleLyricsClick() {
    if (lyricsDisabled) return;
    setRightPanelView(rightPanelView === "lyrics" ? null : "lyrics");
  }

  function handleSelectLyricsClick() {
    setRightPanelView(
      rightPanelView === "customLyrics" ? null : "customLyrics",
    );
  }

  return (
    <div
      className={cn(
        "flex h-full w-full overflow-hidden text-foreground",
        contrast.className,
      )}
      data-testid="fullscreen-desktop-layout"
      style={contrast.style}
    >
      <div
        className={`fullscreen-desktop-playing flex h-full min-w-0 shrink-0 flex-col px-8 pt-6 pb-4 md:px-12 ${rightPanelView ? "w-1/2" : "w-full"}`}
      >
        <div className="flex items-center gap-2 shrink-0">
          <Button
            variant="ghost"
            size="icon"
            className={`size-10 rounded-full ${contrast.hoverBg}`}
            onClick={closeFullscreenPlayerWithHistory}
            aria-label="Close"
          >
            <ChevronDown className="size-5" />
          </Button>
          <div className="flex-1" />
          {!rightPanelView && (
            <>
              <Button
                variant="ghost"
                size="icon"
                className={`size-10 rounded-full ${contrast.hoverBg}`}
                onClick={handleQueueClick}
                aria-label={t("fullscreen.queue")}
              >
                <ListMusic className="size-4" />
              </Button>
              <Button
                variant="ghost"
                size="icon"
                className={`size-10 rounded-full ${contrast.hoverBg} ${lyricsDisabled ? "opacity-50 cursor-not-allowed" : ""}`}
                onClick={handleLyricsClick}
                disabled={lyricsDisabled}
                aria-label={t("fullscreen.lyrics")}
              >
                <MicVocalIcon className="size-4" />
              </Button>
              <Button
                variant="ghost"
                size="icon"
                className={`size-10 rounded-full ${contrast.hoverBg}`}
                onClick={handleSelectLyricsClick}
                aria-label={t("fullscreen.selectLyrics")}
              >
                <ListChecks className="size-4" />
              </Button>
            </>
          )}
          <FullscreenSettings />
        </div>

        <div className="flex min-w-0 flex-1 flex-col items-center justify-center min-h-0">
          <div className="flex w-full min-w-0 flex-col items-center max-h-full overflow-y-hidden overflow-y-clip">
            <ArtworkWithInfo
              className="flex-1 min-h-0"
              showTouchDragSurface={isTouchPrimary}
            />
            <FullscreenControlPanel />
          </div>
        </div>
      </div>

      <div
        className={`shrink-0 flex h-full flex-col overflow-hidden ${rightPanelView ? "w-1/2" : "w-0"}`}
        data-testid="fullscreen-desktop-side-panel"
        data-view={rightPanelView ?? "closed"}
        style={{ "--queue-bg-overlay": "transparent" } as React.CSSProperties}
      >
        <div className="flex items-center justify-between px-4 pt-6 pb-2">
          <div className="flex gap-1">
            <Button
              variant="ghost"
              size="sm"
              className={cn(
                "gap-1.5",
                rightPanelView === "queue"
                  ? "fullscreen-backdrop-layer rounded-md hover-supported:bg-transparent"
                  : contrast.hoverBg,
              )}
              onClick={handleQueueClick}
            >
              <ListMusic className="size-4" />
              {t("fullscreen.queue")}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className={cn(
                "gap-1.5",
                lyricsDisabled && "opacity-50 cursor-not-allowed",
                rightPanelView === "lyrics"
                  ? "fullscreen-backdrop-layer rounded-md hover-supported:bg-transparent"
                  : contrast.hoverBg,
              )}
              onClick={handleLyricsClick}
              disabled={lyricsDisabled}
            >
              <MicVocalIcon className="size-4" />
              {t("fullscreen.lyrics")}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className={cn(
                "gap-1.5",
                rightPanelView === "customLyrics"
                  ? "fullscreen-backdrop-layer rounded-md hover:bg-transparent"
                  : contrast.hoverBg,
              )}
              onClick={handleSelectLyricsClick}
            >
              <ListChecks className="size-4" />
              {t("fullscreen.selectLyrics")}
            </Button>
          </div>
        </div>

        <div className="flex-1 overflow-hidden pb-4" data-vaul-no-drag>
          <AnimatePresence mode="wait">
            {rightPanelView === "queue" && (
              <motion.div
                key="queue"
                initial={{ opacity: 0, x: 20 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -20 }}
                transition={{ duration: 0.2, ease: [0.4, 0, 0.2, 1] }}
                className="h-full"
              >
                <FullscreenSongQueue hideModeButtons hideCurrentSongContent />
              </motion.div>
            )}
            {rightPanelView === "lyrics" && (
              <motion.div
                key="lyrics"
                initial={{ opacity: 0, x: 20 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -20 }}
                transition={{ duration: 0.2, ease: [0.4, 0, 0.2, 1] }}
                className="h-full"
              >
                <MemoLyricsTab />
              </motion.div>
            )}
            {rightPanelView === "customLyrics" && (
              <motion.div
                key="custom-lyrics"
                initial={{ opacity: 0, x: 20 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -20 }}
                transition={{ duration: 0.2, ease: [0.4, 0, 0.2, 1] }}
                className="h-full"
              >
                <CustomLyricsSelect
                  onBack={() => setRightPanelView("lyrics")}
                />
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
});
