export type DynamicCoverFormat = "square" | "portrait";
export type DynamicCoverStage = "static" | "camera" | "depth";

export interface DynamicCoverRequest {
  /** Must match the currently displayed local/remote playback cover. */
  coverArtId: string;
  format: DynamicCoverFormat | "any";
  mode: "static" | "dynamic";
}

export interface DynamicCoverCapabilities {
  version: 1;
  available: boolean;
  formats: DynamicCoverFormat[];
  reason?: string;
}

export interface DynamicCoverVideo {
  status: "ready";
  /** Playback/accessibility permission; resource restrictions only gate generation. */
  motionAllowed?: boolean;
  leaseId: string;
  assetId: string;
  coverArtId: string;
  format: DynamicCoverFormat;
  stage: DynamicCoverStage;
  backend: string;
  width: number;
  height: number;
  /** Dynamic loop duration in seconds; nominal hold duration for static clips. */
  duration: number;
  src: string;
}

export type DynamicCoverResult =
  | DynamicCoverVideo
  | {
      status: "pending" | "disabled" | "mismatch" | "unavailable" | "busy";
      reason?: string;
      motionAllowed?: boolean;
    };

/** Optional host contract; the shared renderer does not ship a video producer. */
export interface DynamicCoverProvider {
  getCapabilities(): Promise<DynamicCoverCapabilities>;
  acquire(request: DynamicCoverRequest): Promise<DynamicCoverResult>;
  release(leaseId: string): Promise<void>;
  registerDemand?(
    request: Pick<DynamicCoverRequest, "coverArtId" | "mode">,
  ): Promise<{ demandId: string }>;
  releaseDemand?(demandId: string): Promise<void>;
}

export type DynamicCoverHandle = DynamicCoverVideo & {
  /** Idempotent; bound to the provider that granted this lease. */
  release(): Promise<void>;
};
