import type {
  NativeAudioBufferingChangedEvent,
  NativeAudioDurationChangedEvent,
  NativeAudioEndedEvent,
  NativeAudioErrorEvent,
  NativeAudioEvents,
  NativeAudioLoadOptions,
  NativeAudioPlaybackStateChangedEvent,
  NativeAudioProgressEvent,
  NativeAudioSeekOptions,
} from "@aonsoku/audio-contract";
import { describe, expect, it } from "vitest";
import fixtures from "../../../desktop/aonsoku-playerd/fixtures/mvp-contract.json";

interface RawFixtureSet {
  commands: Array<{
    name: string;
    request: {
      jsonrpc?: unknown;
      id?: unknown;
      method?: unknown;
      params?: unknown;
    };
  }>;
  events: Array<{
    name: string;
    event: {
      event?: unknown;
      payload?: unknown;
    };
  }>;
}

const fixtureSet = fixtures as RawFixtureSet;

describe("aonsoku-playerd contract fixtures", () => {
  it("keeps MVP command fixtures aligned with the audio contract", () => {
    expect(fixtureSet.commands.map(({ request }) => request.method)).toEqual([
      "load",
      "play",
      "pause",
      "stop",
      "seek",
    ]);

    for (const { request } of fixtureSet.commands) {
      expect(request.jsonrpc).toBe("2.0");
      expect(["string", "number"]).toContain(typeof request.id);

      if (request.method === "load") {
        assertLoadOptions(request.params);
        const payload: NativeAudioLoadOptions = request.params;
        expect(payload.source.kind).toBe("stream");
      } else if (request.method === "seek") {
        assertSeekOptions(request.params);
        const payload: NativeAudioSeekOptions = request.params;
        expect(payload.position).toBe(42);
      } else {
        expect(request.params).toBeUndefined();
      }
    }
  });

  it("keeps MVP event fixtures aligned with the audio contract", () => {
    expect(fixtureSet.events.map(({ event }) => event.event)).toEqual([
      "playbackStateChanged",
      "progress",
      "durationChanged",
      "bufferingChanged",
      "ended",
      "error",
    ]);

    for (const { event } of fixtureSet.events) {
      switch (event.event) {
        case "playbackStateChanged": {
          assertPlaybackStateChangedEvent(event.payload);
          const payload: NativeAudioPlaybackStateChangedEvent = event.payload;
          expect(payload.state).toBe("playing");
          break;
        }
        case "progress": {
          assertProgressEvent(event.payload);
          const payload: NativeAudioProgressEvent = event.payload;
          expect(payload.currentTime).toBe(42);
          break;
        }
        case "durationChanged": {
          assertDurationChangedEvent(event.payload);
          const payload: NativeAudioDurationChangedEvent = event.payload;
          expect(payload.duration).toBe(120);
          break;
        }
        case "bufferingChanged": {
          assertBufferingChangedEvent(event.payload);
          const payload: NativeAudioBufferingChangedEvent = event.payload;
          expect(payload.isBuffering).toBe(false);
          break;
        }
        case "ended": {
          assertEndedEvent(event.payload);
          const payload: NativeAudioEndedEvent = event.payload;
          expect(payload.reason).toBe("stopped");
          break;
        }
        case "error": {
          assertErrorEvent(event.payload);
          const payload: NativeAudioErrorEvent = event.payload;
          expect(payload.code).toBe("NOT_LOADED");
          break;
        }
        default:
          throw new Error(`unexpected event fixture: ${String(event.event)}`);
      }
    }
  });
});

function assertLoadOptions(
  value: unknown,
): asserts value is NativeAudioLoadOptions {
  expect(value).toEqual({
    source: {
      kind: "stream",
      url: "https://example.test/song.flac",
      songId: "song-1",
    },
    metadata: {
      title: "Fixture Song",
      artist: "Aonsoku",
      album: "Fixture Album",
      duration: 120,
      artworkUrl: "https://example.test/cover.jpg",
      coverArtId: "cover-1",
    },
    autoplay: true,
    startTime: 12.5,
    requestId: "load-1",
  });
}

function assertSeekOptions(
  value: unknown,
): asserts value is NativeAudioSeekOptions {
  expect(value).toEqual({ position: 42 });
}

function assertPlaybackStateChangedEvent(
  value: unknown,
): asserts value is NativeAudioEvents["playbackStateChanged"] {
  expect(value).toEqual({ requestId: "play-1", state: "playing" });
}

function assertProgressEvent(
  value: unknown,
): asserts value is NativeAudioEvents["progress"] {
  expect(value).toEqual({
    requestId: "seek-1",
    currentTime: 42,
    duration: 120,
    bufferedTime: 88,
  });
}

function assertDurationChangedEvent(
  value: unknown,
): asserts value is NativeAudioEvents["durationChanged"] {
  expect(value).toEqual({ requestId: "load-1", duration: 120 });
}

function assertBufferingChangedEvent(
  value: unknown,
): asserts value is NativeAudioEvents["bufferingChanged"] {
  expect(value).toEqual({ requestId: "load-1", isBuffering: false });
}

function assertEndedEvent(
  value: unknown,
): asserts value is NativeAudioEvents["ended"] {
  expect(value).toEqual({ requestId: "stop-1", reason: "stopped" });
}

function assertErrorEvent(
  value: unknown,
): asserts value is NativeAudioEvents["error"] {
  expect(value).toEqual({
    requestId: "seek-before-load",
    code: "NOT_LOADED",
    message: "cannot control playback before load",
  });
}
