import { Music } from "lucide-react";
import { CoverArt } from "@/types/coverArtType";

export interface DefaultCoverArtProps {
  coverArtType?: CoverArt;
  className?: string;
  width?: string | number;
  height?: string | number;
}

export function DefaultCoverArt({
  coverArtType = "album",
  className = "",
  width,
  height,
}: DefaultCoverArtProps) {
  return (
    <div
      className={`flex items-center justify-center bg-muted ${className}`}
      data-testid="default-cover-art"
      data-cover-type={coverArtType}
      style={width || height ? { width, height } : undefined}
    >
      <Music className="text-muted-foreground/60" />
    </div>
  );
}
