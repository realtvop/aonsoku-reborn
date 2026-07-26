import { clsx } from "clsx";
import { memo } from "react";
import { CONTENT_MAX_WIDTH } from "./constants";
import { MemoFullscreenControls } from "./controls";
import { FullscreenProgress } from "./progress";
import { VolumeBar } from "./volume-bar";

export const FullscreenControlPanel = memo(function FullscreenControlPanel({
  compact = false,
  flushTop = false,
  relaxed = false,
  className,
}: {
  compact?: boolean;
  flushTop?: boolean;
  relaxed?: boolean;
  className?: string;
}) {
  return (
    <div
      className={clsx(
        "mx-auto self-center w-full flex flex-col min-h-0",
        CONTENT_MAX_WIDTH,
        compact
          ? "shrink-0 gap-3 pb-2"
          : clsx(
              "shrink-0",
              flushTop ? "pt-0" : "pt-7",
              relaxed ? "gap-8 pb-8" : "gap-5 pb-7",
            ),
        className,
      )}
    >
      <div className={clsx(compact && "shrink-0")}>
        <FullscreenProgress thin stacked />
      </div>
      <div
        className={clsx(
          "flex min-h-14 items-center justify-between",
          compact ? "shrink-0" : "md:justify-center md:gap-3",
        )}
      >
        <MemoFullscreenControls />
      </div>
      <div className={clsx(compact && "shrink-0")} data-vaul-no-drag>
        <VolumeBar />
      </div>
    </div>
  );
});
