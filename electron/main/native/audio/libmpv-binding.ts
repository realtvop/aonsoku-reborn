import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
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

const ADDON_FILENAME = "aonsoku_libmpv.node";

interface ElectronProcess extends NodeJS.Process {
  resourcesPath?: string;
}

export interface NativeMpvPlayerBinding {
  setEventCallback(listener: (event: MpvPlayerEvent) => void): void;
  initialize(options: MpvPlayerInitializeOptions): void;
  command(args: readonly string[]): void;
  setProperty(name: string, value: MpvPropertyValue): void;
  observeProperty(name: string, format: MpvPropertyFormat): void;
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
  resourcesPath?: string;
  cwd?: string;
}

export class LibMpvBindingLoadError extends Error {
  readonly code = "libmpv-addon-unavailable";
  readonly searchedPaths: string[];

  constructor(searchedPaths: string[], cause?: unknown) {
    const causeMessage =
      cause instanceof Error ? ` Last error: ${cause.message}` : "";
    super(
      [
        "Unable to load the Aonsoku libmpv native addon.",
        "Run pnpm native-audio:build, set AONSOKU_LIBMPV_ADDON_PATH,",
        "or package the addon under resources/native-audio/<platform>-<arch>.",
        `Searched: ${searchedPaths.join(", ") || "(none)"}.`,
        causeMessage,
      ].join(" "),
    );
    this.name = "LibMpvBindingLoadError";
    this.searchedPaths = searchedPaths;
  }
}

export function loadLibMpvBinding(
  options: LibMpvBindingLoadOptions = {},
): LibMpvNativeBinding {
  const requireNative = options.require ?? createRequire(import.meta.url);
  const exists = options.exists ?? existsSync;
  const searchedPaths: string[] = [];
  let lastError: unknown;

  for (const candidate of getLibMpvAddonCandidates(options)) {
    searchedPaths.push(candidate);
    if (!exists(candidate)) continue;

    try {
      return requireNative(candidate) as LibMpvNativeBinding;
    } catch (error) {
      lastError = error;
    }
  }

  throw new LibMpvBindingLoadError(searchedPaths, lastError);
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
    ...new Set(candidates.filter(isPresent).map((candidate) =>
      path.resolve(candidate),
    )),
  ];
}

export function libMpvPlatformKey(
  platform: NodeJS.Platform = process.platform,
  arch: string = process.arch,
): string {
  return `${platform}-${arch}`;
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
  const resourcesPath =
    options.resourcesPath ?? (process as ElectronProcess).resourcesPath;
  if (!resourcesPath) return undefined;

  return path.join(
    resourcesPath,
    "native-audio",
    libMpvPlatformKey(),
    ADDON_FILENAME,
  );
}

function devResourceAddonPath(
  options: LibMpvBindingLoadOptions,
): string | undefined {
  const cwd = options.cwd ?? process.cwd();

  return path.join(
    cwd,
    "resources",
    "native-audio",
    libMpvPlatformKey(),
    ADDON_FILENAME,
  );
}

function sourceBuildAddonPath(): string {
  return path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "libmpv",
    "build",
    "Release",
    ADDON_FILENAME,
  );
}

function isPresent(value: string | undefined): value is string {
  return typeof value === "string" && value.length > 0;
}
