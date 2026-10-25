import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const nativeAudioServicePath = path.join(
  process.cwd(),
  "ios/AonsokuKit/Sources/AonsokuKit/Audio/AudioService.swift",
);
const nativeSourceResolverPath = path.join(
  process.cwd(),
  "ios/AonsokuKit/Sources/AonsokuKit/Audio/NativeSourceResolver.swift",
);

function readNativeAudioService() {
  return readFileSync(nativeAudioServicePath, "utf-8");
}

function readNativeSourceResolver() {
  return readFileSync(nativeSourceResolverPath, "utf-8");
}

describe("iOS native audio source resolution", () => {
  it("resolves WebView media stream URLs through the native source resolver", () => {
    const resolver = readNativeSourceResolver();

    expect(resolver).toContain("func resolveSource(for song: QueueSong)");
    expect(resolver).toContain(
      'song.streamUrl.hasPrefix("aonsoku-media://stream")',
    );
    expect(resolver).toContain(
      'values["id"].flatMap { $0.isEmpty ? nil : $0 } ?? song.id',
    );
    expect(resolver).toContain('params["id"] = songId');
    expect(resolver).toContain(
      'params["estimateContentLength"] = String(estimateContentLengthProvider())',
    );
  });

  it("preserves optional stream transcoding parameters for native playback", () => {
    const resolver = readNativeSourceResolver();

    expect(resolver).toContain('values["maxBitRate"]');
    expect(resolver).toContain('extra["maxBitRate"] = maxBitRate');
    expect(resolver).toContain('values["format"]');
    expect(resolver).toContain('extra["format"] = format');
  });

  it("publishes duration changes observed from the current AVPlayerItem", () => {
    const audioService = readNativeAudioService();

    expect(audioService).toContain(
      "durationObservation = item.observe(\\.duration",
    );
    expect(audioService).toContain("generation == self.playbackGeneration");
    expect(audioService).toContain("self.emitDuration()");
    expect(audioService).toContain("private func emitDuration()");
    expect(audioService).toContain("private var duration: Double");
  });

  it("accepts file URL cached audio entries in the native queue resolver", () => {
    const resolver = readNativeSourceResolver();

    expect(resolver).toContain(
      "cachedFile(songId: song.id, explicitURI: song.cachedFileUri)",
    );
    expect(resolver).toContain("let url = fileURL(from: explicitURI)");
    expect(resolver).toContain("if isUsableCachedFile(at: url) { return url }");
    expect(resolver).toContain("if let url = URL(string: uri), url.isFileURL");
    expect(resolver).toContain("return URL(fileURLWithPath: uri)");
  });
});
