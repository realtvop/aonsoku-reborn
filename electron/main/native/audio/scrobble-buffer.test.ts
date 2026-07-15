import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { DesktopScrobbleBuffer } from "./scrobble-buffer";

describe("DesktopScrobbleBuffer persistence", () => {
  it("tracks only playing segments and restores duration metadata", () => {
    const directory = mkdtempSync(path.join(os.tmpdir(), "aonsoku-scrobble-"));
    let now = 1_000;
    const first = new DesktopScrobbleBuffer({
      storageDirectory: directory,
      now: () => now,
    });

    first.startTracking("song-1", 100, true);
    now += 1_500;
    first.pauseTracking();
    now += 2_000;
    first.resumeTracking();
    now += 500;
    first.stopTracking();

    const persisted = JSON.parse(
      readFileSync(path.join(directory, "scrobble-buffer.json"), "utf8"),
    );
    expect(persisted).toEqual([
      expect.objectContaining({
        entryId: expect.any(String),
        songId: "song-1",
        playedDurationMs: 2_000,
        timestamp: 1_000,
        songDurationSeconds: 100,
      }),
    ]);
    expect(
      new DesktopScrobbleBuffer({
        storageDirectory: directory,
      }).getEntries(),
    ).toEqual(persisted);
  });

  it("migrates legacy entries to stable exact entry ids", () => {
    const directory = mkdtempSync(path.join(os.tmpdir(), "aonsoku-scrobble-"));
    const storagePath = path.join(directory, "scrobble-buffer.json");
    writeFileSync(
      storagePath,
      JSON.stringify([
        { songId: "same-song", playedDurationMs: 60_000, timestamp: 1_000 },
        { songId: "same-song", playedDurationMs: 70_000, timestamp: 2_000 },
      ]),
    );

    const first = new DesktopScrobbleBuffer({ storageDirectory: directory });
    const entries = first.getEntries();
    expect(entries[0]?.entryId).not.toBe(entries[1]?.entryId);

    first.removeEntry(entries[0]!.entryId);
    expect(first.getEntries()).toEqual([entries[1]]);
    expect(
      new DesktopScrobbleBuffer({ storageDirectory: directory }).getEntries(),
    ).toEqual([entries[1]]);
  });
});
