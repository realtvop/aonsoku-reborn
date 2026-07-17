import type {
  AonsokuAudioBridge,
  NativeRemotePlaybackStateOptions,
} from "@aonsoku/audio-contract";
import { useCallback, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { useBackgroundPlayback } from "@/app/hooks/use-background-playback";
import { getNativeAudioPluginAvailability } from "@/native/audio/facade";
import { playbackRepeatModeFromLoopState } from "@/player/playback/types";
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
import {
  getCoverArtUrlFromSongPreference,
  getSongCoverArtId,
} from "@/utils/coverArt";
import { clampProgress, isValidDuration } from "@/utils/duration";
import { logger } from "@/utils/logger";
import { manageMediaSession } from "@/utils/setMediaSession";

const NATIVE_REMOTE_COVER_SIZE = "800";

export async function syncNativeRemotePlaybackProjection(
  plugin: AonsokuAudioBridge,
  options: NativeRemotePlaybackStateOptions | null,
): Promise<void> {
  if (options) {
    await plugin.updateRemotePlaybackState(options);
  } else {
    await plugin.clearRemotePlaybackState();
  }
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
  const remoteProjection = useRemotePlaybackProjection();
  const isRemoteActive = remoteProjection.active;

  const lastMetadataRef = useRef<string>("");

  const song = isRemoteActive ? remoteProjection.song : storeCurrentSong;
  const radio = radioList[currentSongIndex] ?? null;

  const hasNothingPlaying = isRemoteActive
    ? !remoteProjection.song?.id
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
      ? remoteProjection.isPlaying
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

    if (!isRemoteActive && isRadio && radio) {
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
    remoteProjection.isPlaying,
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
      ? remoteProjection.isPlaying
      : isPlaying;

    if (hasNothingPlaying || !song) {
      return;
    }

    const duration = isRemoteActive
      ? remoteProjection.duration || song.duration || 0
      : currentDuration;

    if (!isValidDuration(duration)) {
      return;
    }

    const effectiveProgress = isRemoteActive
      ? remoteProjection.progress
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
    remoteProjection.duration,
    remoteProjection.isPlaying,
    remoteProjection.progress,
  ]);

  useEffect(() => {
    const availability = getNativeAudioPluginAvailability();
    if (!availability.available) return;

    const plugin = availability.plugin;
    if (!isRemoteActive || hasNothingPlaying || !song) {
      if (nativeRemoteProjectionActiveRef.current) {
        nativeRemoteProjectionActiveRef.current = false;
        syncNativeRemotePlaybackProjection(plugin, null).catch((error) => {
          logger.error(
            "[MediaSessionObserver.nativeRemoteClear] failed",
            error,
          );
        });
      }
      return;
    }

    const duration = remoteProjection.duration || song.duration || 0;
    const position = remoteProjection.progress;
    const artworkUrl =
      song.coverArt || song.albumId
        ? getCoverArtUrlFromSongPreference({
            coverArt: song.coverArt,
            coverArtType: "song",
            albumId: song.albumId,
            size: NATIVE_REMOTE_COVER_SIZE,
          })
        : undefined;
    const coverArtId =
      song.coverArt || song.albumId
        ? getSongCoverArtId({
            coverArt: song.coverArt ?? "",
            albumId: song.albumId,
          })
        : undefined;

    nativeRemoteProjectionActiveRef.current = true;
    syncNativeRemotePlaybackProjection(plugin, {
      metadata: {
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration,
        artworkUrl,
        coverArtId,
      },
      isPlaying: remoteProjection.isPlaying,
      position,
      duration,
      isShuffleActive: remoteProjection.isShuffleActive,
      repeatMode: playbackRepeatModeFromLoopState(remoteProjection.loopState),
      volume:
        typeof remoteProjection.volume === "number"
          ? remoteProjection.volume / 100
          : undefined,
      targetDeviceId: remoteProjection.targetDeviceId ?? undefined,
      expectedGeneration: remoteProjection.expectedGeneration ?? undefined,
    }).catch((error) => {
      logger.error("[MediaSessionObserver.nativeRemoteUpdate] failed", error);
    });
  }, [
    hasNothingPlaying,
    isRemoteActive,
    remoteProjection.duration,
    remoteProjection.isPlaying,
    remoteProjection.isShuffleActive,
    remoteProjection.loopState,
    remoteProjection.progress,
    remoteProjection.targetDeviceId,
    remoteProjection.expectedGeneration,
    remoteProjection.volume,
    song,
  ]);

  return null;
}
