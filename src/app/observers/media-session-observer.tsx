import { useCallback, useEffect, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { useCoordinationStore } from "@/coordination/store";
import { projectPlaybackProgress } from "@/coordination/progress";
import { useBackgroundPlayback } from "@/app/hooks/use-background-playback";
import { getNativeAudioPluginAvailability } from "@/native/audio/facade";
import { subsonic } from "@/service/subsonic";
import {
  usePlayerCurrentSong,
  usePlayerCurrentSongIndex,
  usePlayerDuration,
  usePlayerIsPlaying,
  usePlayerIsTransitioning,
  usePlayerMediaType,
  usePlayerProgress,
  usePlayerStore,
} from "@/store/player.store";
import { appName } from "@/utils/appName";
import { getCoverArtUrlFromSongPreference } from "@/utils/coverArt";
import { clampProgress, isValidDuration } from "@/utils/duration";
import { logger } from "@/utils/logger";
import { manageMediaSession } from "@/utils/setMediaSession";

function useRemoteSongInfo(songId: string | undefined) {
  return useQuery({
    queryKey: ["song-info", songId],
    queryFn: async () => {
      if (!songId) return null;
      return subsonic.songs.getSong(songId);
    },
    enabled: !!songId,
    staleTime: Infinity,
  });
}

export function MediaSessionObserver() {
  const { t } = useTranslation();
  useBackgroundPlayback();
  const isPlaying = usePlayerIsPlaying();
  const isTransitioning = usePlayerIsTransitioning();
  const { isRadio, isSong } = usePlayerMediaType();
  const storeCurrentSong = usePlayerCurrentSong();
  const currentSongIndex = usePlayerCurrentSongIndex();
  const radioList = usePlayerStore((s) => s.songlist.radioList);
  const progress = usePlayerProgress();
  const currentDuration = usePlayerDuration();
  const radioLabel = t("radios.label");
  const isRemoteActive = usePlayerStore((s) => s.remoteControl.active);
  const controlledDeviceId = useCoordinationStore(
    (s) => s.controlledDeviceId,
  );
  const remoteSnapshotData = useCoordinationStore((s) =>
    controlledDeviceId ? s.deviceSnapshots[controlledDeviceId] : undefined,
  );
  const remoteSnapshot = remoteSnapshotData?.snapshot ?? null;
  const { data: remoteSong } = useRemoteSongInfo(remoteSnapshot?.songId);

  const lastMetadataRef = useRef<string>("");

  const song =
    isRemoteActive && remoteSnapshot?.songId
      ? {
          id: remoteSnapshot.songId,
          title: remoteSong?.title ?? remoteSnapshot.songId,
          artist: remoteSong?.artist ?? "",
          album: remoteSong?.album ?? "",
          coverArt: remoteSong?.coverArt,
          albumId: remoteSong?.albumId,
          duration: remoteSnapshot.durationSeconds,
        }
      : storeCurrentSong;
  const radio = radioList[currentSongIndex] ?? null;

  const hasNothingPlaying = isRemoteActive
    ? !remoteSnapshot || !remoteSnapshot.songId
    : !storeCurrentSong && radioList.length === 0;
  const nativeRemoteProjectionActiveRef = useRef(false);

  const resetAppTitle = useCallback(() => {
    document.title = appName;
  }, []);

  useEffect(() => {
    logger.info(
      `[MediaSessionObserver] handlers | remoteControl=${isRemoteActive}`,
    );
    manageMediaSession.setHandlers();
  }, [isRemoteActive]);

  useEffect(() => {
    logger.info(
      `[MediaSessionObserver] isPlaying=${isPlaying} | isTransitioning=${isTransitioning} | isSong=${isSong} | isRadio=${isRadio} | songId=${song?.id} | isRemote=${isRemoteActive} | hasNothingPlaying=${hasNothingPlaying}`,
    );

    const effectiveIsPlaying = isRemoteActive
      ? (remoteSnapshot?.isPlaying ?? false)
      : isPlaying;

    if (isTransitioning) {
      logger.info(
        "[MediaSessionObserver → transitioning] | keeping existing metadata, only updating playback state",
      );
      manageMediaSession.ensurePlaybackStatePlaying();
      return;
    }

    manageMediaSession.setPlaybackState(effectiveIsPlaying);

    if (hasNothingPlaying) {
      logger.info(
        "[MediaSessionObserver → nothingPlaying] | calling removeMediaSession",
      );
      manageMediaSession.removeMediaSession();
      resetAppTitle();
      lastMetadataRef.current = "";
      return;
    }

    let title = "";
    let metadataKey = "";

    if (isRadio && radio) {
      title = `${radioLabel} - ${radio.name} | Aonsoku`;
      metadataKey = `radio:${radio.name}`;

      if (lastMetadataRef.current !== metadataKey) {
        logger.info(
          `[MediaSessionObserver → setRadioMediaSession] | name=${radio.name}`,
        );
        manageMediaSession.setRadioMediaSession(radioLabel, radio.name);
        lastMetadataRef.current = metadataKey;
      } else {
        logger.info(
          `[MediaSessionObserver → metadataUnchanged] | name=${radio.name}`,
        );
      }
    } else if ((isSong || isRemoteActive) && song) {
      title = `${song.title} - ${song.artist} | Aonsoku`;
      metadataKey = `song:${song.id || song.title}`;

      const metadataChanged = lastMetadataRef.current !== metadataKey;
      if (metadataChanged) {
        logger.info(
          `[MediaSessionObserver → setMediaSession] | songId=${song.id} | title="${song.title}"`,
        );
        manageMediaSession.setMediaSession(song);
        lastMetadataRef.current = metadataKey;
      } else {
        logger.info(
          `[MediaSessionObserver → metadataUnchanged] | songId=${song.id}`,
        );
      }
    }

    if (!effectiveIsPlaying) {
      resetAppTitle();
    } else if (title) {
      document.title = title;
    }
  }, [
    hasNothingPlaying,
    isPlaying,
    isRadio,
    isSong,
    isTransitioning,
    isRemoteActive,
    radio,
    radioLabel,
    remoteSnapshot,
    song,
    resetAppTitle,
  ]);

  const lastPositionStateRef = useRef({
    progress: -1,
    timestamp: 0,
    isPlaying: false,
    songId: "",
  });

  useEffect(() => {
    const effectiveIsPlaying = isRemoteActive
      ? (remoteSnapshot?.isPlaying ?? false)
      : isPlaying;

    if (hasNothingPlaying || !song) {
      return;
    }

    const duration = isRemoteActive ? (song.duration ?? 0) : currentDuration;

    if (!isValidDuration(duration)) {
      return;
    }

    const effectiveProgress =
      isRemoteActive && remoteSnapshotData
        ? projectPlaybackProgress({
            snapshot: remoteSnapshotData.snapshot,
            serverTime: remoteSnapshotData.serverTime,
            lastConfirmedAt: remoteSnapshotData.lastConfirmedAt,
            receivedAtPerformance: remoteSnapshotData.receivedAtPerformance,
          })
        : progress;

    const songId =
      (song as { id?: string })?.id || (song as { title: string }).title;
    const now = Date.now();
    const lastState = lastPositionStateRef.current;

    let shouldUpdate = false;

    if (songId !== lastState.songId) {
      shouldUpdate = true;
    } else if (effectiveIsPlaying !== lastState.isPlaying) {
      shouldUpdate = true;
    } else {
      const elapsedSeconds = (now - lastState.timestamp) / 1000;
      const expectedProgress = lastState.isPlaying
        ? lastState.progress + elapsedSeconds
        : lastState.progress;

      if (Math.abs(effectiveProgress - expectedProgress) > 2) {
        shouldUpdate = true;
      }
    }

    if (shouldUpdate) {
      const clampedProgress = clampProgress(effectiveProgress, duration);
      logger.info(
        `[MediaSessionObserver.positionState] songId=${songId} | duration=${duration} | position=${effectiveProgress} | isPlaying=${effectiveIsPlaying} | updateReason=${songId !== lastState.songId ? "songChanged" : effectiveIsPlaying !== lastState.isPlaying ? "playStateChanged" : "drift>2s"}`,
      );
      manageMediaSession.setPositionState(duration, clampedProgress);

      lastPositionStateRef.current = {
        progress: effectiveProgress,
        timestamp: now,
        isPlaying: effectiveIsPlaying,
        songId,
      };
    }
  }, [
    progress,
    isPlaying,
    isRemoteActive,
    hasNothingPlaying,
    song,
    currentDuration,
    remoteSnapshot,
    remoteSnapshotData,
  ]);

  useEffect(() => {
    const availability = getNativeAudioPluginAvailability();
    if (!availability.available) return;

    const plugin = availability.plugin;
    if (!isRemoteActive || hasNothingPlaying || !song || !remoteSnapshotData) {
      if (nativeRemoteProjectionActiveRef.current) {
        nativeRemoteProjectionActiveRef.current = false;
        plugin.clearRemotePlaybackState().catch((error) => {
          logger.info("[MediaSessionObserver.nativeRemoteClear] failed", error);
        });
      }
      return;
    }

    const duration = song.duration ?? remoteSnapshotData.snapshot.durationSeconds;
    const position = projectPlaybackProgress({
      snapshot: remoteSnapshotData.snapshot,
      serverTime: remoteSnapshotData.serverTime,
      lastConfirmedAt: remoteSnapshotData.lastConfirmedAt,
      receivedAtPerformance: remoteSnapshotData.receivedAtPerformance,
    });
    const artworkUrl =
      song.coverArt || song.albumId
        ? getCoverArtUrlFromSongPreference({
            coverArt: song.coverArt,
            coverArtType: "song",
            albumId: song.albumId,
            size: "300",
          })
        : undefined;

    nativeRemoteProjectionActiveRef.current = true;
    plugin
      .updateRemotePlaybackState({
        metadata: {
          title: song.title,
          artist: song.artist,
          album: song.album,
          duration,
          artworkUrl,
        },
        isPlaying: remoteSnapshotData.snapshot.isPlaying,
        position,
        duration,
      })
      .catch((error) => {
        logger.info("[MediaSessionObserver.nativeRemoteUpdate] failed", error);
      });
  }, [hasNothingPlaying, isRemoteActive, remoteSnapshotData, song]);

  return null;
}
