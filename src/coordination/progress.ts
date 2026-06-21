import type { PlaybackSnapshot } from "./types";

export interface PlaybackProgressAnchor {
  snapshot: Pick<
    PlaybackSnapshot,
    "progressSeconds" | "durationSeconds" | "isPlaying"
  >;
  serverTime: number;
  lastConfirmedAt: number;
  receivedAtPerformance: number;
}

function finiteNonNegative(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

export function projectPlaybackProgress(
  anchor: PlaybackProgressAnchor,
  nowPerformance = performance.now(),
): number {
  const duration = finiteNonNegative(anchor.snapshot.durationSeconds);
  const progress = finiteNonNegative(anchor.snapshot.progressSeconds);

  if (!anchor.snapshot.isPlaying) {
    return Math.min(progress, duration);
  }

  const snapshotAge = Math.max(
    0,
    finiteNonNegative(anchor.serverTime) -
      finiteNonNegative(anchor.lastConfirmedAt),
  );
  const localElapsed =
    Math.max(
      0,
      finiteNonNegative(nowPerformance) -
        finiteNonNegative(anchor.receivedAtPerformance),
    ) / 1000;

  return Math.min(progress + snapshotAge + localElapsed, duration);
}
