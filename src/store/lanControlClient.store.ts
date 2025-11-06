import { createWithEqualityFn } from 'zustand/traditional'
import { shallow } from 'zustand/shallow'
import {
    AuthResponseData,
    CurrentSongData,
    LanControlMessage,
    LanControlMessageType,
    PlayerStateData,
    QueueData,
    RemoteDeviceInfo,
} from '@/types/lanControl'
import { usePlayerStore } from './player.store'

type ConnectionStatus =
    | 'disconnected'
    | 'connecting'
    | 'authenticating'
    | 'connected'
    | 'error'

type SendPayload = {
    type: LanControlMessageType
    data?: unknown
}
interface LanControlClientState {
    status: ConnectionStatus
    address: string
    password: string
    error?: string
    remoteDevice: RemoteDeviceInfo | null
    playerState: PlayerStateData | null
    currentSong: CurrentSongData | null
    queue: QueueData | null
    lastMessageAt: number | null
    actions: {
        setAddress: (address: string) => void
        setPassword: (password: string) => void
        connect: () => void
        disconnect: () => void
        clearError: () => void
        send: (payload: SendPayload) => void
    }
}

let socket: WebSocket | null = null
let reconnectAbort = false

function parseMessage(event: MessageEvent<string>): LanControlMessage | null {
    try {
        return JSON.parse(event.data) as LanControlMessage
    } catch (error) {
        console.error('[LAN Control Client] Failed to parse message', error)
        return null
    }
}

function closeSocket() {
    if (socket) {
        socket.close()
        socket = null
    }
}

const getPlayerActions = () => usePlayerStore.getState().actions

function cleanupRemoteControl() {
    const actions = getPlayerActions()
    actions.clearRemoteSender()
    actions.exitRemoteControl()
}

