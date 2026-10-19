import AVFoundation

struct QueueItemInfo {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    let isCurrent: Bool
}

struct AudioDebugSnapshot {
    let title: String?
    let artist: String?
    let album: String?
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let bufferedTime: Double
    let sourceKind: String?
    let bufferEmpty: Bool
    let likelyToKeepUp: Bool
    let recoveryState: String
    let repeatMode: String
    let shuffleEnabled: Bool
    let queueIndex: Int
    let queueItemCount: Int
    let queue: [QueueItemInfo]
    let userQueue: [QueueItemInfo]
}

struct ConnectionDebugSnapshot {
    let serverUrl: String
    let username: String
    let authType: String
    let protocolVersion: String
    let serverType: String
    let hasFallbackUrl: Bool
}

struct AudioSessionSnapshot {
    let category: String
    let mode: String
    let isOtherAudioPlaying: Bool
    let outputVolume: Float
    let sampleRate: Double
    let outputLatency: TimeInterval
    let ioBufferDuration: TimeInterval
}

final class DebugDataProvider {
    private let audioService: AudioService

    init(audioService: AudioService = AppServices.shared.audio) {
        self.audioService = audioService
    }

    func audioSnapshot() -> AudioDebugSnapshot? {
        let snapshot = audioService.playbackSnapshot()
        let context = snapshot.queue?.contextSongs ?? []
        let currentId = snapshot.queue?.currentSongId
        return AudioDebugSnapshot(
            title: snapshot.metadata.title,
            artist: snapshot.metadata.artist,
            album: snapshot.metadata.album,
            isPlaying: snapshot.state == .playing,
            currentTime: snapshot.currentTime,
            duration: snapshot.duration,
            bufferedTime: snapshot.bufferedTime,
            sourceKind: nil,
            bufferEmpty: false,
            likelyToKeepUp: true,
            recoveryState: "idle",
            repeatMode: snapshot.queue?.loopState.rawValue ?? "off",
            shuffleEnabled: snapshot.queue?.isShuffleActive ?? false,
            queueIndex: snapshot.queue?.currentIndex ?? 0,
            queueItemCount: context.count,
            queue: context.map {
                QueueItemInfo(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist,
                    duration: $0.duration,
                    isCurrent: $0.id == currentId
                )
            },
            userQueue: (snapshot.queue?.userQueue ?? []).map {
                QueueItemInfo(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist,
                    duration: $0.duration,
                    isCurrent: $0.id == currentId
                )
            }
        )
    }

    func playPause() {
        _ = audioService.execute(.togglePlayPause)
    }

    func skipNext() {
        audioService.skipToNext()
    }

    func skipPrevious() {
        audioService.skipToPrevious()
    }

    func connectionSnapshot() -> ConnectionDebugSnapshot? {
        guard let creds = KeychainManager.retrieve() else { return nil }
        return ConnectionDebugSnapshot(
            serverUrl: creds.serverUrl,
            username: creds.username,
            authType: creds.authType,
            protocolVersion: creds.protocolVersion,
            serverType: creds.serverType,
            hasFallbackUrl: creds.fallbackUrl != nil
        )
    }

    func audioSessionSnapshot() -> AudioSessionSnapshot {
        let session = AVAudioSession.sharedInstance()
        return AudioSessionSnapshot(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            isOtherAudioPlaying: session.isOtherAudioPlaying,
            outputVolume: session.outputVolume,
            sampleRate: session.sampleRate,
            outputLatency: session.outputLatency,
            ioBufferDuration: session.ioBufferDuration
        )
    }

    func memoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
