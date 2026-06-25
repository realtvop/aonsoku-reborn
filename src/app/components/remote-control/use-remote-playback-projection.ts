import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import { projectPlaybackProgress } from "@/coordination/progress";
import { useCoordinationStore } from "@/coordination/store";
import type { PlaybackSnapshot } from "@/coordination/types";
import { subsonic } from "@/service/subsonic";
import { usePlayerStore } from "@/store/player.store";
import { LoopState } from "@/types/playerContext";
import type { ISong } from "@/types/responses/song";

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

function fallbackRemoteSong(snapshot: PlaybackSnapshot): ISong {
  return {
    id: snapshot.songId,
    parent: "",
    isDir: false,
    title: snapshot.songId,
    album: "",
    artist: "",
    track: 0,
    year: 0,
    genre: undefined,
    coverArt: "",
    size: 0,
    contentType: "",
    suffix: "",
    duration: snapshot.durationSeconds,
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
    sortName: snapshot.songId,
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

export function useRemotePlaybackProjection() {
  const isRemoteActive = usePlayerStore((s) => s.remoteControl.active);
  const controlledDeviceId = useCoordinationStore(
    (s) => s.controlledDeviceId,
  );
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
      };
    }

    const song = remoteSong ?? fallbackRemoteSong(snapshot);
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
    };
  }, [isRemoteActive, remoteSong, snapshot, snapshotData]);
}
