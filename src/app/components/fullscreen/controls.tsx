import clsx from "clsx";
import { AnimatePresence, motion } from "framer-motion";
import {
  Loader2,
  Pause,
  Play,
  Repeat,
  Shuffle,
  SkipBack,
  SkipForward,
} from "lucide-react";
import { memo } from "react";
import RepeatOne from "@/app/components/icons/repeat-one";
import { Button } from "@/app/components/ui/button";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { usePlaybackControls } from "@/app/hooks/use-playback-controls";
import { LoopState } from "@/types/playerContext";

function FullscreenControls() {
  const {
    isPlaying,
    isBuffering,
    isTransitioning,
    isShuffleActive,
    loopState,
    cannotSkipNext,
    canUsePreviousControl,
    isLoopOff,
    isLoopAll,
    isLoopOne,
    isPlayingOneSong,
    toggleShuffle,
    playPrevSong,
    togglePlayPause,
    playNextSong,
    toggleLoop,
    hasNext,
  } = usePlaybackControls();
  const {
    isBackdropDark,
    playButtonBg,
    playButtonIconColor,
    playButtonIconFill,
  } = useFullscreenContrast();

  const secondaryBtnClass = clsx(
    "relative h-11 w-11 min-h-11 min-w-11 shrink-0 rounded-full text-foreground md:h-12 md:w-12 md:min-h-12 md:min-w-12",
    isBackdropDark
      ? "data-[state=active]:text-white hover-supported:data-[state=active]:text-white"
      : "data-[state=active]:text-primary hover-supported:data-[state=active]:text-primary",
    "hover-supported:bg-transparent hover-supported:scale-110 transition-transform will-change-transform",
  );

  const isLoading = isBuffering || isTransitioning;

  return (
    <>
      <Button
        size="icon"
        variant="ghost"
        data-state={isShuffleActive ? "active" : undefined}
        className={clsx(
          secondaryBtnClass,
          isShuffleActive && "fullscreen-button-active",
        )}
        style={{ backfaceVisibility: "hidden" }}
        onClick={() => toggleShuffle()}
        disabled={isPlayingOneSong() || !hasNext}
        unfocusable
      >
        <Shuffle className="w-5 h-5 md:w-6 md:h-6" />
      </Button>
      <Button
        size="icon"
        variant="ghost"
        className={secondaryBtnClass}
        style={{ backfaceVisibility: "hidden" }}
        onClick={() => playPrevSong()}
        disabled={!canUsePreviousControl}
        unfocusable
      >
        <SkipBack className="w-5 h-5 md:w-6 md:h-6 text-secondary-foreground fill-secondary-foreground" />
      </Button>
      <motion.button
        whileTap={{ scale: 0.9 }}
        className={clsx(
          "h-14 w-14 min-h-14 min-w-14 shrink-0 aspect-square rounded-full flex items-center justify-center cursor-pointer",
          "",
          playButtonBg,
        )}
        style={{ backfaceVisibility: "hidden" }}
        onClick={() => togglePlayPause()}
        aria-label={isLoading ? "Loading" : isPlaying ? "Pause" : "Play"}
        type="button"
      >
        <AnimatePresence mode="wait">
          {isLoading ? (
            <motion.div
              key="loading"
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.8, opacity: 0 }}
              transition={{ duration: 0.1 }}
            >
              <Loader2
                className={clsx("w-6 h-6 animate-spin", playButtonIconColor)}
              />
            </motion.div>
          ) : isPlaying ? (
            <motion.div
              key="pause"
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.8, opacity: 0 }}
              transition={{ duration: 0.1 }}
            >
              <Pause
                className={clsx(
                  "w-6 h-6",
                  playButtonIconColor,
                  playButtonIconFill,
                )}
                strokeWidth={1}
              />
            </motion.div>
          ) : (
            <motion.div
              key="play"
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.8, opacity: 0 }}
              transition={{ duration: 0.1 }}
            >
              <Play
                className={clsx(
                  "w-6 h-6",
                  playButtonIconColor,
                  playButtonIconFill,
                )}
              />
            </motion.div>
          )}
        </AnimatePresence>
      </motion.button>
      <Button
        size="icon"
        variant="ghost"
        className={secondaryBtnClass}
        style={{ backfaceVisibility: "hidden" }}
        onClick={() => playNextSong()}
        disabled={cannotSkipNext}
        unfocusable
      >
        <SkipForward className="w-5 h-5 md:w-6 md:h-6 text-secondary-foreground fill-secondary-foreground" />
      </Button>
      <Button
        size="icon"
        variant="ghost"
        data-state={loopState !== LoopState.Off ? "active" : undefined}
        aria-label="Repeat"
        aria-pressed={loopState !== LoopState.Off}
        className={clsx(
          secondaryBtnClass,
          loopState !== LoopState.Off && "fullscreen-button-active",
        )}
        onClick={() => toggleLoop()}
        style={{ backfaceVisibility: "hidden" }}
        unfocusable
      >
        {isLoopOff && <Repeat className="w-5 h-5 md:w-6 md:h-6" />}
        {isLoopAll && <Repeat className="w-5 h-5 md:w-6 md:h-6" />}
        {isLoopOne && <RepeatOne className="w-5 h-5 md:w-6 md:h-6" />}
      </Button>
    </>
  );
}

export const MemoFullscreenControls = memo(FullscreenControls);
