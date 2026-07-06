import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { NATIVE_AUDIO_PLUGIN_NAME } from ".";

const pluginRoot = path.join(
  process.cwd(),
  "capacitor-plugins/capacitor-native",
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
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    expect(swift).toContain("import AVFoundation");
    expect(swift).toContain("import MediaPlayer");
    expect(swift).toContain("private var player: AVPlayer?");
    expect(swift).toContain('private var repeatMode = "off"');
    expect(swift).toContain("private var shuffleEnabled = false");
    expect(swift).toContain("private var queueItemCount = 0");
    expect(swift).toContain("private var currentSourceKind: String?");
    expect(swift).toContain("private var currentRadioId: String?");
    expect(swift).toContain(
      "private var currentMetadata = NativeAudioMetadata()",
    );
    expect(swift).toContain("private struct NativeCachedAudioFile");
    expect(swift).toContain("@objc(AonsokuNativeAudioPlugin)");
    expect(swift).toContain(
      `public let jsName = "${NATIVE_AUDIO_PLUGIN_NAME}"`,
    );
    expect(swift).not.toContain("rejectNotImplemented");
    expect(swift).not.toContain("not_implemented");

    for (const method of nativeAudioMethods) {
      expect(swift).toContain(`CAPPluginMethod(name: "${method}"`);
      expect(swift).toContain(`@objc func ${method}(_ call: CAPPluginCall)`);
    }
  });

  it("emits the shared playback backend event names from native iOS", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    for (const eventName of nativeAudioEventNames) {
      expect(swift).toContain(`notifyListeners("${eventName}"`);
    }
  });

  it("leaves the iOS volume HUD unsuppressed outside fullscreen", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );
    const setupVolumeControl =
      swift.match(
        /private func setupVolumeControl\(\) \{([\s\S]*?)\n {4}@objc func setSystemVolume/,
      )?.[1] ?? "";
    const setVolumeHUDEnabled =
      swift.match(
        /@objc func setVolumeHUDEnabled\(_ call: CAPPluginCall\) \{([\s\S]*?)\n {4}private func removeVolumeSliderView/,
      )?.[1] ?? "";
    const hudEnabledBranch =
      setVolumeHUDEnabled.match(/if enabled \{([\s\S]*?)\} else \{/)?.[1] ?? "";

    expect(setupVolumeControl).toContain("observe(\\.outputVolume");
    expect(setupVolumeControl).not.toContain("MPVolumeView(frame:");
    expect(hudEnabledBranch).toContain("removeVolumeSliderView()");
    expect(setVolumeHUDEnabled).toContain("ensureVolumeSlider()");
  });

  it("keeps the app facade and plugin package contracts in parity", () => {
    const appTypes = readText(
      path.join(process.cwd(), "src/native/audio/types.ts"),
    );
    const packageDefinitions = readText(
      path.join(pluginRoot, "src/audio/definitions.ts"),
    );
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    for (const method of nativeAudioMethods) {
      expect(appTypes).toContain(`${method}(`);
      expect(packageDefinitions).toContain(`${method}(`);
      expect(swift).toContain(`CAPPluginMethod(name: "${method}"`);
    }

    for (const eventName of nativeAudioEventNames) {
      expect(appTypes).toContain(`${eventName}:`);
      expect(packageDefinitions).toContain(`${eventName}:`);
      expect(swift).toContain(`notifyListeners("${eventName}"`);
    }

    for (const sourceKind of nativeAudioSourceKinds) {
      expect(appTypes).toContain(`kind: "${sourceKind}"`);
      expect(packageDefinitions).toContain(`kind: "${sourceKind}"`);
    }
  });

  it("enables iOS background audio and native audio session handling", () => {
    const infoPlist = readText(
      path.join(process.cwd(), "ios/App/App/Info.plist"),
    );
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    expect(infoPlist).toContain("<key>UIBackgroundModes</key>");
    expect(infoPlist).toContain("<string>audio</string>");
    expect(swift).toContain("AVAudioSession.sharedInstance()");
    expect(swift).toContain("setCategory(.playback");
    expect(swift).toContain("setActive(true)");
    expect(swift).toContain("AVAudioSession.interruptionNotification");
    expect(swift).toContain("AVAudioSession.routeChangeNotification");
    expect(swift).toContain("UIApplication.didEnterBackgroundNotification");
    expect(swift).toContain("UIApplication.willEnterForegroundNotification");
    expect(swift).toContain("UIApplication.didBecomeActiveNotification");
    expect(swift).toContain("handleAudioSessionInterruption");
    expect(swift).toContain("handleAudioSessionRouteChange");
  });

  it("updates iOS Now Playing metadata, artwork, and remote commands", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    for (const command of [
      "playCommand",
      "pauseCommand",
      "togglePlayPauseCommand",
      "nextTrackCommand",
      "previousTrackCommand",
      "changePlaybackPositionCommand",
    ]) {
      expect(swift).toContain(`commandCenter.${command}.isEnabled = true`);
    }

    for (const command of [
      '"play"',
      '"pause"',
      '"next"',
      '"previous"',
      '"seek"',
    ]) {
      expect(swift).toContain(`emitRemoteCommand(${command}`);
    }

    expect(swift).toContain("MPNowPlayingInfoCenter.default().nowPlayingInfo");
    expect(swift).toContain("MPMediaItemPropertyTitle");
    expect(swift).toContain("MPMediaItemPropertyArtist");
    expect(swift).toContain("MPMediaItemPropertyAlbumTitle");
    expect(swift).toContain("MPMediaItemPropertyPlaybackDuration");
    expect(swift).toContain("MPNowPlayingInfoPropertyElapsedPlaybackTime");
    expect(swift).toContain("MPNowPlayingInfoPropertyPlaybackRate");
    expect(swift).toContain("MPMediaItemArtwork");
    expect(swift).toContain("URLSession.shared.dataTask");
  });

  it("tracks radio sources and resets native state on clear", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    expect(swift).toContain('case "radio":');
    expect(swift).toContain('case "native-file":');
    expect(swift).toContain("Invalid radio stream URL.");
    expect(swift).toContain("Native cached audio file does not exist.");
    expect(swift).toContain("self.currentSourceKind = resolvedSource.kind");
    expect(swift).toContain("self.currentRadioId = resolvedSource.radioId");
    expect(swift).toContain("private func resetControlState()");
    expect(swift).toContain('repeatMode = "off"');
    expect(swift).toContain("shuffleEnabled = false");
    expect(swift).toContain("queueItemCount = 0");
    expect(swift).toContain("queueIndex = 0");
  });

  it("stores and resolves iOS native cached audio files", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    expect(swift).toContain("@objc func storeAudioFile");
    expect(swift).toContain("@objc func resolveAudioFile");
    expect(swift).toContain("@objc func getAudioFileSize");
    expect(swift).toContain("@objc func deleteAudioFile");
    expect(swift).toContain("@objc func clearAudioFiles");
    expect(swift).toContain("Application Support directory");
    expect(swift).toContain('.appendingPathComponent("AudioCache"');
    expect(swift).toContain("Data(base64Encoded: dataBase64)");
    expect(swift).toContain("isExcludedFromBackup = true");
    expect(swift).toContain("NativeCachedAudioFileMetadata");
    expect(swift).toContain("fileExtension(for: contentType)");
    expect(swift).toContain("jsObject(from file: NativeCachedAudioFile)");
  });

  it("guards native lifecycle events against stale source changes", () => {
    const swift = readText(
      path.join(
        pluginRoot,
        "ios/Sources/AonsokuNativePlugin/Audio/AonsokuNativeAudioPlugin.swift",
      ),
    );

    expect(swift).toContain("private var currentRequestId: String?");
    expect(swift).toContain("private var playbackGeneration = 0");
    expect(swift).toContain('let requestId = call.getString("requestId")');
    expect(swift).toContain("self.currentRequestId = requestId");
    expect(swift).toContain("generation: generation, requestId: requestId");
    expect(swift).toContain("private func isCurrentPlayback(generation: Int)");
    expect(swift).toContain(
      "guard isCurrentPlayback(item: item, generation: generation)",
    );
    expect(swift).toContain("player?.removeTimeObserver(token)");
    expect(swift).toContain("timeObserverToken = nil");
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
