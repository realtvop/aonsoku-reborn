import Foundation

class NativeScrobbleSubmitter {
    private let thresholdPercent = 0.5
    private let thresholdMaxSeconds: Double = 240
    private let credentialsProvider: @Sendable () -> ServerCredentials?
    private let request: @Sendable (
        ServerCredentials,
        String,
        Bool,
        Double
    ) async -> Bool
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    private var pendingSubmissionId: UUID?
    private var pendingSubmissionTask: Task<Void, Never>?

    convenience init(client: HTTPClient = NetworkService.shared.client(for: .subsonic)) {
        let httpClient = SubsonicHTTPClient(client: client)
        self.init(
            credentialsProvider: { KeychainManager.retrieve() },
            request: { credentials, songId, submission, timestamp in
                do {
                    _ = try await httpClient.request(
                        baseUrl: credentials.serverUrl,
                        path: "scrobble",
                        credentials: credentials,
                        extraQuery: [
                            "id": songId,
                            "submission": submission ? "true" : "false",
                            "time": String(Int(timestamp)),
                        ]
                    )
                    return true
                } catch {
                    return false
                }
            }
        )
    }

    init(
        credentialsProvider: @escaping @Sendable () -> ServerCredentials?,
        request: @escaping @Sendable (
            ServerCredentials,
            String,
            Bool,
            Double
        ) async -> Bool
    ) {
        self.credentialsProvider = credentialsProvider
        self.request = request
    }

    func sendNowPlaying(songId: String) {
        guard let context = operationContext() else { return }
        Task {
            guard isCurrent(context.generation) else { return }
            _ = await request(
                context.credentials,
                songId,
                false,
                Date().timeIntervalSince1970 * 1000
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
        guard let context = operationContext() else { return }
        let submissionId = UUID()
        let reserved = generationLock.withLock { () -> Bool in
            guard generation == context.generation,
                  pendingSubmissionId == nil else { return false }
            pendingSubmissionId = submissionId
            return true
        }
        guard reserved else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishPendingSubmission(submissionId) }
            var submittedEntries: [ScrobbleEntry] = []
            for entry in entries {
                guard self.isCurrent(context.generation) else { return }
                if await self.request(
                    context.credentials,
                    entry.songId,
                    true,
                    entry.timestamp
                ) {
                    submittedEntries.append(entry)
                } else {
                    break
                }
            }
            if !submittedEntries.isEmpty, self.isCurrent(context.generation) {
                let completedEntries = submittedEntries
                await MainActor.run {
                    guard self.isCurrent(context.generation) else { return }
                    buffer.removeEntries(completedEntries)
                }
            }
        }
        generationLock.withLock {
            if pendingSubmissionId == submissionId {
                pendingSubmissionTask = task
            } else {
                task.cancel()
            }
        }
    }

    func invalidate() {
        let task = generationLock.withLock { () -> Task<Void, Never>? in
            generation &+= 1
            pendingSubmissionId = nil
            let task = pendingSubmissionTask
            pendingSubmissionTask = nil
            return task
        }
        task?.cancel()
    }

    private func submit(songId: String, timestamp: Double) {
        guard let context = operationContext() else { return }
        Task {
            guard isCurrent(context.generation) else { return }
            _ = await request(
                context.credentials,
                songId,
                true,
                timestamp
            )
        }
    }

    private func operationContext() -> (
        generation: UInt64,
        credentials: ServerCredentials
    )? {
        let currentGeneration = generationLock.withLock { generation }
        guard let credentials = credentialsProvider() else { return nil }
        guard isCurrent(currentGeneration) else { return nil }
        return (currentGeneration, credentials)
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        generationLock.withLock { generation == candidate }
    }

    private func finishPendingSubmission(_ submissionId: UUID) {
        generationLock.withLock {
            guard pendingSubmissionId == submissionId else { return }
            pendingSubmissionId = nil
            pendingSubmissionTask = nil
        }
    }
}
