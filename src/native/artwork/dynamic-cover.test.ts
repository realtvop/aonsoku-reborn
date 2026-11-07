import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { dynamicCover, isDynamicCoverAvailable } from ".";
import type { DynamicCoverProvider, DynamicCoverVideo } from "./types";

const request = {
  coverArtId: "album-1",
  format: "square",
  mode: "dynamic",
} as const;
const capabilities = {
  version: 1,
  available: true,
  formats: ["square"],
} as const;
const video: DynamicCoverVideo = {
  status: "ready",
  leaseId: "lease-1",
  assetId: "depth-v6",
  coverArtId: "album-1",
  format: "square",
  stage: "depth",
  backend: "fixture",
  width: 720,
  height: 720,
  duration: 6,
  src: "https://example.test/leased-cover.mp4",
};
const host = {
  getCapabilities: vi.fn(),
  acquire: vi.fn(),
  release: vi.fn(),
  registerDemand: vi.fn(),
  releaseDemand: vi.fn(),
};

describe("optional dynamic cover provider", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.stubGlobal("window", { aonsokuDynamicCover: host });
    host.getCapabilities.mockResolvedValue(capabilities);
    host.acquire.mockResolvedValue(video);
    host.release.mockResolvedValue(undefined);
    host.registerDemand.mockResolvedValue({ demandId: "consumer" });
    host.releaseDemand.mockResolvedValue(undefined);
  });
  afterEach(() => vi.unstubAllGlobals());

  it("preserves static fallback when no provider is installed", async () => {
    window.aonsokuDynamicCover = undefined;
    expect(isDynamicCoverAvailable()).toBe(false);
    expect(await dynamicCover.getCapabilities()).toMatchObject({
      available: false,
    });
    expect(await dynamicCover.acquire(request)).toEqual({
      status: "unavailable",
      reason: "provider-not-installed",
    });
    expect(await dynamicCover.requestGeneration(request)).toBeUndefined();
    expect(host.acquire).not.toHaveBeenCalled();
  });
  it("works without a window during server-side evaluation", async () => {
    vi.stubGlobal("window", undefined);
    expect(isDynamicCoverAvailable()).toBe(false);
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
  });
  it("releases once through the granting provider after it is replaced", async () => {
    const result = await dynamicCover.acquire(request);
    if (result.status !== "ready") throw new Error("Expected lease");
    window.aonsokuDynamicCover = undefined;
    await Promise.all([result.release(), result.release()]);
    expect(host.release).toHaveBeenCalledExactlyOnceWith("lease-1");
  });
  it("registers generation separately and releases demand once", async () => {
    const demand = await dynamicCover.requestGeneration(request);
    expect(host.acquire).not.toHaveBeenCalled();
    await Promise.all([demand?.release(), demand?.release()]);
    expect(host.releaseDemand).toHaveBeenCalledExactlyOnceWith("consumer");
  });
  it("retries a failed release", async () => {
    host.release.mockRejectedValueOnce(new Error("temporary"));
    const result = await dynamicCover.acquire(request);
    if (result.status !== "ready") throw new Error("Expected lease");
    await expect(result.release()).rejects.toThrow("temporary");
    await result.release();
    expect(host.release).toHaveBeenCalledTimes(2);
  });
  it("accepts an existing portrait clip for an any-format request", async () => {
    host.acquire.mockResolvedValue({
      ...video,
      format: "portrait",
      width: 300,
      height: 400,
    });
    const result = await dynamicCover.acquire({ ...request, format: "any" });
    expect(result.status).toBe("ready");
    if (result.status === "ready") await result.release();
    expect(host.registerDemand).not.toHaveBeenCalled();
  });
  it.each([
    { ...video, coverArtId: "stale" },
    { ...video, format: "portrait" },
  ])("releases mismatched assets", async (result) => {
    host.acquire.mockResolvedValue(result);
    expect(await dynamicCover.acquire(request)).toEqual({ status: "mismatch" });
    expect(host.release).toHaveBeenCalledOnce();
  });
  it("rejects an animated clip for a static request", async () => {
    expect(await dynamicCover.acquire({ ...request, mode: "static" })).toEqual({
      status: "mismatch",
    });
    expect(host.release).toHaveBeenCalledOnce();
  });
  it.each(["pending", "disabled", "busy", "unavailable"])(
    "passes %s without granting a lease",
    async (status) => {
      host.acquire.mockResolvedValue({ status });
      expect(await dynamicCover.acquire(request)).toEqual({ status });
      expect(host.release).not.toHaveBeenCalled();
    },
  );
  it("does not acquire unsupported protocols or formats", async () => {
    host.getCapabilities.mockResolvedValueOnce({ ...capabilities, version: 2 });
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
    host.getCapabilities.mockResolvedValueOnce({
      ...capabilities,
      formats: ["portrait"],
    });
    expect(await dynamicCover.acquire(request)).toMatchObject({
      status: "unavailable",
    });
    expect(host.acquire).not.toHaveBeenCalled();
  });
  it("does not request generation when demand release is unsupported", async () => {
    window.aonsokuDynamicCover = {
      ...host,
      releaseDemand: undefined,
    } as DynamicCoverProvider;
    expect(await dynamicCover.requestGeneration(request)).toBeUndefined();
    expect(host.registerDemand).not.toHaveBeenCalled();
  });
});
