import { FullscreenControls } from "./controls";
import { LikeButton } from "./like-button";
import { FullscreenProgress } from "./progress";
import { VolumeContainer } from "./volume-container";

export function FullscreenPlayer() {
  return (
    <div className="w-full">
      <FullscreenProgress />

      <div className="flex flex-col sm:flex-row items-center justify-between gap-2 sm:gap-4 mt-2 sm:mt-5">
        {/* Like button - hidden on mobile */}
        <div className="hidden sm:flex w-[200px] justify-start">
          <LikeButton />
        </div>

        {/* Controls - centered on both mobile and desktop */}
        <div className="flex flex-1 justify-center items-center gap-1 sm:gap-2">
          <FullscreenControls />
        </div>

        {/* Volume - hidden on mobile */}
        <div className="hidden sm:flex w-[200px] justify-end">
          <VolumeContainer />
        </div>
      </div>

      {/* Mobile: Like and Volume in a separate row */}
      <div className="flex sm:hidden items-center justify-between mt-2 px-2">
        <LikeButton />
        <VolumeContainer className="sm:hidden" />
      </div>
    </div>
  );
}
