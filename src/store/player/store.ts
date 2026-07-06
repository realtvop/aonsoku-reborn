import { devtools, persist, subscribeWithSelector } from "zustand/middleware";
import { immer } from "zustand/middleware/immer";
import { shallow } from "zustand/shallow";
import { createWithEqualityFn } from "zustand/traditional";
import {
  CurrentSongData,
  LanControlMessageType,
  PlayerStateData,
} from "@/types/lanControl";
import { IPlayerContext, LoopState } from "@/types/playerContext";
import { ISong } from "@/types/responses/song";
import {
  createInitialSettings,
  initialPlayerProgress,
  initialPlayerState,
  initialRemoteControl,
  initialSonglist,
} from "./initial-state";
import { createPlaybackActions } from "./playback-actions";
import { createPlayerPersistOptions } from "./persistence";
import { createQueueActions } from "./queue-actions";
import { clearSonglistState } from "./queue-utils";

import { createSettingsActions } from "./settings-actions";
import { createStarActions } from "./star-actions";
import { createUiActions } from "./ui-actions";

export const usePlayerStore = createWithEqualityFn<IPlayerContext>()(
  subscribeWithSelector(
    persist(
      devtools(
        immer((set, get) => {
          const isRemoteActive = () => get().remoteControl.active;

          const remoteSend = (type: LanControlMessageType, data?: unknown) => {
            const { active, sendCommand } = get().remoteControl;
            if (!active || !sendCommand) return false;
            sendCommand(type, data);
            return true;
          };

          const mapRepeatMode = (
            repeatMode: PlayerStateData["repeatMode"] | undefined,
          ) => {
            if (repeatMode === "one") return LoopState.One;
            if (repeatMode === "all") return LoopState.All;
            return LoopState.Off;
          };

          const remoteSongToISong = (song: CurrentSongData): ISong => ({
            id: song.id,
            parent: "",
            isDir: false,
            title: song.title ?? "",
            album: song.album ?? "",
            artist: song.artist ?? "",
            track: 0,
            year: 0,
            genre: undefined,
            coverArt: song.coverArt ?? "",
            size: 0,
            contentType: "",
            suffix: "",
            duration: song.duration ?? 0,
            bitRate: 0,
            path: "",
            playCount: 0,
            discNumber: 0,
            created: "remote",
            albumId: song.albumId ?? "",
            artistId: undefined,
            type: "remote",
            isVideo: false,
            played: undefined,
            bpm: 0,
            starred: undefined,
            comment: "",
            sortName: song.title ?? "",
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
            displayArtist: song.artist,
            albumArtists: undefined,
            displayAlbumArtist: song.album,
            contributors: undefined,
            displayComposer: undefined,
            explicitStatus: undefined,
          });

          const shared = {
            set,
            get,
            isRemoteActive,
            remoteSend,
            mapRepeatMode,
            remoteSongToISong,
            clearSonglistState,
          };

          const queueActions = createQueueActions(shared);
          const playbackActions = createPlaybackActions(shared);
          const uiActions = createUiActions(shared);

          const starActions = createStarActions(shared);
          const settingsActions = createSettingsActions(shared);

          return {
            songlist: initialSonglist,
            playerState: initialPlayerState,
            playerProgress: initialPlayerProgress,
            settings: createInitialSettings(set),
            remoteControl: initialRemoteControl,
            actions: {
              ...queueActions,
              ...playbackActions,
              ...uiActions,

              ...starActions,
              ...settingsActions,
            },
          };
        }),
        { name: "player_store" },
      ),
      createPlayerPersistOptions(() => usePlayerStore),
    ),
  ),
  shallow,
);
