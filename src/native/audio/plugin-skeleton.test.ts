import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const pluginRoot = path.join(
  process.cwd(),
  "capacitor-plugins/capacitor-native",
);
const kitRoot = path.join(process.cwd(), "ios/AonsokuKit");
const kitSourcesRoot = path.join(kitRoot, "Sources/AonsokuKit");
const nativeAudioServicePath = path.join(
  kitSourcesRoot,
  "Audio/AudioService.swift",
);
const nativeAudioServiceModelsPath = path.join(
  kitSourcesRoot,
  "Audio/AudioServiceModels.swift",
);
const appLifecycleServicePath = path.join(
  kitSourcesRoot,
  "AppLifecycleService.swift",
);
const nativeCoordinationServicePath = path.join(
  kitSourcesRoot,
  "Coordination/CoordinationRealtime.swift",
);

const iosAudioServiceMethods = [
  "load",
  "play",
  "pause",
  "stop",
  "seek",
  "setRepeatMode",
  "setShuffle",
  "setQueue",
  "skipToNext",
  "skipToPrevious",
  "updateMetadata",
  "clear",
  "storeAudioFile",
  "resolveAudioFile",
  "deleteAudioFile",
  "clearAudioFiles",
  "setSystemVolume",
  "setVolumeHUDEnabled",
  "setLikeActive",
] as const;

const nativeAudioMethods = [
  "load",
  "play",
  "pause",
  "stop",
  "seek",
  "setRepeatMode",
  "setShuffle",
  "setQueue",
  "skipToNext",
  "skipToPrevious",
  "updateMetadata",
  "preload",
  "clear",
  "storeAudioFile",
  "resolveAudioFile",
  "getAudioFileSize",
  "deleteAudioFile",
  "clearAudioFiles",
  "setSystemVolume",
  "getSystemVolume",
  "setVolumeHUDEnabled",
  "setLikeActive",
] as const;

const nativeAudioEventNames = [
  "playbackStateChanged",
  "progress",
  "durationChanged",
  "bufferingChanged",
  "ended",
  "error",
  "remoteCommand",
  "interruptionChanged",
  "routeChanged",
  "systemVolumeChanged",
] as const;

const nativeAudioSourceKinds = [
  "stream",
  "blob",
  "native-file",
  "radio",
] as const;

interface PackageJson {
  name?: string;
  dependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  capacitor?: {
    ios?: unknown;
    android?: unknown;
  };
}

function readText(filePath: string) {
  return readFileSync(filePath, "utf-8");
}

function readPackageJson(filePath: string): PackageJson {
  return JSON.parse(readText(filePath)) as PackageJson;
}

