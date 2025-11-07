import { useCallback, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import {
  usePlayerIsPlaying,
  usePlayerMediaType,
  usePlayerSonglist,
  useIsRemoteControlActive,
  usePlayerProgress,
} from "@/store/player.store";
import { useLanControlClientStore } from "@/store/lanControlClient.store";
import { appName } from "@/utils/appName";
import { manageMediaSession } from "@/utils/setMediaSession";

export function MediaSessionObserver() {
  const { t } = useTranslation();
  const isPlaying = usePlayerIsPlaying();
  const { isRadio, isSong, isPodcast } = usePlayerMediaType();
  const { currentList, currentSongIndex, podcastList, radioList } =
    usePlayerSonglist();
  const progress = usePlayerProgress();
  const radioLabel = t("radios.label");
  const isRemoteActive = useIsRemoteControlActive();

  // Get remote player state directly for more accurate status
  const remotePlayerState = useLanControlClientStore(
    (state) => state.playerState
  );
  const remoteCurrentSong = useLanControlClientStore(
    (state) => state.currentSong
  );

  // Use ref to track last update to avoid unnecessary re-renders
  const lastMetadataRef = useRef<string>("");

  // In remote mode, prefer currentSong over currentList[index]
  // because currentSong is set directly from remote updates
  const song =
    isRemoteActive && remoteCurrentSong?.id
      ? {
          id: remoteCurrentSong.id,
          title: remoteCurrentSong.title,
          artist: remoteCurrentSong.artist,
          album: remoteCurrentSong.album,
          coverArt: remoteCurrentSong.coverArt,
          duration: remoteCurrentSong.duration,
        }
      : currentList[currentSongIndex] ?? null;
  const radio = radioList[currentSongIndex] ?? null;
  const episode = podcastList[currentSongIndex] ?? null;

  // In remote mode, check if we have currentSong data
  const hasNothingPlaying = isRemoteActive
    ? !remoteCurrentSong || !remoteCurrentSong.id
    : currentList.length === 0 &&
      radioList.length === 0 &&
      podcastList.length === 0;

  const resetAppTitle = useCallback(() => {
    document.title = appName;
  }, []);

  // Update media session handlers when remote control state changes
  useEffect(() => {
    console.log("[MediaSession] Remote control state changed:", isRemoteActive);
    manageMediaSession.setHandlers();
  }, [isRemoteActive]);

  // Update metadata and playback state whenever they change
  useEffect(() => {
    console.log("[MediaSession] State update:", {
      isRemoteActive,
      isPlaying: isRemoteActive ? remotePlayerState?.isPlaying : isPlaying,
      hasNothingPlaying,
      hasSong: !!song,
      songTitle: song?.title,
      songArtist: song?.artist,
      remotePlayerState: isRemoteActive ? remotePlayerState : undefined,
    });

    // Use remote player state when in remote mode
    const effectiveIsPlaying = isRemoteActive
      ? remotePlayerState?.isPlaying ?? false
      : isPlaying;

    manageMediaSession.setPlaybackState(effectiveIsPlaying);

    if (hasNothingPlaying) {
      console.log("[MediaSession] Nothing playing, removing session");
      manageMediaSession.removeMediaSession();
      resetAppTitle();
      lastMetadataRef.current = "";
      return;
    }

    if (!effectiveIsPlaying) {
      resetAppTitle();
      // Don't clear metadata when paused, just update playback state
      return;
    }

    let title = "";
    let metadataKey = "";

    if (isRadio && radio) {
      title = `${radioLabel} - ${radio.name} | Aonsoku`;
      metadataKey = `radio:${radio.name}`;

      // Only update if changed
      if (lastMetadataRef.current !== metadataKey) {
        console.log("[MediaSession] Setting radio session:", title);
        manageMediaSession.setRadioMediaSession(radioLabel, radio.name);
        lastMetadataRef.current = metadataKey;
      }
    } else if (isSong && song) {
      title = `${song.title} - ${song.artist} | Aonsoku`;
      metadataKey = `song:${song.id || song.title}`;

      // Only update if changed
      if (lastMetadataRef.current !== metadataKey) {
        console.log("[MediaSession] Setting song session:", title);
        manageMediaSession.setMediaSession(song);
        lastMetadataRef.current = metadataKey;
      }
    } else if (isPodcast && episode) {
      title = `${episode.title} - ${episode.podcast.title} | Aonsoku`;
      metadataKey = `podcast:${episode.id}`;

      // Only update if changed
      if (lastMetadataRef.current !== metadataKey) {
        console.log("[MediaSession] Setting podcast session:", title);
        manageMediaSession.setPodcastMediaSession(episode);
        lastMetadataRef.current = metadataKey;
      }
    }

    document.title = title;
  }, [
    episode,
    hasNothingPlaying,
    isPlaying,
    isPodcast,
    isRadio,
    isSong,
    radio,
    radioLabel,
    song,
    resetAppTitle,
    isRemoteActive,
    remotePlayerState,
  ]);

  // Update position state for progress tracking
  useEffect(() => {
    // Use remote player state when in remote mode
    const effectiveIsPlaying = isRemoteActive
      ? remotePlayerState?.isPlaying ?? false
      : isPlaying;

    if (!effectiveIsPlaying || hasNothingPlaying || !song) {
      return;
    }

    const duration = song.duration ?? 0;

    // In remote mode, use remote progress if available
    const effectiveProgress =
      isRemoteActive && remotePlayerState?.currentTime !== undefined
        ? remotePlayerState.currentTime
        : progress;

    manageMediaSession.setPositionState(duration, effectiveProgress);
  }, [
    progress,
    isPlaying,
    hasNothingPlaying,
    song,
    isRemoteActive,
    remotePlayerState,
  ]);

  return null;
}
