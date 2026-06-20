import { useCallback, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { useBackgroundPlayback } from "@/app/hooks/use-background-playback";
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
import { clampProgress, isValidDuration } from "@/utils/duration";
import { logger } from "@/utils/logger";
import { manageMediaSession } from "@/utils/setMediaSession";

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
  const isRemoteActive = false;
  const remotePlayerState = null;
  const remoteCurrentSong = null;

  const lastMetadataRef = useRef<string>("");

  const song =
    isRemoteActive && remoteCurrentSong?.id
      ? {
          id: remoteCurrentSong.id,
          title: remoteCurrentSong.title,
          artist: remoteCurrentSong.artist,
          album: remoteCurrentSong.album,
          coverArt: remoteCurrentSong.coverArt,
          albumId: remoteCurrentSong.albumId,
          duration: remoteCurrentSong.duration,
        }
      : storeCurrentSong;
  const radio = radioList[currentSongIndex] ?? null;

  const hasNothingPlaying = isRemoteActive
    ? !remoteCurrentSong || !remoteCurrentSong.id
    : !storeCurrentSong && radioList.length === 0;

  const resetAppTitle = useCallback(() => {
    document.title = appName;
  }, []);

  useEffect(() => {
    logger.info(
      `[MediaSessionObserver] handlers | remoteControl=${isRemoteActive}`,
    );
    manageMediaSession.setHandlers();
  }, []);

  useEffect(() => {
    logger.info(
      `[MediaSessionObserver] isPlaying=${isPlaying} | isTransitioning=${isTransitioning} | isSong=${isSong} | isRadio=${isRadio} | songId=${song?.id} | isRemote=${isRemoteActive} | hasNothingPlaying=${hasNothingPlaying}`,
    );

    const effectiveIsPlaying = isRemoteActive
      ? (remotePlayerState?.isPlaying ?? false)
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
    } else if (isSong && song) {
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
    radio,
    radioLabel,
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
      ? (remotePlayerState?.isPlaying ?? false)
      : isPlaying;

    if (hasNothingPlaying || !song) {
      return;
    }

    const duration = isRemoteActive ? (song.duration ?? 0) : currentDuration;

    if (!isValidDuration(duration)) {
      return;
    }

    const effectiveProgress =
      isRemoteActive && remotePlayerState?.currentTime !== undefined
        ? remotePlayerState.currentTime
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
  }, [progress, isPlaying, hasNothingPlaying, song, currentDuration]);

  return null;
}
