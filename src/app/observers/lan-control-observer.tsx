import { useCallback, useEffect, useMemo, useRef } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import {
  useLanControlActions,
  useLanControlConfig,
  useLanControlServerInfo,
} from "@/store/lanControl.store";
import {
  usePlayerActions,
  usePlayerCurrentList,
  usePlayerCurrentSong,
  usePlayerCurrentSongIndex,
  usePlayerLoop,
  usePlayerProgress,
  usePlayerRef,
  usePlayerShuffle,
  usePlayerStore,
  usePlayerVolume,
} from "@/store/player.store";
import {
  CurrentSongData,
  LanControlMessage,
  LanControlMessageType,
  LanControlServerInfo,
  PlayerStateData,
  PlayAlbumData,
  PlayPlaylistData,
  PlaySongData,
  QueueData,
  SeekData,
  SetRepeatData,
  SetShuffleData,
  VolumeData,
  AddToQueueData,
  AddAlbumToQueueData,
  AddPlaylistToQueueData,
} from "@/types/lanControl";
import { LoopState } from "@/types/playerContext";
import { isDesktop } from "@/utils/desktop";
import { subsonic } from "@/service/subsonic";

function mapLoopState(loop: LoopState): PlayerStateData["repeatMode"] {
  switch (loop) {
    case LoopState.One:
      return "one";
    case LoopState.All:
      return "all";
    default:
      return "off";
  }
}

function clampVolume(volume: number): number {
  if (Number.isNaN(volume)) return 0;
  return Math.min(100, Math.max(0, Math.floor(volume)));
}

