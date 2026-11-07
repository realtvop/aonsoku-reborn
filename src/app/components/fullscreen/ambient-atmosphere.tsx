import { memo } from "react";
import { CachedImage } from "@/app/components/cover-image/cached-image";

interface FullscreenAmbientAtmosphereProps {
  coverArtId?: string;
  albumId?: string;
  active: boolean;
  hasRightPanel?: boolean;
  isPortrait?: boolean;
}

/**
 * Full-bleed atmospheric background layer mounted at the root of the fullscreen player.
 * By living outside safe-area padding and column flex containers, it naturally extends
 * behind the status bar and between left/right desktop panels without hitting container walls.
 */
export const FullscreenAmbientAtmosphere = memo(
  function FullscreenAmbientAtmosphere({
    coverArtId,
    albumId,
    active,
    hasRightPanel = false,
    isPortrait = false,
  }: FullscreenAmbientAtmosphereProps) {
    if (!coverArtId || !active) return null;

    // Anchor the glow center to the artwork's visual focal point:
    // - On desktop with side panel open: centered on the left playing column (x: 25%, y: 44%)
    // - On desktop full width (panel closed): centered in the viewport (x: 50%, y: 44%)
    // - On mobile: centered horizontally, slightly upper-middle (x: 50%, y: 38%)
    const centerStyle = {
      left: !isPortrait && hasRightPanel ? "25%" : "50%",
      top: isPortrait ? "38%" : "44%",
    };

    return (
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 z-0 isolate overflow-hidden select-none [contain:paint] transform-gpu"
      >
        <div
          className="absolute -translate-x-1/2 -translate-y-1/2 transition-[left,top] duration-500 ease-out"
          style={{
            ...centerStyle,
            width: "max(120vw, 120vh)",
            height: "max(120vw, 120vh)",
            maskImage:
              "radial-gradient(circle closest-side at center, black 18%, rgba(0,0,0,0.85) 38%, rgba(0,0,0,0.5) 62%, rgba(0,0,0,0.15) 84%, transparent 98%)",
            WebkitMaskImage:
              "radial-gradient(circle closest-side at center, black 18%, rgba(0,0,0,0.85) 38%, rgba(0,0,0,0.5) 62%, rgba(0,0,0,0.15) 84%, transparent 98%)",
          }}
        >
          <div className="size-full blur-[72px] sm:blur-[96px] opacity-65 scale-106 transition-opacity duration-1000">
            <div className="size-full scale-110">
              <CachedImage
                coverArtId={coverArtId}
                coverArtType="song"
                albumId={albumId}
                coverArtSize="300"
                alt=""
                className="size-full object-cover"
                wrapperClassName="size-full block"
                width="100%"
                height="100%"
              />
            </div>
          </div>
        </div>
      </div>
    );
  },
);