export const useLanControlClientStore = createWithEqualityFn<LanControlClientState>()(
    (set, get) => ({
        status: 'disconnected',
        address: 'ws://localhost:5299',
        password: '',
        remoteDevice: null,
        playerState: null,
        currentSong: null,
        queue: null,
        lastMessageAt: null,
        error: undefined,
        actions: {
            setAddress: (address) => {
                set({ address })
            },
            setPassword: (password) => {
                set({ password: password.toUpperCase() })
            },
            clearError: () => {
                set({ error: undefined })
            },
            connect: () => {
                const { status, address, password } = get()
                if (status === 'connecting' || status === 'authenticating') {
                    return
                }

                reconnectAbort = false
                closeSocket()

                let serverUrl: URL
                try {
                    serverUrl = new URL(address, window.location.href)
                    if (!/^wss?:$/i.test(serverUrl.protocol)) {
                        serverUrl.protocol = serverUrl.protocol === 'https:' ? 'wss:' : 'ws:'
                    }
                } catch (error) {
                    console.error('[LAN Control Client] Invalid URL', error)
                    cleanupRemoteControl()
                    set({
                        status: 'error',
                        error: 'Invalid server URL',
                    })
                    return
                }

                set({
                    status: 'connecting',
                    error: undefined,
                    remoteDevice: null,
                })

                socket = new WebSocket(serverUrl.toString())

                socket.addEventListener('open', () => {
                    if (reconnectAbort) return
                    set({ status: 'authenticating' })
                    const payload: LanControlMessage = {
                        type: LanControlMessageType.AUTH_REQUEST,
                        data: {
                            authType: 'lan',
                            password: password.trim().toUpperCase(),
                        },
                        timestamp: Date.now(),
                    }
                    socket?.send(JSON.stringify(payload))
                })

                socket.addEventListener('message', (event) => {
                    if (reconnectAbort) return
                    const message = parseMessage(event)
                    if (!message) return

                    switch (message.type) {
                        case LanControlMessageType.AUTH_RESPONSE: {
                            const response = (message.data ?? {}) as AuthResponseData
                            const success = Boolean(response?.success)
                            if (success) {
                                const remoteDevice = response.deviceInfo ?? null
                                set({
                                    status: 'connected',
                                    remoteDevice,
                                    error: undefined,
                                    playerState: null,
                                    currentSong: null,
                                    queue: null,
                                })
                                const playerActions = getPlayerActions()
                                playerActions.registerRemoteSender((type, data) => {
                                    get().actions.send({ type, data })
                                })
                                playerActions.enterRemoteControl(remoteDevice)
                                playerActions.setRemoteDevice(remoteDevice)
                                const requestState: LanControlMessage = {
                                    type: LanControlMessageType.GET_STATE,
                                    timestamp: Date.now(),
                                }
                                socket?.send(JSON.stringify(requestState))
                                const requestSong: LanControlMessage = {
                                    type: LanControlMessageType.GET_CURRENT_SONG,
                                    timestamp: Date.now(),
                                }
                                socket?.send(JSON.stringify(requestSong))
                                const requestQueue: LanControlMessage = {
                                    type: LanControlMessageType.GET_QUEUE,
                                    timestamp: Date.now(),
                                }
                                socket?.send(JSON.stringify(requestQueue))
                            } else {
                                cleanupRemoteControl()
                                set({
                                    status: 'error',
                                    error: typeof response?.message === 'string'
                                        ? response.message
                                        : 'Authentication failed',
                                })
                                closeSocket()
                            }
                            break
                        }
                        case LanControlMessageType.STATE_UPDATE: {
                            const stateData = (message.data as PlayerStateData) ?? null
                            set({
                                playerState: stateData,
                                lastMessageAt: Date.now(),
                            })
                            getPlayerActions().setRemotePlayerState(stateData)
                            break
                        }
                        case LanControlMessageType.CURRENT_SONG_UPDATE: {
                            const songData = (message.data as CurrentSongData) ?? null
                            set({
                                currentSong: songData,
                                lastMessageAt: Date.now(),
                            })
                            getPlayerActions().setRemoteCurrentSongData(songData)
                            break
                        }
                        case LanControlMessageType.QUEUE_UPDATE: {
                            const queueData = (message.data as QueueData) ?? null
                            set({
                                queue: queueData,
                                lastMessageAt: Date.now(),
                            })
                            getPlayerActions().setRemoteQueueData(queueData)
                            break
                        }
                        case LanControlMessageType.ERROR: {
                            const errorPayload = (message.data ?? {}) as { message?: string }
                            cleanupRemoteControl()
                            set({
                                status: 'error',
                                error: typeof errorPayload?.message === 'string'
                                    ? errorPayload.message
                                    : 'Server error',
                                remoteDevice: null,
                                playerState: null,
                                currentSong: null,
                                queue: null,
                            })
                            break
                        }
                    }
                })

                socket.addEventListener('close', () => {
                    if (reconnectAbort) return
                    cleanupRemoteControl()
                    set((state) => ({
                        status: state.status === 'error' ? state.status : 'disconnected',
                        remoteDevice: null,
                        playerState: null,
                        currentSong: null,
                        queue: null,
                    }))
                    socket = null
                })

                socket.addEventListener('error', () => {
                    if (reconnectAbort) return
                    cleanupRemoteControl()
                    set({
                        status: 'error',
                        error: 'WebSocket error',
                        remoteDevice: null,
                        playerState: null,
                        currentSong: null,
                        queue: null,
                    })
                })
            },
            disconnect: () => {
                reconnectAbort = true
                closeSocket()
                cleanupRemoteControl()
                set({
                    status: 'disconnected',
                    remoteDevice: null,
                    playerState: null,
                    currentSong: null,
                    queue: null,
                })
            },
            send: ({ type, data }) => {
                if (!socket || socket.readyState !== WebSocket.OPEN) return
                const payload: LanControlMessage = {
                    type,
                    data,
                    timestamp: Date.now(),
                }
                socket.send(JSON.stringify(payload))
            },
        },
    }),
    shallow,
)