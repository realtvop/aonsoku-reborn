import type { NativeFullState } from "@/native/audio";
import { describe, expect, it } from "vitest";
import { buildPlaybackSnapshotFromNativeFullState } from "./native-full-state-snapshot";

describe("buildPlaybackSnapshotFromNativeFullState", () => {
  it("exports queue, playback, and handoff fields from native full state", () => {
    const state: NativeFullState = {
      contextQueue: {
        songs: [queueSong("song-1"), queueSong("song-2")],
        currentIndex: 1,
        sourceId: { type: "album", id: "album-1" },
        sourceName: "Album One",
      },
      userQueue: [queueSong("song-3")],
      originalContextSongs: [queueSong("song-1"), queueSong("song-2")],
      originalUserSongs: [],
      shuffleHistory: ["song-0"],
      shuffleStartHistory: [],
      playedUserQueueHistory: [queueSong("song-prev")],
      isInUserQueue: false,
      isShuffleActive: true,
      loopState: "all",
      isPlaying: true,
      currentTime: 42,
      duration: 200,
      currentSongId: "song-2",
      isRestored: false,
    };

    expect(
      buildPlaybackSnapshotFromNativeFullState("session-1", state, {
        volume: 75,
        sampledAt: 123,
      }),
    ).toEqual({
      sessionId: "session-1",
      logicalPlaybackSessionId: "session-1",
      mediaKind: "song",
      songId: "song-2",
      progressSeconds: 42,
      durationSeconds: 200,
      isPlaying: true,
      sampledAt: 123,
      contextQueue: ["song-1", "song-2"],
      contextIndex: 1,
      sourceId: "album:album-1",
      sourceName: "Album One",
      userQueue: ["song-3"],
      inUserQueue: false,
      restorePrevious: ["song-prev"],
      shuffle: true,
      repeat: "all",
      volume: 0.75,
      accumulatedPlaySeconds: 0,
      historyWritten: false,
      nowPlayingSent: false,
      scrobbleSent: false,
    });
  });

  it("falls back to current queue song duration and rejects empty state", () => {
    const state: NativeFullState = {
      contextQueue: {
        songs: [queueSong("song-1", 88)],
        currentIndex: 0,
        sourceId: null,
        sourceName: null,
      },
      userQueue: [],
      originalContextSongs: [],
      originalUserSongs: [],
      shuffleHistory: [],
      shuffleStartHistory: [],
      playedUserQueueHistory: [],
      isInUserQueue: false,
      isShuffleActive: false,
      loopState: "off",
      isPlaying: false,
      currentTime: -1,
      duration: 0,
      currentSongId: null,
      isRestored: false,
    };

    expect(
      buildPlaybackSnapshotFromNativeFullState("session-1", state, {
        volume: null,
        sampledAt: 123,
      }),
    ).toMatchObject({
      songId: "song-1",
      progressSeconds: 0,
      durationSeconds: 88,
      contextIndex: 0,
      sourceId: null,
      volume: null,
    });

    expect(
      buildPlaybackSnapshotFromNativeFullState(
        "session-1",
        {
          ...state,
          contextQueue: {
            ...state.contextQueue,
            songs: [],
          },
        },
        { volume: null },
      ),
    ).toBeNull();
  });
});

function queueSong(id: string, duration = 100) {
  return {
    id,
    title: `Title ${id}`,
    artist: "Artist",
    album: "Album",
    duration,
    streamUrl: `https://server/rest/stream?id=${id}`,
  };
}
