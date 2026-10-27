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
const libraryMediaReferencePath = path.join(
  process.cwd(),
  "ios/AonsokuKit/Sources/AonsokuKit/Audio/LibraryMediaReference.swift",
);

function readNativeAudioService() {
  return readFileSync(nativeAudioServicePath, "utf-8");
}

function readNativeSourceResolver() {
  return readFileSync(nativeSourceResolverPath, "utf-8");
}

describe("iOS native audio source resolution", () => {
  it("resolves library media identities through the native source resolver", () => {
    const resolver = readNativeSourceResolver();
    const reference = readFileSync(libraryMediaReferencePath, "utf-8");

    expect(resolver).toContain("func resolveSource(for song: QueueSong)");
    expect(resolver).toContain(
      "LibraryMediaReference(streamURL: song.streamUrl, fallbackSongID: song.id)",
    );
    expect(resolver).toContain(
      "buildAuthenticatedStreamUrl(songId: reference.songID, extra: reference.options)",
    );
    expect(reference).toContain('components.scheme?.lowercased() == "aonsoku-media"');
    expect(reference).toContain('components.host?.lowercased() == "stream"');
    expect(reference).toContain('values["id"].flatMap { $0.isEmpty ? nil : $0 }');
    expect(resolver).toContain('params["id"] = songId');
    expect(resolver).toContain(
      'params["estimateContentLength"] = String(estimateContentLengthProvider())',
    );
  });

  it("preserves optional stream transcoding parameters for native playback", () => {
    const resolver = readNativeSourceResolver();
    const reference = readFileSync(libraryMediaReferencePath, "utf-8");

    for (const option of ["maxBitRate", "format", "timeOffset", "size"]) {
      expect(reference).toContain(`"${option}"`);
    }
    expect(reference).toContain("self.init(songID: songID, options: values)");
    expect(reference).toContain("options.filter { Self.streamOptions.contains($0.key) }");
    expect(resolver).toContain("extra: reference.options");
    expect(resolver).toContain("for (key, value) in extra");
    expect(resolver).toContain("params[key] = value");
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
