import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { projectPlaybackProgress } from "@/coordination/progress";
import { useCoordinationStore } from "@/coordination/store";
import type { PlaybackSnapshot } from "@/coordination/types";
import { subsonic } from "@/service/subsonic";
import { usePlayerStore } from "@/store/player.store";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";
import { clampProgress } from "@/utils/duration";

function repeatModeToLoopState(mode: PlaybackSnapshot["repeat"]): LoopState {
  switch (mode) {
    case "all":
      return LoopState.All;
    case "one":
      return LoopState.One;
    case "off":
      return LoopState.Off;
  }
}

function fallbackRemoteSongById(id: string, duration = 0): ISong {
  return {
    id,
    parent: "",
    isDir: false,
    title: id,
    album: "",
    artist: "",
    track: 0,
    year: 0,
    genre: undefined,
    coverArt: "",
    size: 0,
    contentType: "",
    suffix: "",
    duration,
    bitRate: 0,
    path: "",
    playCount: 0,
    discNumber: 0,
    created: "remote",
    albumId: "",
    artistId: undefined,
    type: "remote",
    isVideo: false,
    played: undefined,
    bpm: 0,
    starred: undefined,
    comment: "",
    sortName: id,
    mediaType: "song",
    musicBrainzId: "",
    genres: [],
    replayGain: {
      trackGain: 0,
      trackPeak: 1,
      albumGain: 0,
      albumPeak: 1,
    },
    channelCount: undefined,
    samplingRate: undefined,
    bitDepth: undefined,
    moods: undefined,
    artists: undefined,
    displayArtist: undefined,
    albumArtists: undefined,
    displayAlbumArtist: undefined,
    contributors: undefined,
    displayComposer: undefined,
    explicitStatus: undefined,
  };
}

function fallbackRemoteSong(snapshot: PlaybackSnapshot): ISong {
  return fallbackRemoteSongById(snapshot.songId, snapshot.durationSeconds);
}

export function useRemotePlaybackProjection() {
  const isRemoteActive = usePlayerStore((s) => s.remoteControl.active);
  const controlledDeviceId = useCoordinationStore((s) => s.controlledDeviceId);
  const snapshotData = useCoordinationStore((s) =>
    controlledDeviceId ? s.deviceSnapshots[controlledDeviceId] : undefined,
  );
  const snapshot = snapshotData?.snapshot ?? null;

  const { data: remoteSong } = useQuery({
    queryKey: ["song-info", snapshot?.songId],
    queryFn: async () => {
      if (!snapshot?.songId) return null;
      return subsonic.songs.getSong(snapshot.songId);
    },
    enabled: isRemoteActive && !!snapshot?.songId,
    staleTime: Infinity,
  });

  const queueSongIds = useMemo(() => {
    if (!isRemoteActive || !snapshot) return [];
    return Array.from(
      new Set([
        snapshot.songId,
        ...snapshot.contextQueue,
        ...snapshot.userQueue,
      ]),
    ).filter(Boolean);
  }, [isRemoteActive, snapshot]);

  const { data: remoteQueueSongs } = useQuery({
    queryKey: ["remote-queue-songs", queueSongIds],
    queryFn: async () => {
      const entries = await Promise.all(
        queueSongIds.map(async (id) => [id, await subsonic.songs.getSong(id)]),
      );
      return new Map(entries.filter(([, song]) => !!song) as [string, ISong][]);
    },
    enabled: queueSongIds.length > 0,
    staleTime: Infinity,
  });

  return useMemo(() => {
    if (!isRemoteActive || !snapshot || !snapshotData) {
      return {
        active: false,
        snapshot: null,
        song: null,
        isPlaying: false,
        progress: 0,
        duration: 0,
        volume: null as number | null,
        isShuffleActive: false,
        loopState: LoopState.Off,
        hasPrev: false,
        hasNext: false,
        contextSongs: [] as ISong[],
        contextIndex: 0,
        userQueueSongs: [] as ISong[],
        sourceName: null as string | null,
        targetDeviceId: null as string | null,
        expectedGeneration: null as number | null,
      };
    }

    const song = remoteSong ?? fallbackRemoteSong(snapshot);
    const remoteSongById = (id: string) =>
      remoteQueueSongs?.get(id) ??
      (id === song.id ? song : fallbackRemoteSongById(id));
    const contextSongs = snapshot.contextQueue.map(remoteSongById);
    const userQueueSongs = snapshot.userQueue.map(remoteSongById);
    const progress = projectPlaybackProgress({
      snapshot,
      serverTime: snapshotData.serverTime,
      lastConfirmedAt: snapshotData.lastConfirmedAt,
      receivedAtPerformance: snapshotData.receivedAtPerformance,
    });

    const contextIndex = snapshot.contextIndex ?? 0;
    const hasContextPrevious = contextIndex > 0;
    const hasContextNext =
      snapshot.contextIndex === null
        ? snapshot.contextQueue.length > 1
        : contextIndex < snapshot.contextQueue.length - 1;

    return {
      active: true,
      snapshot,
      song,
      isPlaying: snapshot.isPlaying,
      progress,
      duration: snapshot.durationSeconds,
      volume:
        typeof snapshot.volume === "number"
          ? Math.round(snapshot.volume * 100)
          : null,
      isShuffleActive: snapshot.shuffle,
      loopState: repeatModeToLoopState(snapshot.repeat),
      hasPrev: progress > 3 || hasContextPrevious,
      hasNext: hasContextNext || snapshot.userQueue.length > 0,
      contextSongs,
      contextIndex,
      userQueueSongs,
      sourceName: snapshot.sourceName,
      targetDeviceId: controlledDeviceId,
      expectedGeneration: snapshotData.generation,
    };
  }, [
    controlledDeviceId,
    isRemoteActive,
    remoteQueueSongs,
    remoteSong,
    snapshot,
    snapshotData,
  ]);
}

export function useSmoothRemoteProgress({
  active,
  isPlaying,
  progress,
  duration,
}: {
  active: boolean;
  isPlaying: boolean;
  progress: number;
  duration: number;
}) {
  const [displayProgress, setDisplayProgress] = useState(progress);

  useEffect(() => {
    setDisplayProgress(progress);
  }, [progress]);

  useEffect(() => {
    if (!active || !isPlaying) return;

    let lastTick = performance.now();
    const interval = window.setInterval(() => {
      const now = performance.now();
      const elapsedSeconds = (now - lastTick) / 1000;
      lastTick = now;
      setDisplayProgress((current) =>
        clampProgress(current + elapsedSeconds, duration),
      );
    }, 250);

    return () => window.clearInterval(interval);
  }, [active, duration, isPlaying]);

  return displayProgress;
}
