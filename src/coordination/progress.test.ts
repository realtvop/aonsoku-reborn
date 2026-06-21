import { describe, expect, it } from "vitest";
import { projectPlaybackProgress } from "./progress";

function anchor(overrides: Record<string, unknown> = {}) {
  return {
    snapshot: {
      progressSeconds: 10,
      durationSeconds: 120,
      isPlaying: true,
    },
    serverTime: 1_010,
    lastConfirmedAt: 1_000,
    receivedAtPerformance: 5_000,
    ...overrides,
  };
}

describe("projectPlaybackProgress", () => {
  it("derives progress from the monotonic receive anchor after throttling", () => {
    expect(projectPlaybackProgress(anchor(), 35_000)).toBe(50);
  });

  it("does not accumulate error across repeated refreshes", () => {
    const value = anchor();
    expect(projectPlaybackProgress(value, 6_000)).toBe(21);
    expect(projectPlaybackProgress(value, 7_000)).toBe(22);
  });

  it("freezes paused snapshots and clamps progress to duration", () => {
    expect(
      projectPlaybackProgress(
        anchor({
          snapshot: {
            progressSeconds: 150,
            durationSeconds: 120,
            isPlaying: false,
          },
        }),
        99_000,
      ),
    ).toBe(120);
  });

  it("ignores invalid and negative clock deltas", () => {
    expect(
      projectPlaybackProgress(
        anchor({ serverTime: 900, receivedAtPerformance: 10_000 }),
        5_000,
      ),
    ).toBe(10);
  });

  it("uses server clock metadata to age cached snapshots", () => {
    expect(projectPlaybackProgress(anchor(), 5_000)).toBe(20);
  });
});