describe("Aonsoku native audio packages", () => {
  it("is declared as an Android-only Capacitor plugin package", () => {
    const manifest = readPackageJson(path.join(pluginRoot, "package.json"));

    expect(manifest).toMatchObject({
      name: "@aonsoku/capacitor-native",
      peerDependencies: {
        "@capacitor/core": ">=8.0.0",
      },
      capacitor: {
        android: {
          src: "android",
        },
      },
    });
    expect(manifest.capacitor?.ios).toBeUndefined();
  });

  it("is included by the app through a local file dependency", () => {
    const manifest = readPackageJson(path.join(process.cwd(), "package.json"));

    expect(manifest.dependencies?.["@aonsoku/capacitor-native"]).toBe(
      "workspace:*",
    );
  });

  it("declares the iOS AonsokuKit Swift package without Android targets", () => {
    const packageSwift = readText(path.join(kitRoot, "Package.swift"));

    expect(packageSwift).toContain('name: "AonsokuKit"');
    expect(packageSwift).toContain("platforms: [.iOS(.v26)]");
    expect(packageSwift).toContain('path: "Sources/AonsokuKit"');
    expect(packageSwift).not.toContain("Android");
  });

  it("implements native iOS playback directly in AudioService", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(audioServiceSwift).not.toContain("import Capacitor");
    expect(audioServiceSwift).toContain("import AVFoundation");
    expect(audioServiceSwift).toContain("import MediaPlayer");
    expect(audioServiceSwift).toContain("private var player: AVPlayer?");
    expect(audioServiceSwift).toContain(
      "private let audioSession = AVAudioSession.sharedInstance()",
    );

    for (const method of iosAudioServiceMethods) {
      expect(audioServiceSwift).toContain(`public func ${method}(`);
    }
  });

  it("models the shared playback backend events in native iOS", () => {
    const audioServiceModelsSwift = readText(nativeAudioServiceModelsPath);

    expect(audioServiceModelsSwift).toContain(
      "public enum AudioServiceEvent: Sendable",
    );
    for (const eventName of nativeAudioEventNames) {
      expect(audioServiceModelsSwift).toContain(`case ${eventName}`);
    }
  });

  it("leaves the iOS volume HUD unsuppressed outside fullscreen", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);
    const setVolumeHUDEnabled =
      audioServiceSwift.match(
        /public func setVolumeHUDEnabled\(_ enabled: Bool\) \{([\s\S]*?)\n {4}\}/,
      )?.[1] ?? "";

    expect(audioServiceSwift).toContain("audioSession.observe(\\.outputVolume");
    expect(setVolumeHUDEnabled).toContain(
      "self.volumeView?.removeFromSuperview()",
    );
    expect(setVolumeHUDEnabled).toContain(
      "self.volumeHostView?.addSubview(view)",
    );
    expect(setVolumeHUDEnabled).toContain("view.alpha = 0.001");
  });

  it("keeps the app facade, plugin package, and iOS event contracts in parity", () => {
    const appTypes = readText(
      path.join(process.cwd(), "src/native/audio/types.ts"),
    );
    const audioContract = readText(
      path.join(process.cwd(), "packages/audio-contract/src/index.ts"),
    );
    const packageDefinitions = readText(
      path.join(pluginRoot, "src/audio/definitions.ts"),
    );
    const audioServiceModelsSwift = readText(nativeAudioServiceModelsPath);

    expect(appTypes).toContain('export * from "@aonsoku/audio-contract"');
    expect(appTypes).toContain("AonsokuAudioBridge as NativeAudioPlugin");
    expect(packageDefinitions).toContain(
      'export * from "@aonsoku/audio-contract"',
    );
    expect(packageDefinitions).toContain("extends Plugin, AonsokuAudioApi");

    for (const method of nativeAudioMethods) {
      expect(audioContract).toContain(`${method}(`);
    }

    for (const eventName of nativeAudioEventNames) {
      expect(audioContract).toContain(`${eventName}:`);
      expect(audioServiceModelsSwift).toContain(`case ${eventName}`);
    }

    for (const sourceKind of nativeAudioSourceKinds) {
      expect(audioContract).toContain(`kind: "${sourceKind}"`);
    }
  });

  it("enables iOS background audio and native audio session handling", () => {
    const infoPlist = readText(
      path.join(process.cwd(), "ios/Aonsoku/Resources/Info.plist"),
    );
    const audioServiceSwift = readText(nativeAudioServicePath);
    const lifecycleSwift = readText(appLifecycleServicePath);

    expect(infoPlist).toContain("<key>UIBackgroundModes</key>");
    expect(infoPlist).toContain("<string>audio</string>");
    expect(audioServiceSwift).toContain("AVAudioSession.sharedInstance()");
    expect(audioServiceSwift).toContain("private func configureAudioSession()");
    expect(audioServiceSwift).toContain("audioSession.setCategory(");
    expect(audioServiceSwift).toContain(".playback,");
    expect(audioServiceSwift).toContain("audioSession.setActive(true)");
    expect(audioServiceSwift).toContain(
      "AVAudioSession.interruptionNotification",
    );
    expect(audioServiceSwift).toContain(
      "AVAudioSession.routeChangeNotification",
    );
    expect(lifecycleSwift).toContain("public func didEnterBackground()");
    expect(lifecycleSwift).toContain("public func willEnterForeground()");
    expect(lifecycleSwift).toContain("public func didBecomeActive()");
  });

  it("updates iOS Now Playing metadata, artwork, and remote commands", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    for (const command of [
      "playCommand",
      "pauseCommand",
      "togglePlayPauseCommand",
      "nextTrackCommand",
      "previousTrackCommand",
      "changePlaybackPositionCommand",
    ]) {
      expect(audioServiceSwift).toContain(`center.${command}`);
    }
    expect(audioServiceSwift).toContain("command.isEnabled = true");

    for (const command of [
      '["type": "play"]',
      '["type": "pause"]',
      '["type": "toggle_play_pause"]',
      '["type": "next"]',
      '["type": "previous"]',
      '["type": "seek", "seconds": event.positionTime]',
      '["type": "toggle_like"]',
    ]) {
      expect(audioServiceSwift).toContain(command);
    }
    expect(audioServiceSwift).toContain(
      "CoordinationService.shared.sendCommandFromActive(",
    );

    expect(audioServiceSwift).toContain(
      "MPNowPlayingInfoCenter.default().nowPlayingInfo",
    );
    expect(audioServiceSwift).toContain("MPMediaItemPropertyTitle");
    expect(audioServiceSwift).toContain("MPMediaItemPropertyArtist");
    expect(audioServiceSwift).toContain("MPMediaItemPropertyAlbumTitle");
    expect(audioServiceSwift).toContain("MPMediaItemPropertyPlaybackDuration");
    expect(audioServiceSwift).toContain(
      "MPNowPlayingInfoPropertyElapsedPlaybackTime",
    );
    expect(audioServiceSwift).toContain("MPNowPlayingInfoPropertyPlaybackRate");
    expect(audioServiceSwift).toContain(
      "MPMediaItemArtwork(boundsSize: image.size)",
    );
    expect(audioServiceSwift).toContain(
      "imageCache.resolveCoverImage(coverArtId:",
    );
    expect(audioServiceSwift).toContain("imageCache.downloadCoverImage(");
    expect(audioServiceSwift).toContain("forName: .aonsokuCoverImageCached");
    expect(audioServiceSwift).toContain(
      "cachedCoverArtId == currentNowPlayingCoverArtId()",
    );
  });

  it("bridges native audio changes into coordination snapshots", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);
    const coordinationSwift = readText(nativeCoordinationServicePath);

    expect(audioServiceSwift).toContain(
      "NotificationCenter.default.post(name: .aonsokuAudioStateDidChange",
    );
    expect(coordinationSwift).toContain("forName: .aonsokuAudioStateDidChange");
    expect(coordinationSwift).toContain("publishNativePlaybackSnapshot()");
  });

  it("refreshes native playback state and volume on foreground entry", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(audioServiceSwift).toContain("self.emitCurrentPlaybackState()");
    expect(audioServiceSwift).toContain("self.emitProgress()");
    expect(audioServiceSwift).toContain(
      "self.emit(.systemVolumeChanged(self.audioSession.outputVolume))",
    );
  });

  it("announces native cover images after caching", () => {
    const imageCacheSwift = readText(
      path.join(kitSourcesRoot, "Image/ImageCacheManager.swift"),
    );

    expect(imageCacheSwift).toContain("aonsokuCoverImageCached");
    expect(imageCacheSwift).toContain(
      "notifyCoverImageCached(coverArtId: coverArtId)",
    );
    expect(imageCacheSwift).toContain("name: .aonsokuCoverImageCached");
  });

  it("tracks radio sources and invalidates old playback when clearing", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(audioServiceSwift).toContain('case .radio: return "radio"');
    expect(audioServiceSwift).toContain(
      'case .nativeFile: return "native-file"',
    );
    expect(audioServiceSwift).toContain(
      "case .blob(let url, _), .radio(let url, _):",
    );
    expect(audioServiceSwift).toContain("public func clear()");
    expect(audioServiceSwift).toContain(
      "self.clearPlayer(deactivateSession: true)",
    );
    expect(audioServiceSwift).toContain(
      "MPNowPlayingInfoCenter.default().nowPlayingInfo = nil",
    );
    expect(audioServiceSwift).toContain("playbackGeneration += 1");
  });

  it("stores and resolves iOS native cached audio files", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    for (const method of [
      "storeAudioFile",
      "resolveAudioFile",
      "deleteAudioFile",
      "clearAudioFiles",
    ]) {
      expect(audioServiceSwift).toContain(`public func ${method}(`);
    }
    expect(audioServiceSwift).toContain(
      "AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)",
    );
    expect(audioServiceSwift).toContain('let prefix = "\\(cacheId)."');
    expect(audioServiceSwift).toContain("applicationSupportDirectory");
    expect(audioServiceSwift).toContain("NativeCachedAudioFileMetadata(");
    expect(audioServiceSwift).toContain("Data(contentsOf: metadataURL)");
    expect(audioServiceSwift).toContain("options: .atomic");
  });

  it("guards native lifecycle events against stale source changes", () => {
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(audioServiceSwift).toContain(
      "private var currentRequestId: String?",
    );
    expect(audioServiceSwift).toContain("private var playbackGeneration = 0");
    expect(audioServiceSwift).toContain(
      "self.currentRequestId = request.requestId",
    );
    expect(audioServiceSwift).toContain(
      "generation == self.playbackGeneration",
    );
    expect(audioServiceSwift).toContain("item === self.playerItem");
    expect(audioServiceSwift).toContain("playbackGeneration += 1");
    expect(audioServiceSwift).toContain("statusObservation?.invalidate()");
    expect(audioServiceSwift).toContain("timeObserver = nil");
  });

  it("links AonsokuKit into the native SwiftUI app target", () => {
    const project = readText(
      path.join(process.cwd(), "ios/Aonsoku.xcodeproj/project.pbxproj"),
    );

    expect(project).toContain('XCLocalSwiftPackageReference "AonsokuKit"');
    expect(project).toContain("relativePath = AonsokuKit;");
    expect(project).toContain("productName = AonsokuKit;");
    expect(project).toContain(
      "PRODUCT_BUNDLE_IDENTIFIER = github.realtvop.aonsoku;",
    );
    expect(project).not.toContain("Capacitor");
  });

  it("ensures no AonsokuKit sources import Capacitor", () => {
    function walkDir(dir: string, callback: (filePath: string) => void) {
      const files = readdirSync(dir);
      for (const file of files) {
        const filePath = path.join(dir, file);
        const stat = statSync(filePath);
        if (stat.isDirectory()) {
          walkDir(filePath, callback);
        } else if (file.endsWith(".swift")) {
          callback(filePath);
        }
      }
    }

    const sourceRoots = [
      kitSourcesRoot,
      path.join(process.cwd(), "ios/Aonsoku"),
    ];

    const importCapacitorPattern = /^import (Capacitor|Cordova)\b/m;

    for (const root of sourceRoots) {
      walkDir(root, (filePath: string) => {
        const content = readText(filePath);
        expect(
          content,
          `File ${filePath} should not import Capacitor or Cordova`,
        ).not.toMatch(importCapacitorPattern);
      });
    }
  });
});
