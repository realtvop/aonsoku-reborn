import Foundation

class NativeScrobbleSubmitter {
    private let httpClient = SubsonicHTTPClient()
    private let thresholdPercent = 0.5
    private let thresholdMaxSeconds: Double = 240

    func sendNowPlaying(songId: String) {
        Task {
            guard let credentials = KeychainManager.retrieve() else { return }
            _ = try? await httpClient.request(
                baseUrl: credentials.serverUrl,
                path: "scrobble",
                credentials: credentials,
                extraQuery: [
                    "id": songId,
                    "submission": "false",
                    "time": String(Int(Date().timeIntervalSince1970 * 1000)),
                ]
            )
        }
    }

    func submitIfEligible(entry: ScrobbleEntry, songDurationSeconds: Double) {
        guard isEligible(
            entry: entry,
            songDurationSeconds: songDurationSeconds
        ) else { return }
        submit(songId: entry.songId, timestamp: entry.timestamp)
    }

    func isEligible(
        entry: ScrobbleEntry,
        songDurationSeconds: Double
    ) -> Bool {
        let playedSeconds = Double(entry.playedDurationMs) / 1000
        let threshold = min(
            songDurationSeconds * thresholdPercent,
            thresholdMaxSeconds
        )
        return threshold > 0 && playedSeconds >= threshold
    }

    func submitPending(buffer: NativeScrobbleBuffer) {
        let entries = buffer.getEntries()
        guard !entries.isEmpty else { return }
        guard KeychainManager.retrieve() != nil else { return }

        Task {
            var submittedIds = Set<String>()
            for entry in entries {
                if await submitAsync(songId: entry.songId, timestamp: entry.timestamp) {
                    submittedIds.insert(entry.songId)
                } else {
                    break
                }
            }
            if !submittedIds.isEmpty {
                await MainActor.run {
                    buffer.removeEntries(songIds: submittedIds)
                }
            }
        }
    }

    private func submit(songId: String, timestamp: Double) {
        Task {
            await submitAsync(songId: songId, timestamp: timestamp)
        }
    }

    @discardableResult
    private func submitAsync(songId: String, timestamp: Double) async -> Bool {
        guard let credentials = KeychainManager.retrieve() else { return false }

        do {
            _ = try await httpClient.request(
                baseUrl: credentials.serverUrl,
                path: "scrobble",
                credentials: credentials,
                extraQuery: [
                    "id": songId,
                    "submission": "true",
                    "time": String(Int(timestamp)),
                ]
            )
            return true
        } catch {
            return false
        }
    }
}
