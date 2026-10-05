import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { NATIVE_AUDIO_PLUGIN_NAME } from ".";

const pluginRoot = path.join(
  process.cwd(),
  "capacitor-plugins/capacitor-native",
);
const nativeAudioPluginPath = path.join(
  pluginRoot,
  "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
);
const nativeAudioServicePath = path.join(
  pluginRoot,
  "ios/Sources/AonsokuNativePlugin/Audio/AudioService.swift",
);
const nativeAudioServiceModelsPath = path.join(
  pluginRoot,
  "ios/Sources/AonsokuNativePlugin/Audio/AudioServiceModels.swift",
);
const appLifecycleServicePath = path.join(
  pluginRoot,
  "ios/Sources/AonsokuNativePlugin/AppLifecycleService.swift",
);

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
    ios?: {
      src?: string;
    };
    android?: unknown;
  };
}

function readText(filePath: string) {
  return readFileSync(filePath, "utf-8");
}

function readPackageJson(filePath: string): PackageJson {
  return JSON.parse(readText(filePath)) as PackageJson;
}

describe("Aonsoku native audio plugin skeleton", () => {
  it("is declared as a dual-platform (iOS + Android) Capacitor plugin package", () => {
    const manifest = readPackageJson(path.join(pluginRoot, "package.json"));

    expect(manifest).toMatchObject({
      name: "@aonsoku/capacitor-native",
      peerDependencies: {
        "@capacitor/core": ">=8.0.0",
      },
      capacitor: {
        ios: {
          src: "ios",
        },
        android: {
          src: "android",
        },
      },
    });
  });

  it("is included by the app through a local file dependency", () => {
    const manifest = readPackageJson(path.join(process.cwd(), "package.json"));

    expect(manifest.dependencies?.["@aonsoku/capacitor-native"]).toBe(
      "workspace:*",
    );
  });

  it("declares an iOS Swift package without Android targets", () => {
    const packageSwift = readText(path.join(pluginRoot, "Package.swift"));

    expect(packageSwift).toContain('name: "AonsokuCapacitorNative"');
    expect(packageSwift).toContain("platforms: [.iOS(.v15)]");
    expect(packageSwift).toContain('name: "AonsokuNativePlugin"');
    expect(packageSwift).toContain('path: "ios/Sources/AonsokuNativePlugin"');
    expect(packageSwift).not.toContain("Android");
  });

  it("bridges and implements the expected native methods", () => {
    const pluginSwift = readText(nativeAudioPluginPath);
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(pluginSwift).toContain("import Capacitor");
    expect(pluginSwift).toContain(
      "public final class AonsokuNativeAudioPlugin: CAPPlugin, CAPBridgedPlugin",
    );
    expect(pluginSwift).toContain("@objc(AonsokuNativeAudioPlugin)");
    expect(pluginSwift).toContain(
      `public let jsName = "${NATIVE_AUDIO_PLUGIN_NAME}"`,
    );
    expect(pluginSwift).toContain(
      "private let service = AppServices.shared.audio",
    );
    expect(pluginSwift).toContain("service.subscribe");
    expect(audioServiceSwift).toContain("import AVFoundation");
    expect(audioServiceSwift).toContain("import MediaPlayer");
    expect(audioServiceSwift).toContain("private var player: AVPlayer?");
    expect(audioServiceSwift).toContain(
      "private let audioSession = AVAudioSession.sharedInstance()",
    );
    expect(pluginSwift).not.toContain("rejectNotImplemented");
    expect(pluginSwift).not.toContain("not_implemented");

    for (const method of nativeAudioMethods) {
      expect(pluginSwift).toContain(`CAPPluginMethod(name: "${method}"`);
      expect(pluginSwift).toContain(
        `@objc func ${method}(_ call: CAPPluginCall)`,
      );
    }
  });

  it("emits the shared playback backend event names from native iOS", () => {
    const pluginSwift = readText(nativeAudioPluginPath);

    expect(pluginSwift).toContain(
      "private func forward(_ event: AudioServiceEvent)",
    );
    expect(pluginSwift).toContain("notifyListeners(name, data: data)");

    for (const eventName of nativeAudioEventNames) {
      expect(pluginSwift).toContain(`name = "${eventName}"`);
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
      "self?.volumeView?.removeFromSuperview()",
    );
    expect(setVolumeHUDEnabled).toContain(
      "self?.volumeHostView?.addSubview(view)",
    );
    expect(setVolumeHUDEnabled).toContain("view.alpha = 0.001");
  });

  it("keeps the app facade and plugin package contracts in parity", () => {
    const appTypes = readText(
      path.join(process.cwd(), "src/native/audio/types.ts"),
    );
    const audioContract = readText(
      path.join(process.cwd(), "packages/audio-contract/src/index.ts"),
    );
    const packageDefinitions = readText(
      path.join(pluginRoot, "src/audio/definitions.ts"),
    );
    const pluginSwift = readText(nativeAudioPluginPath);
    const audioServiceModelsSwift = readText(nativeAudioServiceModelsPath);

    expect(appTypes).toContain('export * from "@aonsoku/audio-contract"');
    expect(appTypes).toContain("AonsokuAudioBridge as NativeAudioPlugin");
    expect(packageDefinitions).toContain(
      'export * from "@aonsoku/audio-contract"',
    );
    expect(packageDefinitions).toContain("extends Plugin, AonsokuAudioApi");

    for (const method of nativeAudioMethods) {
      expect(audioContract).toContain(`${method}(`);
      expect(pluginSwift).toContain(`CAPPluginMethod(name: "${method}"`);
    }

    for (const eventName of nativeAudioEventNames) {
      expect(audioContract).toContain(`${eventName}:`);
      expect(pluginSwift).toContain(`name = "${eventName}"`);
      expect(audioServiceModelsSwift).toContain(`case ${eventName}`);
    }

    for (const sourceKind of nativeAudioSourceKinds) {
      expect(audioContract).toContain(`kind: "${sourceKind}"`);
    }
  });

  it("enables iOS background audio and native audio session handling", () => {
    const infoPlist = readText(
      path.join(process.cwd(), "ios/App/App/Info.plist"),
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

  it("updates iOS Now Playing metadata and remote commands", () => {
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
      'command: "togglePlayPause"',
      'command: "next"',
      'command: "previous"',
      'command: "seek"',
    ]) {
      expect(audioServiceSwift).toContain(command);
    }

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
  });

  it("announces native cover images after caching", () => {
    const imageCacheSwift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Image/ImageCacheManager.swift",
      ),
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
    const pluginSwift = readText(nativeAudioPluginPath);
    const audioServiceSwift = readText(nativeAudioServicePath);

    for (const method of [
      "storeAudioFile",
      "resolveAudioFile",
      "deleteAudioFile",
      "clearAudioFiles",
    ]) {
      expect(pluginSwift).toContain(
        `@objc func ${method}(_ call: CAPPluginCall)`,
      );
      expect(audioServiceSwift).toContain(`public func ${method}(`);
    }
    expect(pluginSwift).toContain(
      "@objc func getAudioFileSize(_ call: CAPPluginCall)",
    );
    expect(pluginSwift).toContain(
      "service.resolveAudioFile(songId: songId)?.sizeBytes",
    );
    expect(audioServiceSwift).toContain(
      "AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)",
    );
    expect(audioServiceSwift).toContain("NativeCachedAudioFileMetadata(");
    expect(audioServiceSwift).toContain("Data(contentsOf: metadataURL)");
    expect(audioServiceSwift).toContain("options: .atomic");
  });

  it("guards native lifecycle events against stale source changes", () => {
    const pluginSwift = readText(nativeAudioPluginPath);
    const audioServiceSwift = readText(nativeAudioServicePath);

    expect(audioServiceSwift).toContain(
      "private var currentRequestId: String?",
    );
    expect(audioServiceSwift).toContain("private var playbackGeneration = 0");
    expect(pluginSwift).toContain('requestId: call.getString("requestId")');
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

  it("is wired into the generated Capacitor iOS Swift package", () => {
    const packageSwift = readText(
      path.join(process.cwd(), "ios/App/CapApp-SPM/Package.swift"),
    );

    expect(packageSwift).toContain(
      '.package(name: "AonsokuCapacitorNative", path: "../../../node_modules/@aonsoku/capacitor-native")',
    );
    expect(packageSwift).toContain(
      '.product(name: "AonsokuCapacitorNative", package: "AonsokuCapacitorNative")',
    );
  });
});