export function LanControlObserver() {
  const config = useLanControlConfig();
  const serverInfo = useLanControlServerInfo();
  const { setServerInfo } = useLanControlActions();
  const { t } = useTranslation();
  const playerActions = usePlayerActions();
  const audioRef = usePlayerRef();
  const playerProgress = usePlayerProgress();
  const { volume } = usePlayerVolume();
  const loopState = usePlayerLoop();
  const shuffleEnabled = usePlayerShuffle();
  const currentSong = usePlayerCurrentSong();
  const currentList = usePlayerCurrentList();
  const currentIndex = usePlayerCurrentSongIndex();
  const latestServerInfo = useRef<LanControlServerInfo>(serverInfo);
  const previousEnabled = useRef(config.enabled);
  const isDesktopEnv = useMemo(() => isDesktop(), []);

  latestServerInfo.current = serverInfo;

  const buildPlayerState = useCallback((): PlayerStateData => {
    const hasPrevious = currentIndex > 0;
    const hasNext = currentIndex >= 0 && currentIndex < currentList.length - 1;

    const duration = currentSong?.duration ?? 0;

    return {
      isPlaying: usePlayerStore.getState().playerState.isPlaying,
      currentTime: playerProgress,
      duration,
      volume,
      isShuffle: shuffleEnabled,
      repeatMode: mapLoopState(loopState),
      hasPrevious,
      hasNext,
    };
  }, [
    currentIndex,
    currentList.length,
    currentSong?.duration,
    loopState,
    playerProgress,
    shuffleEnabled,
    volume,
  ]);

  const buildCurrentSong = useCallback((): CurrentSongData | null => {
    if (!currentSong || !currentSong.id) return null;

    return {
      id: currentSong.id,
      title: currentSong.title,
      artist: currentSong.artist,
      album: currentSong.album,
      coverArt: currentSong.coverArt,
      duration: currentSong.duration,
    };
  }, [currentSong]);

  const buildQueueData = useCallback((): QueueData => {
    return {
      currentIndex,
      songs: currentList.map((song) => ({
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        coverArt: song.coverArt,
        duration: song.duration,
      })),
    };
  }, [currentIndex, currentList]);

  const broadcastState = useCallback(
    (state: PlayerStateData) => {
      if (!isDesktopEnv) return;
      if (!config.enabled) return;
      if (!latestServerInfo.current.running) return;
      window.api.lanControl.broadcastState(state);
    },
    [config.enabled, isDesktopEnv]
  );

  const ensureServerRunning = useCallback(async () => {
    if (!isDesktopEnv) return;
    const info = await window.api.lanControl.getInfo();
    setServerInfo(info);

    if (config.enabled && !info.running) {
      const result = await window.api.lanControl.start(config);
      setServerInfo(result);
      if (!result.running && result.error) {
        toast.error(
          `${t("settings.desktop.lanControl.serverError")}: ${result.error}`
        );
      }
    }
  }, [config, isDesktopEnv, setServerInfo, t]);

  useEffect(() => {
    if (!isDesktopEnv) return;
    ensureServerRunning();
  }, [ensureServerRunning, isDesktopEnv]);

  useEffect(() => {
    if (!isDesktopEnv) return;

    let cancelled = false;
    const wasEnabled = previousEnabled.current;

    async function handleToggle() {
      if (config.enabled && !wasEnabled) {
        const result = await window.api.lanControl.start(config);
        if (cancelled) return;
        setServerInfo(result);
        if (!result.running && result.error) {
          toast.error(
            `${t("settings.desktop.lanControl.serverError")}: ${result.error}`
          );
        } else if (result.running) {
          toast.success(t("settings.desktop.lanControl.serverStarted"));
        }
      } else if (!config.enabled && wasEnabled) {
        await window.api.lanControl.stop();
        if (cancelled) return;
        setServerInfo({
          running: false,
          port: config.port,
        });
      }
      previousEnabled.current = config.enabled;
    }

    handleToggle();

    return () => {
      cancelled = true;
    };
  }, [config.enabled, config, isDesktopEnv, setServerInfo, t]);

  useEffect(() => {
    if (!isDesktopEnv) return;
    if (!config.enabled) return;

    let cancelled = false;

    async function updateConfig() {
      await window.api.lanControl.updateConfig(config);
      const info = await window.api.lanControl.getInfo();
      if (!cancelled) {
        setServerInfo(info);
      }
    }

    updateConfig();

    return () => {
      cancelled = true;
    };
  }, [
    config.port,
    config.password,
    config.allowNavidromeAuth,
    config,
    isDesktopEnv,
    setServerInfo,
  ]);

  useEffect(() => {
    if (!isDesktopEnv) return;

    const handler = (message: LanControlMessage) => {
      const { type, data } = message;
      switch (type) {
        case LanControlMessageType.PLAY_PAUSE:
          playerActions.togglePlayPause();
          break;
        case LanControlMessageType.PLAY:
          playerActions.setPlayingState(true);
          break;
        case LanControlMessageType.PAUSE:
          playerActions.setPlayingState(false);
          break;
        case LanControlMessageType.NEXT:
          playerActions.playNextSong();
          break;
        case LanControlMessageType.PREVIOUS:
          playerActions.playPrevSong();
          break;
        case LanControlMessageType.SEEK: {
          const payload = data as SeekData | undefined;
          if (payload && typeof payload.time === "number") {
            const target = Math.max(0, payload.time);
            if (audioRef) {
              audioRef.currentTime = target;
            }
            playerActions.setProgress(target);
          }
          break;
        }
        case LanControlMessageType.SET_VOLUME: {
          const payload = data as VolumeData | undefined;
          if (payload && typeof payload.volume === "number") {
            playerActions.setVolume(clampVolume(payload.volume));
          }
          break;
        }
        case LanControlMessageType.TOGGLE_SHUFFLE:
          playerActions.toggleShuffle();
          break;
        case LanControlMessageType.TOGGLE_REPEAT:
          playerActions.toggleLoop();
          break;
        case LanControlMessageType.SET_SHUFFLE: {
          const payload = data as SetShuffleData | undefined;
          if (payload && typeof payload.enabled === "boolean") {
            const current =
              usePlayerStore.getState().playerState.isShuffleActive;
            if (current !== payload.enabled) {
              playerActions.toggleShuffle();
            }
          }
          break;
        }
        case LanControlMessageType.SET_REPEAT: {
          const payload = data as SetRepeatData | undefined;
          if (payload) {
            const desired = payload.mode;
            const loop = usePlayerStore.getState().playerState.loopState;
            if (
              (desired === "off" && loop !== LoopState.Off) ||
              (desired === "one" && loop !== LoopState.One) ||
              (desired === "all" && loop !== LoopState.All)
            ) {
              playerActions.toggleLoop();
            }
          }
          break;
        }
        case LanControlMessageType.GET_STATE: {
          const state = buildPlayerState();
          broadcastState(state);
          break;
        }
        case LanControlMessageType.GET_CURRENT_SONG: {
          const song = buildCurrentSong();
          if (song) {
            window.api.lanControl.broadcastSong(song);
          }
          break;
        }
        case LanControlMessageType.GET_QUEUE: {
          const queue = buildQueueData();
          window.api.lanControl.broadcastQueue(queue);
          break;
        }
        case LanControlMessageType.PLAY_SONG: {
          const payload = data as PlaySongData | undefined;
          if (payload && payload.songId) {
            subsonic.songs
              .getSong(payload.songId)
              .then((song) => {
                if (song) {
                  playerActions.playSong(song);
                }
              })
              .catch((error) => {
                console.error("Failed to play song:", error);
              });
          }
          break;
        }
        case LanControlMessageType.PLAY_ALBUM: {
          const payload = data as PlayAlbumData | undefined;
          if (payload && payload.albumId) {
            subsonic.albums
              .getOne(payload.albumId)
              .then((album) => {
                if (album && album.song) {
                  const startIndex = payload.songIndex ?? 0;
                  playerActions.setSongList(album.song, startIndex);
                }
              })
              .catch((error) => {
                console.error("Failed to play album:", error);
              });
          }
          break;
        }
        case LanControlMessageType.PLAY_PLAYLIST: {
          const payload = data as PlayPlaylistData | undefined;
          if (payload && payload.playlistId) {
            subsonic.playlists
              .getOne(payload.playlistId)
              .then((playlist) => {
                if (playlist && playlist.entry) {
                  const startIndex = payload.songIndex ?? 0;
                  playerActions.setSongList(playlist.entry, startIndex);
                }
              })
              .catch((error) => {
                console.error("Failed to play playlist:", error);
              });
          }
          break;
        }
        case LanControlMessageType.PLAY_ALBUM_SHUFFLE: {
          const payload = data as PlayAlbumData | undefined;
          if (payload && payload.albumId) {
            subsonic.albums
              .getOne(payload.albumId)
              .then((album) => {
                if (album && album.song) {
                  const startIndex = payload.songIndex ?? 0;
                  playerActions.setSongList(album.song, startIndex, true);
                }
              })
              .catch((error) => {
                console.error("Failed to play album with shuffle:", error);
              });
          }
          break;
        }
        case LanControlMessageType.PLAY_PLAYLIST_SHUFFLE: {
          const payload = data as PlayPlaylistData | undefined;
          if (payload && payload.playlistId) {
            subsonic.playlists
              .getOne(payload.playlistId)
              .then((playlist) => {
                if (playlist && playlist.entry) {
                  const startIndex = payload.songIndex ?? 0;
                  playerActions.setSongList(playlist.entry, startIndex, true);
                }
              })
              .catch((error) => {
                console.error("Failed to play playlist with shuffle:", error);
              });
          }
          break;
        }
        case LanControlMessageType.ADD_TO_QUEUE: {
          const payload = data as AddToQueueData | undefined;
          if (payload && payload.songIds && payload.songIds.length > 0) {
            // Fetch all songs and add them to queue
            Promise.all(payload.songIds.map((id) => subsonic.songs.getSong(id)))
              .then((songs) => {
                const validSongs = songs.filter(
                  (song) => song !== null && song !== undefined
                );
                if (validSongs.length > 0) {
                  playerActions.setLastOnQueue(validSongs);
                }
              })
              .catch((error) => {
                console.error("Failed to add songs to queue:", error);
              });
          }
          break;
        }
        case LanControlMessageType.ADD_ALBUM_TO_QUEUE: {
          const payload = data as AddAlbumToQueueData | undefined;
          if (payload && payload.albumId) {
            subsonic.albums
              .getOne(payload.albumId)
              .then((album) => {
                if (album && album.song && album.song.length > 0) {
                  playerActions.setLastOnQueue(album.song);
                }
              })
              .catch((error) => {
                console.error("Failed to add album to queue:", error);
              });
          }
          break;
        }
        case LanControlMessageType.ADD_PLAYLIST_TO_QUEUE: {
          const payload = data as AddPlaylistToQueueData | undefined;
          if (payload && payload.playlistId) {
            subsonic.playlists
              .getOne(payload.playlistId)
              .then((playlist) => {
                if (playlist && playlist.entry && playlist.entry.length > 0) {
                  playerActions.setLastOnQueue(playlist.entry);
                }
              })
              .catch((error) => {
                console.error("Failed to add playlist to queue:", error);
              });
          }
          break;
        }
        case LanControlMessageType.CLEAR_QUEUE: {
          playerActions.clearPlayerState();
          break;
        }
      }
    };

    window.api.lanControl.onMessage(handler);

    return () => {
      window.api.lanControl.removeMessageListener();
    };
  }, [
    audioRef,
    broadcastState,
    buildCurrentSong,
    buildPlayerState,
    buildQueueData,
    isDesktopEnv,
    playerActions,
  ]);

  useEffect(() => {
    if (!isDesktopEnv) return;

    const handleRequestState = () => {
      const state = buildPlayerState();
      const song = buildCurrentSong();
      const queue = buildQueueData();
      broadcastState(state);
      if (song) {
        window.api.lanControl.broadcastSong(song);
      }
      window.api.lanControl.broadcastQueue(queue);
    };

    window.api.lanControl.onRequestState(handleRequestState);

    return () => {
      window.api.lanControl.removeRequestStateListener();
    };
  }, [
    broadcastState,
    buildCurrentSong,
    buildPlayerState,
    buildQueueData,
    isDesktopEnv,
  ]);

  useEffect(() => {
    const state = buildPlayerState();
    broadcastState(state);
  }, [broadcastState, buildPlayerState]);

  useEffect(() => {
    if (!isDesktopEnv) return;
    if (!config.enabled) return;
    if (!latestServerInfo.current.running) return;

    const song = buildCurrentSong();
    if (song) {
      window.api.lanControl.broadcastSong(song);
    }
  }, [buildCurrentSong, config.enabled, isDesktopEnv]);

  useEffect(() => {
    if (!isDesktopEnv) return;
    if (!config.enabled) return;
    if (!latestServerInfo.current.running) return;

    const queue = buildQueueData();
    window.api.lanControl.broadcastQueue(queue);
  }, [buildQueueData, config.enabled, isDesktopEnv]);

  return null;
}
