type AudioSidecarApi = Window["api"]["audioSidecar"];
type AudioSidecarLoadOptions = Parameters<AudioSidecarApi["load"]>[0];
type AudioSidecarSeekOptions = Parameters<AudioSidecarApi["seek"]>[0];
type AudioSidecarEvent = Parameters<
  Parameters<AudioSidecarApi["onEvent"]>[0]
>[0];
type AudioSidecarError = Parameters<
  Parameters<AudioSidecarApi["onError"]>[0]
>[0];

export type AudioSidecarDebugHarness = {
  readonly events: AudioSidecarEvent[];
  readonly errors: AudioSidecarError[];
  start: () => Promise<void>;
  load: (options: AudioSidecarLoadOptions) => Promise<void>;
  loadStream: (
    url: string,
    options?: AudioSidecarDebugLoadOptions,
  ) => Promise<void>;
  loadFile: (
    uri: string,
    options?: AudioSidecarDebugLoadOptions,
  ) => Promise<void>;
  play: () => Promise<void>;
  pause: () => Promise<void>;
  stop: () => Promise<void>;
  seek: (position: number | AudioSidecarSeekOptions) => Promise<void>;
  dispose: () => Promise<void>;
};

export type AudioSidecarDebugLoadOptions = Omit<
  Partial<AudioSidecarLoadOptions>,
  "source"
>;

export type InstallAudioSidecarDebugOptions = {
  isDev: boolean;
  log?: Pick<Console, "info" | "warn">;
};

declare global {
  interface Window {
    aonsokuAudioSidecarDebug?: AudioSidecarDebugHarness;
  }
}

export async function installAudioSidecarDebugHarness(
  target: Window,
  options: InstallAudioSidecarDebugOptions,
): Promise<AudioSidecarDebugHarness | null> {
  if (!options.isDev) return null;

  const audioSidecar = target.api?.audioSidecar;
  if (!audioSidecar) return null;

  const isAvailable = await audioSidecar.isAvailable();
  if (!isAvailable) return null;

  const harness = createAudioSidecarDebugHarness(audioSidecar);
  target.aonsokuAudioSidecarDebug = harness;
  options.log?.info(
    "[AudioSidecarDebug] installed at window.aonsokuAudioSidecarDebug",
  );

  return harness;
}

export function createAudioSidecarDebugHarness(
  audioSidecar: AudioSidecarApi,
): AudioSidecarDebugHarness {
  const events: AudioSidecarEvent[] = [];
  const errors: AudioSidecarError[] = [];

  const removeEventListener = audioSidecar.onEvent((event) => {
    events.push(event);
  });
  const removeErrorListener = audioSidecar.onError((error) => {
    errors.push(error);
  });

  return {
    events,
    errors,
    start: () => audioSidecar.start(),
    load: (options) => audioSidecar.load(options),
    loadStream: (url, options = {}) =>
      audioSidecar.load({
        ...options,
        source: {
          kind: "stream",
          url,
        },
      }),
    loadFile: (uri, options = {}) =>
      audioSidecar.load({
        ...options,
        source: {
          kind: "native-file",
          uri,
        },
      }),
    play: () => audioSidecar.play(),
    pause: () => audioSidecar.pause(),
    stop: () => audioSidecar.stopPlayback(),
    seek: (position) =>
      audioSidecar.seek(
        typeof position === "number"
          ? {
              position,
            }
          : position,
      ),
    dispose: async () => {
      removeEventListener();
      removeErrorListener();
      await audioSidecar.stop();
    },
  };
}
