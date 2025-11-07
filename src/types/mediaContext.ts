import { ISong } from "@/types/responses/song";

export interface MediaSessionState {
    isPlaying: boolean;
    currentSong: ISong | null;
    duration: number;
    position: number;
    isRemoteMode: boolean;
}

export interface IMediaContext {
    state: MediaSessionState;
    updatePlaybackState: (isPlaying: boolean) => void;
    updateMetadata: (song: ISong | null) => void;
    updatePosition: (position: number) => void;
    updateDuration: (duration: number) => void;
    setRemoteMode: (isRemote: boolean) => void;
}
