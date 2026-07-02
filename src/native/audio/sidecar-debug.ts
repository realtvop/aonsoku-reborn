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
  smokeStream: (
    url: string,
    options?: AudioSidecarDebugSmokeOptions,
  ) => Promise<AudioSidecarDebugSmokeResult>;
  smokeFile: (
    uri: string,
    options?: AudioSidecarDebugSmokeOptions,
  ) => Promise<AudioSidecarDebugSmokeResult>;
  dispose: () => Promise<void>;
};

export type AudioSidecarDebugLoadOptions = Omit<
  Partial<AudioSidecarLoadOptions>,
  "source"
>;

export type AudioSidecarDebugSmokeOptions = AudioSidecarDebugLoadOptions & {
  seekTo?: number;
};

export type AudioSidecarDebugSmokeResult = {
  events: AudioSidecarEvent[];
  errors: AudioSidecarError[];
  summary: AudioSidecarDebugSmokeSummary;
};

export type AudioSidecarDebugSmokeSummary = {
  ok: boolean;
  eventNames: string[];
  playbackStates: string[];
  latestProgress: {
    currentTime: number;
    duration: number;
  } | null;
  errorMessages: string[];
};

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

  const harness: AudioSidecarDebugHarness = {
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
    smokeStream: (url, options = {}) =>
      runSmokeSequence(harness, {
        ...options,
        source: {
          kind: "stream",
          url,
        },
      }),
    smokeFile: (uri, options = {}) =>
      runSmokeSequence(harness, {
        ...options,
        source: {
          kind: "native-file",
          uri,
        },
      }),
    dispose: async () => {
      removeEventListener();
      removeErrorListener();
      await audioSidecar.stop();
    },
  };

  return harness;
}

async function runSmokeSequence(
  harness: Pick<
    AudioSidecarDebugHarness,
    "errors" | "events" | "load" | "pause" | "play" | "seek" | "stop"
  >,
  options: AudioSidecarDebugLoadOptions & {
    source: AudioSidecarLoadOptions["source"];
    seekTo?: number;
  },
): Promise<AudioSidecarDebugSmokeResult> {
  const startedAtEvent = harness.events.length;
  const startedAtError = harness.errors.length;
  const { seekTo = 1, ...loadOptions } = options;

  await harness.load({
    ...loadOptions,
    autoplay: loadOptions.autoplay ?? false,
  });
  await harness.play();
  await harness.seek(seekTo);
  await harness.pause();
  await harness.play();
  await harness.stop();

  const events = harness.events.slice(startedAtEvent);
  const errors = harness.errors.slice(startedAtError);

  return {
    events,
    errors,
    summary: summarizeSmokeResult(events, errors),
  };
}

function summarizeSmokeResult(
  events: AudioSidecarEvent[],
  errors: AudioSidecarError[],
): AudioSidecarDebugSmokeSummary {
  const playbackStates: string[] = [];
  let latestProgress: AudioSidecarDebugSmokeSummary["latestProgress"] = null;

  for (const { event, payload } of events) {
    if (event === "playbackStateChanged") {
      playbackStates.push(payload.state);
    }
    if (event === "progress") {
      latestProgress = {
        currentTime: payload.currentTime,
        duration: payload.duration,
      };
    }
  }

  return {
    ok: errors.length === 0,
    eventNames: events.map(({ event }) => event),
    playbackStates,
    latestProgress,
    errorMessages: errors.map(({ message }) => message),
  };
}
