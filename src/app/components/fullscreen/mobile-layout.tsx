import { AnimatePresence, motion } from "framer-motion";
import { ChevronDown, ListChecks, ListMusic, MicVocalIcon } from "lucide-react";
import { memo, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";
import { Drawer as DrawerPrimitive } from "vaul";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { useHasLyrics } from "@/app/hooks/use-has-lyrics";
import { useIsTouchPrimary } from "@/app/hooks/use-input-mode";
import { cn } from "@/lib/utils";
import {
  closeFullscreenPlayerWithHistory,
  setFullscreenTabWithHistory,
} from "@/routes/fullscreenRouter";
import {
  useFullscreenPlayerState,
  useLyricsAlignment,
  useLyricsSettings,
  useSongColor,
} from "@/store/player.store";
import { ArtworkWithInfo, FullscreenSongInfoRow } from "./artwork-with-info";
import { FULLSCREEN_QUEUE_BG_CLASS, PANEL_MAX_WIDTH } from "./constants";
import { FullscreenControlPanel } from "./control-panel";
import { CustomLyricsSelect } from "./custom-lyrics-select";
import { LyricsTab } from "./lyrics";
import { FullscreenSongQueue } from "./queue";
import { QueueCurrentSong } from "./queue-current-song";
import { FullscreenSettings } from "./settings";

const MemoLyricsTab = memo(LyricsTab);

const VIEW_TRANSITION = { duration: 0.25, ease: [0.4, 0, 0.2, 1] } as const;

const HEADER_ICON = <ChevronDown className="size-5" />;

const MobileHeader = memo(function MobileHeader({
  onClose,
  showDragHandle = false,
  compact = false,
}: {
  onClose: () => void;
  showDragHandle?: boolean;
  compact?: boolean;
}) {
  const { currentSongColor } = useSongColor();
  const contrast = useFullscreenContrast();

  return (
    <div
      className={cn(
        "relative flex items-center justify-between px-3 shrink-0 min-h-[32px] z-20",
        compact ? "pt-0 pb-1" : "pt-0.5 pb-1.5",
      )}
    >
      <Button
        variant="ghost"
        size="icon"
        className={`size-10 rounded-full ${contrast.hoverBg}`}
        onClick={onClose}
        aria-label="Close"
      >
        {HEADER_ICON}
      </Button>

      {showDragHandle && (
        <div className="absolute left-1/2 top-3 -translate-x-1/2 flex justify-center">
          <DrawerPrimitive.Handle
            preventCycle
            data-testid="fullscreen-drag-handle"
            aria-label="Drag to close"
            className="block w-9 h-1 rounded-full opacity-40 bg-foreground cursor-grab"
            style={{
              backgroundColor: currentSongColor ?? "hsl(var(--primary))",
            }}
          />
        </div>
      )}

      <FullscreenSettings />
    </div>
  );
});

function MobileTabButton({
  icon,
  active,
  disabled = false,
  onClick,
  label,
}: {
  icon: ReactNode;
  active: boolean;
  disabled?: boolean;
  onClick: () => void;
  label: string;
}) {
  return (
    <Button
      variant="ghost"
      size="icon"
      role="tab"
      aria-selected={active}
      className={cn(
        "size-10 rounded-full",
        disabled && "opacity-50 cursor-not-allowed text-foreground/70",
        !disabled &&
          active &&
          "text-foreground hover-supported:text-foreground bg-foreground/10",
        !disabled &&
          !active &&
          "text-foreground/70 hover-supported:text-foreground hover-supported:bg-foreground/10",
      )}
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
    >
      {icon}
    </Button>
  );
}

const MobileBottomTabs = memo(function MobileBottomTabs() {
  const { t } = useTranslation();
  const { fullscreenPlayerTab } = useFullscreenPlayerState();
  const { hasLyrics } = useHasLyrics();
  const { customServerEnabled, customServerUrl } = useLyricsSettings();

  const lyricsDisabled = hasLyrics === false;
  const customLyricsDisabled =
    !customServerEnabled || customServerUrl.trim().length === 0;

  return (
    <div
      className={cn(
        "shrink-0 flex items-center justify-between w-full mx-auto px-0 pt-2 pb-5 w-[65dvw] max-w-[450px]",
      )}
      role="tablist"
    >
      <MobileTabButton
        icon={<MicVocalIcon className="size-5" />}
        label={t("fullscreen.lyrics")}
        active={fullscreenPlayerTab === "lyrics"}
        disabled={lyricsDisabled}
        onClick={() =>
          setFullscreenTabWithHistory(
            fullscreenPlayerTab === "lyrics" ? "playing" : "lyrics",
          )
        }
      />
      <MobileTabButton
        icon={<ListChecks className="size-5" />}
        label={t("fullscreen.selectLyrics")}
        active={fullscreenPlayerTab === "customLyrics"}
        disabled={customLyricsDisabled}
        onClick={() =>
          setFullscreenTabWithHistory(
            fullscreenPlayerTab === "customLyrics" ? "playing" : "customLyrics",
          )
        }
      />
      <MobileTabButton
        icon={<ListMusic className="size-5" />}
        label={t("fullscreen.queue")}
        active={fullscreenPlayerTab === "queue"}
        onClick={() =>
          setFullscreenTabWithHistory(
            fullscreenPlayerTab === "queue" ? "playing" : "queue",
          )
        }
      />
    </div>
  );
});

const MobilePlayingView = memo(function MobilePlayingView() {
  const isTouchPrimary = useIsTouchPrimary();

  return (
    <div className="flex flex-col items-center justify-center w-full flex-1 min-h-0">
      {/* Artwork Section: AlbumName + Artwork */}
      <ArtworkWithInfo
        largeArtwork
        showInfo={false}
        showTouchDragSurface={isTouchPrimary}
        className="w-full flex-1 min-h-0"
      />

      {/* Info Section: Visually centered between artwork and progress */}
      <FullscreenSongInfoRow className="py-8" />

      {/* Control Section: Progress, Controls, VolumeBar */}
      <FullscreenControlPanel flushTop relaxed className="w-full" />
    </div>
  );
});

export const MobileLayout = memo(function MobileLayout({
  showDragHandle = false,
}: {
  showDragHandle?: boolean;
}) {
  const { fullscreenPlayerTab } = useFullscreenPlayerState();
  const areLyricsAligned = useLyricsAlignment();
  const contrast = useFullscreenContrast();

  return (
    <div
      className={cn(
        "flex flex-col h-full w-full text-foreground",
        contrast.className,
      )}
      data-testid="fullscreen-mobile-layout"
      style={contrast.style}
    >
      <MobileHeader
        onClose={closeFullscreenPlayerWithHistory}
        showDragHandle={showDragHandle}
      />

      <div className="flex-1 min-h-0 flex flex-col">
        <AnimatePresence mode="wait">
          {fullscreenPlayerTab === "playing" && (
            <motion.div
              key="playing-view"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={VIEW_TRANSITION}
              data-testid="fullscreen-playing-view"
              className="flex min-h-0 flex-1 flex-col items-center overflow-hidden overflow-clip px-4"
            >
              <MobilePlayingView />
            </motion.div>
          )}

          {fullscreenPlayerTab === "lyrics" && (
            <motion.div
              key="lyrics-view"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={VIEW_TRANSITION}
              className={`flex-1 overflow-hidden min-h-0 mx-auto w-full flex flex-col ${PANEL_MAX_WIDTH}`}
              data-vaul-no-drag
              onClick={(e) => e.stopPropagation()}
            >
              <div className="shrink-0 px-2 pt-2 pb-1">
                <QueueCurrentSong
                  onClick={() => setFullscreenTabWithHistory("playing")}
                />
              </div>
              <div className="flex-1 min-h-0 overflow-hidden">
                <MemoLyricsTab />
              </div>
              <AnimatePresence>
                {areLyricsAligned && (
                  <motion.div
                    initial={{ opacity: 0, height: 0 }}
                    animate={{ opacity: 1, height: "auto" }}
                    exit={{ opacity: 0, height: 0 }}
                    transition={{ duration: 0.2, ease: "easeOut" }}
                    className="overflow-hidden"
                  >
                    <FullscreenControlPanel compact />
                  </motion.div>
                )}
              </AnimatePresence>
            </motion.div>
          )}

          {fullscreenPlayerTab === "customLyrics" && (
            <motion.div
              key="custom-lyrics-view"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={VIEW_TRANSITION}
              className={`flex-1 overflow-hidden min-h-0 mx-auto w-full flex flex-col ${PANEL_MAX_WIDTH}`}
              data-vaul-no-drag
              onClick={(e) => e.stopPropagation()}
            >
              <CustomLyricsSelect
                onBack={() => setFullscreenTabWithHistory("lyrics")}
              />
            </motion.div>
          )}

          {fullscreenPlayerTab === "queue" && (
            <motion.div
              key="queue-view"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8 }}
              transition={VIEW_TRANSITION}
              className={cn(
                "flex-1 overflow-hidden min-h-0 mx-auto w-full",
                PANEL_MAX_WIDTH,
                FULLSCREEN_QUEUE_BG_CLASS,
              )}
              data-vaul-no-drag
              onClick={(e) => e.stopPropagation()}
              style={
                { "--queue-bg-overlay": "transparent" } as React.CSSProperties
              }
            >
              <FullscreenSongQueue
                onCurrentSongClick={() =>
                  setFullscreenTabWithHistory("playing")
                }
              />
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <MobileBottomTabs />
    </div>
  );
});
