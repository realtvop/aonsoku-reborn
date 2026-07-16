import { mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import { DesktopScrobbleBuffer } from "./scrobble-buffer";
import { DesktopScrobbleSubmitter } from "./scrobble-submitter";

function trackedEntry(
  buffer: DesktopScrobbleBuffer,
  now: { value: number },
  songId: string,
  duration: number,
  playedMs: number,
): void {
  buffer.startTracking(songId, duration, true);
  now.value += playedMs;
  buffer.stopTracking();
}

describe("DesktopScrobbleSubmitter", () => {
  it("sends now-playing without submission and applies the scrobble threshold", async () => {
    const now = { value: 1_000 };
    const buffer = new DesktopScrobbleBuffer({
      storageDirectory: null,
      now: () => now.value,
    });
    const request = vi.fn().mockResolvedValue({});
    const submitter = new DesktopScrobbleSubmitter({
      buffer,
      request,
      now: () => now.value,
    });

    submitter.sendNowPlaying("song-1");
    trackedEntry(buffer, now, "too-short", 100, 49_999);
    trackedEntry(buffer, now, "half-played", 100, 50_000);
    trackedEntry(buffer, now, "long-song", 1_000, 240_000);
    await submitter.submitPending();

    expect(request).toHaveBeenNthCalledWith(1, {
      path: "/scrobble.view",
      query: { id: "song-1", submission: "false", time: 1_000 },
    });
    expect(request).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        query: expect.objectContaining({
          id: "half-played",
          submission: "true",
        }),
      }),
    );
    expect(request).toHaveBeenNthCalledWith(
      3,
      expect.objectContaining({
        query: expect.objectContaining({ id: "long-song", submission: "true" }),
      }),
    );
    expect(buffer.getEntries()).toEqual([]);
  });

  it("keeps failed entries ordered and removes repeated song plays exactly", async () => {
    const now = { value: 10_000 };
    const buffer = new DesktopScrobbleBuffer({
      storageDirectory: null,
      now: () => now.value,
    });
    trackedEntry(buffer, now, "same-song", 10, 5_000);
    trackedEntry(buffer, now, "same-song", 10, 5_000);
    const firstId = buffer.getEntries()[0]!.entryId;
    const request = vi
      .fn()
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValue({});
    const submitter = new DesktopScrobbleSubmitter({ buffer, request });

    await submitter.submitPending();
    expect(buffer.getEntries()).toHaveLength(1);
    expect(buffer.getEntries()[0]!.entryId).not.toBe(firstId);

    await submitter.submitPending();
    expect(buffer.getEntries()).toEqual([]);
    expect(request).toHaveBeenCalledTimes(3);
  });

  it("does nothing without a request dependency", async () => {
    const now = { value: 1_000 };
    const buffer = new DesktopScrobbleBuffer({
      storageDirectory: null,
      now: () => now.value,
    });
    trackedEntry(buffer, now, "song-1", 10, 5_000);
    const submitter = new DesktopScrobbleSubmitter({ buffer });

    submitter.sendNowPlaying("song-1");
    await submitter.submitPending();
    expect(buffer.getEntries()).toHaveLength(1);
  });

  it("retries a failed persisted entry after restart", async () => {
    const directory = mkdtempSync(path.join(os.tmpdir(), "aonsoku-scrobble-"));
    const now = { value: 1_000 };
    const firstBuffer = new DesktopScrobbleBuffer({
      storageDirectory: directory,
      now: () => now.value,
    });
    trackedEntry(firstBuffer, now, "song-1", 10, 5_000);
    const failing = new DesktopScrobbleSubmitter({
      buffer: firstBuffer,
      request: vi.fn().mockRejectedValue(new Error("offline")),
    });
    await failing.submitPending();

    const restoredBuffer = new DesktopScrobbleBuffer({
      storageDirectory: directory,
    });
    const request = vi.fn().mockResolvedValue({});
    const restored = new DesktopScrobbleSubmitter({
      buffer: restoredBuffer,
      request,
    });
    await restored.submitPending();

    expect(request).toHaveBeenCalledWith({
      path: "/scrobble.view",
      query: {
        id: "song-1",
        submission: "true",
        time: 1_000,
      },
    });
    expect(restoredBuffer.getEntries()).toEqual([]);
  });
});
