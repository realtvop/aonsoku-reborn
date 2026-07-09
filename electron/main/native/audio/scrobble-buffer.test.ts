import { mkdtempSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { DesktopScrobbleBuffer } from "./scrobble-buffer";

describe("DesktopScrobbleBuffer persistence", () => {
  it("restores flushed entries after recreating the buffer", () => {
    const directory = mkdtempSync(path.join(os.tmpdir(), "aonsoku-scrobble-"));
    let now = 1_000;
    const first = new DesktopScrobbleBuffer({
      storageDirectory: directory,
      now: () => now,
    });

    first.startTracking("song-1", true);
    now += 2_500;
    first.stopTracking();

    expect(
      JSON.parse(
        readFileSync(path.join(directory, "scrobble-buffer.json"), "utf8"),
      ),
    ).toEqual([{ songId: "song-1", playedDurationMs: 2500, timestamp: 1000 }]);
    expect(
      new DesktopScrobbleBuffer({
        storageDirectory: directory,
      }).getScrobbleBuffer(),
    ).toEqual({
      entries: [{ songId: "song-1", playedDurationMs: 2500, timestamp: 1000 }],
    });
  });
});
