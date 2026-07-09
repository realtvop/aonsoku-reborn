import { EventEmitter } from "node:events";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type {
  MpvPlayer,
  MpvPlayerEvent,
  MpvPlayerEventListener,
  MpvPlayerInitializeOptions,
  MpvPropertyFormat,
  MpvPropertyValue,
} from "./mpv-player";

export const LIBMPV_ADDON_FILENAME = "aonsoku_libmpv.node";
export const LIBMPV_RESOURCE_DIRECTORY = "native-audio";
export const LIBMPV_RUNTIME_MANIFEST = "manifest.json";

export interface LibMpvRuntimeManifest {
  schemaVersion: 1;
  platform: NodeJS.Platform | string;
  arch: string;
  platformKey: string;
  addon: string;
  libraries?: string[];
  dependencies?: string[];
  requiredFiles?: string[];
  generatedAt?: string;
}

export interface NativeMpvPlayerBinding {
  setEventCallback(listener: (event: MpvPlayerEvent) => void): void;
  initialize(options: MpvPlayerInitializeOptions): void;
  command(args: readonly string[]): void;
  setProperty(name: string, value: MpvPropertyValue): void;
  observeProperty(name: string, format: MpvPropertyFormat): void;
  updateSystemMediaSession(
    metadata: NativeAudioMetadata,
    options: {
      state: "playing" | "paused" | "stopped";
      position: number;
      duration: number;
    },
  ): void;
  clearSystemMediaSession(): void;
  destroy(): void;
}

export interface LibMpvNativeBinding {
  createPlayer(): NativeMpvPlayerBinding;
  runtimeInfo?(): Record<string, string>;
}

export interface LibMpvBindingLoadOptions {
  addonPath?: string;
  require?: NodeJS.Require;
  exists?: (path: string) => boolean;
  readTextFile?: (path: string) => string;
  resourcesPath?: string;
  cwd?: string;
  platform?: NodeJS.Platform;
  arch?: string;
}

export class LibMpvBindingLoadError extends Error {
  readonly code = "libmpv-addon-unavailable";
  readonly searchedPaths: string[];
  readonly platformKey: string;

  constructor(searchedPaths: string[], platformKey: string, cause?: unknown) {
    const causeMessage =
      cause instanceof Error ? ` Last error: ${cause.message}` : "";
    super(
      [
        "Unable to load the Aonsoku libmpv native addon.",
        "Run pnpm native-audio:build, set AONSOKU_LIBMPV_ADDON_PATH,",
        "or package the addon under resources/native-audio/<platform>-<arch>.",
        `Searched: ${searchedPaths.join(", ") || "(none)"}.`,
        `Platform key: ${platformKey}.`,
        causeMessage,
      ].join(" "),
    );
    this.name = "LibMpvBindingLoadError";
    this.searchedPaths = searchedPaths;
    this.platformKey = platformKey;
  }
}

export class LibMpvRuntimeManifestError extends Error {
  readonly code = "libmpv-runtime-incomplete";
  readonly manifestPath: string;
  readonly missingFiles: string[];

  constructor(manifestPath: string, missingFiles: string[]) {
    super(
      [
        "The packaged libmpv runtime manifest is incomplete.",
        `Manifest: ${manifestPath}.`,
        `Missing files: ${missingFiles.join(", ")}.`,
      ].join(" "),
    );
    this.name = "LibMpvRuntimeManifestError";
    this.manifestPath = manifestPath;
    this.missingFiles = missingFiles;
  }
}

export function loadLibMpvBinding(
  options: LibMpvBindingLoadOptions = {},
): LibMpvNativeBinding {
  const requireNative = options.require ?? createRequire(import.meta.url);
  const exists = options.exists ?? existsSync;
  const searchedPaths: string[] = [];
  let lastError: unknown;
  const platformKey = libMpvPlatformKey(options.platform, options.arch);

  for (const candidate of getLibMpvAddonCandidates(options)) {
    searchedPaths.push(candidate);
    if (!exists(candidate)) continue;

    try {
      validateRuntimeManifest(path.dirname(candidate), options);
      configureLibMpvRuntimeSearchPath(path.dirname(candidate), options);

      return requireNative(candidate) as LibMpvNativeBinding;
    } catch (error) {
      lastError = error;
    }
  }

  throw new LibMpvBindingLoadError(searchedPaths, platformKey, lastError);
}

export function createNativeMpvPlayer(
  binding: LibMpvNativeBinding = loadLibMpvBinding(),
): MpvPlayer {
  return new NativeMpvPlayerAdapter(binding.createPlayer());
}

export function getLibMpvAddonCandidates(
  options: LibMpvBindingLoadOptions = {},
): string[] {
  const candidates = [
    options.addonPath,
    process.env.AONSOKU_LIBMPV_ADDON_PATH,
    packagedAddonPath(options),
    devResourceAddonPath(options),
    sourceBuildAddonPath(),
  ];

  return [
    ...new Set(
      candidates.filter(isPresent).map((candidate) => path.resolve(candidate)),
    ),
  ];
}

export function libMpvPlatformKey(
  platform: NodeJS.Platform = process.platform,
  arch: string = process.arch,
): string {
  return `${platform}-${arch}`;
}

