import { ISong } from '@/types/responses/song'

export enum ConnectionMode {
    HOST = 'HOST',
    CLIENT = 'CLIENT',
    DISCONNECTED = 'DISCONNECTED',
}

export enum ConnectionState {
    DISCONNECTED = 'disconnected',
    CONNECTING = 'connecting',
    CONNECTED = 'connected',
    ERROR = 'error',
}

export enum MessageType {
    // Synchronization messages
    SYNC_STATE = 'SYNC_STATE',
    SYNC_SERVER_CONFIG = 'SYNC_SERVER_CONFIG',
    REQUEST_STATE = 'REQUEST_STATE',

    // Playback control messages
    PLAY = 'PLAY',
    PAUSE = 'PAUSE',
    NEXT = 'NEXT',
    PREV = 'PREV',
    SEEK = 'SEEK',
    VOLUME = 'VOLUME',
    SHUFFLE = 'SHUFFLE',
    LOOP = 'LOOP',

    // Queue/Playlist messages
    SET_SONG_LIST = 'SET_SONG_LIST',
    PLAY_SONG = 'PLAY_SONG',
    ADD_TO_QUEUE_NEXT = 'ADD_TO_QUEUE_NEXT',
    ADD_TO_QUEUE_LAST = 'ADD_TO_QUEUE_LAST',
    REMOVE_FROM_QUEUE = 'REMOVE_FROM_QUEUE',
}

export interface SyncPlayerState {
    currentSong?: ISong
    isPlaying: boolean
    progress: number
    duration: number
    volume: number
    shuffle: boolean
    loop: 'off' | 'one' | 'all'
    queue: ISong[]
    queueIndex: number
}

export interface SyncServerConfig {
    url: string
    username: string
    coverArtURL: string
}

export interface WebRTCMessage {
    type: MessageType
    payload?: Record<string, unknown>
    timestamp: number
}

export interface IWebRTCData {
    mode: ConnectionMode
    state: ConnectionState
    connectionCode: string | null
    serverConfig: SyncServerConfig | null
    error: string | null
    isRemoteControl: boolean
}

export interface IWebRTCActions {
    generateConnectionCode: () => Promise<string>
    connectWithCode: (code: string, mode: ConnectionMode) => Promise<void>
    disconnect: () => void
    sendMessage: (message: WebRTCMessage) => void
    syncPlayerState: (state: SyncPlayerState) => void
    syncServerConfig: (config: SyncServerConfig) => void
    requestStateSync: () => void
    tryReconnect: () => Promise<void>
}

export type IWebRTCContext = IWebRTCData & IWebRTCActions
