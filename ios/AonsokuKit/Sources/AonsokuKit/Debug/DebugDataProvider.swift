import Foundation

#if canImport(UIKit)
import AVFoundation
#endif

public struct QueueItemInfo: Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let duration: Double
    public let isCurrent: Bool
}

public struct AudioDebugSnapshot: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let isPlaying: Bool
    public let currentTime: Double
    public let duration: Double
    public let bufferedTime: Double
    public let sourceKind: String?
    public let bufferEmpty: Bool
    public let likelyToKeepUp: Bool
    public let recoveryState: String
    public let repeatMode: String
    public let shuffleEnabled: Bool
    public let queueIndex: Int
    public let queueItemCount: Int
    public let queue: [QueueItemInfo]
    public let userQueue: [QueueItemInfo]
}

public struct ConnectionDebugSnapshot: Sendable {
    public let serverUrl: String
    public let username: String
    public let authType: String
    public let protocolVersion: String
    public let serverType: String
    public let hasFallbackUrl: Bool
}

#if canImport(UIKit)
/// What `AVAudioSession` reports. macOS has no audio session, and the debug
/// screen that shows this is iOS-only.
struct AudioSessionSnapshot {
    let category: String
    let mode: String
    let isOtherAudioPlaying: Bool
    let outputVolume: Float
    let sampleRate: Double
    let outputLatency: TimeInterval
    let ioBufferDuration: TimeInterval
}
#endif

/// What the native player debug screens show: the playback snapshot, the
/// signed-in connection and memory use.
public final class DebugDataProvider {
    private let audioService: AudioService

    public init(audioService: AudioService = AppServices.shared.audio) {
        self.audioService = audioService
    }

    public func audioSnapshot() -> AudioDebugSnapshot? {
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

    public func playPause() {
        _ = audioService.execute(.togglePlayPause)
    }

    public func skipNext() {
        audioService.skipToNext()
    }

    public func skipPrevious() {
        audioService.skipToPrevious()
    }

    public func connectionSnapshot() -> ConnectionDebugSnapshot? {
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

    #if canImport(UIKit)
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
    #endif

    public func memoryUsageMB() -> Double {
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