export function libMpvRuntimeDirectory(
  root: string,
  options: Pick<LibMpvBindingLoadOptions, "platform" | "arch"> = {},
): string {
  return path.join(
    root,
    LIBMPV_RESOURCE_DIRECTORY,
    libMpvPlatformKey(options.platform, options.arch),
  );
}

export function libMpvRuntimeAddonPath(
  root: string,
  options: Pick<LibMpvBindingLoadOptions, "platform" | "arch"> = {},
): string {
  return path.join(
    libMpvRuntimeDirectory(root, options),
    LIBMPV_ADDON_FILENAME,
  );
}

class NativeMpvPlayerAdapter implements MpvPlayer {
  readonly #native: NativeMpvPlayerBinding;
  readonly #events = new EventEmitter();

  constructor(native: NativeMpvPlayerBinding) {
    this.#native = native;
    this.#native.setEventCallback((event) => {
      this.#events.emit("event", event);
    });
  }

  initialize(options: MpvPlayerInitializeOptions): void {
    this.#native.initialize(options);
  }

  command(args: readonly string[]): void {
    this.#native.command(args);
  }

  setProperty(name: string, value: MpvPropertyValue): void {
    this.#native.setProperty(name, value);
  }

  observeProperty(name: string, format: MpvPropertyFormat): void {
    this.#native.observeProperty(name, format);
  }

  updateSystemMediaSession(
    metadata: NativeAudioMetadata,
    options: {
      state: "playing" | "paused" | "stopped";
      position: number;
      duration: number;
    },
  ): void {
    this.#native.updateSystemMediaSession(metadata, options);
  }

  clearSystemMediaSession(): void {
    this.#native.clearSystemMediaSession();
  }

  onEvent(listener: MpvPlayerEventListener): () => void {
    this.#events.on("event", listener);

    return () => {
      this.#events.off("event", listener);
    };
  }

  destroy(): void {
    this.#native.destroy();
  }
}

function packagedAddonPath(
  options: LibMpvBindingLoadOptions,
): string | undefined {
  const processResourcesPath =
    typeof process.resourcesPath === "string"
      ? process.resourcesPath
      : undefined;
  const resourcesPath = options.resourcesPath ?? processResourcesPath;
  if (!resourcesPath) return undefined;

  return libMpvRuntimeAddonPath(resourcesPath, options);
}

function devResourceAddonPath(
  options: LibMpvBindingLoadOptions,
): string | undefined {
  const cwd = options.cwd ?? process.cwd();

  return libMpvRuntimeAddonPath(path.join(cwd, "resources"), options);
}

function sourceBuildAddonPath(): string {
  return path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "libmpv",
    "build",
    "Release",
    LIBMPV_ADDON_FILENAME,
  );
}

function isPresent(value: string | undefined): value is string {
  return typeof value === "string" && value.length > 0;
}

function validateRuntimeManifest(
  runtimeDirectory: string,
  options: LibMpvBindingLoadOptions,
): void {
  const exists = options.exists ?? existsSync;
  const manifestPath = path.join(runtimeDirectory, LIBMPV_RUNTIME_MANIFEST);
  if (!exists(manifestPath)) return;

  const manifest = readRuntimeManifest(manifestPath, options);
  const requiredFiles = manifest.requiredFiles ?? [
    manifest.addon,
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ];
  const missingFiles = requiredFiles.filter(
    (file) => !exists(path.join(runtimeDirectory, file)),
  );

  if (missingFiles.length > 0) {
    throw new LibMpvRuntimeManifestError(manifestPath, missingFiles);
  }
}

function readRuntimeManifest(
  manifestPath: string,
  options: LibMpvBindingLoadOptions,
): LibMpvRuntimeManifest {
  const readTextFile =
    options.readTextFile ??
    ((filePath: string) => readFileSync(filePath, "utf8"));
  const manifest = JSON.parse(
    readTextFile(manifestPath),
  ) as Partial<LibMpvRuntimeManifest>;

  return {
    schemaVersion: 1,
    platform: manifest.platform ?? process.platform,
    arch: manifest.arch ?? process.arch,
    platformKey:
      manifest.platformKey ??
      libMpvPlatformKey(
        manifest.platform as NodeJS.Platform | undefined,
        manifest.arch,
      ),
    addon: manifest.addon ?? LIBMPV_ADDON_FILENAME,
    libraries: manifest.libraries ?? [],
    dependencies: manifest.dependencies ?? [],
    requiredFiles: manifest.requiredFiles,
    generatedAt: manifest.generatedAt,
  };
}

const configuredRuntimeDirectories = new Set<string>();

function configureLibMpvRuntimeSearchPath(
  runtimeDirectory: string,
  options: LibMpvBindingLoadOptions,
): void {
  const platform = options.platform ?? process.platform;
  if (platform !== "win32") return;
  if (configuredRuntimeDirectories.has(runtimeDirectory)) return;

  process.env.PATH = [runtimeDirectory, process.env.PATH ?? ""]
    .filter(Boolean)
    .join(platform === "win32" ? ";" : path.delimiter);
  configuredRuntimeDirectories.add(runtimeDirectory);
}
