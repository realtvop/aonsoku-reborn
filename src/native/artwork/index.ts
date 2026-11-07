import type {
  DynamicCoverCapabilities,
  DynamicCoverHandle,
  DynamicCoverProvider,
  DynamicCoverRequest,
  DynamicCoverResult,
} from "./types";

export type * from "./types";

declare global {
  interface Window {
    /** Optional host implementation. No video producer ships with this renderer. */
    aonsokuDynamicCover?: DynamicCoverProvider;
  }
}

function provider(): DynamicCoverProvider | undefined {
  return typeof window === "undefined" ? undefined : window.aonsokuDynamicCover;
}

export function isDynamicCoverAvailable(): boolean {
  return provider() !== undefined;
}

export const dynamicCover = {
  async requestGeneration(
    request: Pick<DynamicCoverRequest, "coverArtId" | "mode">,
  ) {
    const host = provider();
    if (!host?.registerDemand || !host.releaseDemand) return undefined;
    const { demandId } = await host.registerDemand(request);
    let releasing: Promise<void> | undefined;
    return {
      release: () => {
        if (!releasing)
          releasing = host.releaseDemand!(demandId).catch((error) => {
            releasing = undefined;
            throw error;
          });
        return releasing;
      },
    };
  },
  async getCapabilities(): Promise<DynamicCoverCapabilities> {
    const host = provider();
    if (!host) {
      return {
        version: 1,
        available: false,
        formats: [],
        reason: "provider-not-installed",
      };
    }
    return host.getCapabilities();
  },

  async acquire(
    request: DynamicCoverRequest,
  ): Promise<
    DynamicCoverHandle | Exclude<DynamicCoverResult, { status: "ready" }>
  > {
    const host = provider();
    if (!host) {
      return { status: "unavailable", reason: "provider-not-installed" };
    }
    const capabilities = await host.getCapabilities();
    if (
      capabilities.version !== 1 ||
      !capabilities.available ||
      !(request.format === "any"
        ? capabilities.formats.length > 0
        : capabilities.formats.includes(request.format))
    ) {
      return {
        status: "unavailable",
        reason: capabilities.reason ?? "unsupported-format",
      };
    }
    const result = await host.acquire(request);
    if (result.status !== "ready") return result;
    let releasing: Promise<void> | undefined;
    const release = () => {
      if (!releasing) {
        releasing = host.release(result.leaseId).catch((error) => {
          releasing = undefined;
          throw error;
        });
      }
      return releasing;
    };
    if (
      result.coverArtId !== request.coverArtId ||
      (request.format !== "any" && result.format !== request.format) ||
      (request.mode === "static" && result.stage !== "static")
    ) {
      await release();
      return { status: "mismatch" };
    }
    return { ...result, release };
  },
};
