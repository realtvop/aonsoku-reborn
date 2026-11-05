import Foundation

/// Tells a running import to stop, from any thread. One per run, so a late
/// request for an earlier run cannot cancel the next one.
final class DesktopImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// Settings → Storage → "Import downloads from Aonsoku Desktop…" (macOS).
//
// The store looks at the Electron desktop app's `AudioCache`, shows what an
// import would do and runs it off the main thread. Everything on the desktop
// side is read only (see `DesktopDownloadsImporter`). Results carry a
// generation: a scan or import that is superseded (sign-out stops the store)
// publishes nothing.
extension DownloadsStore {
    /// Whether this platform has a desktop app whose downloads can be
    /// imported. The row is not shown elsewhere.
    public static var supportsDesktopImport: Bool {
        PlatformStorage.supportsDesktopDownloadsImport
    }

    /// Looks at the desktop app's own folder without asking the user. A
    /// sandboxed app may not read it: the state is then `.unreadable` and the
    /// user chooses the folder.
    public func refreshDesktopDownloads() async {
        guard Self.supportsDesktopImport, !desktopImport.isBusy else { return }
        guard let location = desktopLocator() else {
            desktopLocation = nil
            desktopImport = .unreadable
            return
        }
        await scanDesktopDownloads(at: location)
    }

    /// Looks at a folder the user chose: the desktop app's data folder or its
    /// `AudioCache`. Access to it lasts for this session only.
    public func chooseDesktopDownloads(at url: URL) async {
        guard Self.supportsDesktopImport, !desktopImport.isBusy else { return }
        guard let location = DesktopDataLocator.location(forPicked: url) else {
            desktopImport = .unreadable
            return
        }
        await scanDesktopDownloads(at: location)
    }

    /// Looks again at the folder used last (the chosen one, or the default
    /// place): after a cancelled import to carry on, or once space was freed.
    /// Without one, starts over at the default place.
    public func rescanDesktopDownloads() async {
        guard Self.supportsDesktopImport, !desktopImport.isBusy else { return }
        guard let location = desktopLocation else {
            await refreshDesktopDownloads()
            return
        }
        await scanDesktopDownloads(at: location)
    }

    /// Copies the desktop app's downloads into this app's cache and registers
    /// them as downloads. Safe to repeat: songs that are here already are not
    /// copied again.
    public func importDesktopDownloads() async {
        guard Self.supportsDesktopImport, !desktopImport.isBusy else { return }
        guard let location = desktopLocation ?? desktopLocator() else {
            desktopImport = .unreadable
            return
        }

        desktopGeneration &+= 1
        let generation = desktopGeneration
        let cancellation = DesktopImportCancellation()
        desktopCancellation = cancellation
        desktopImport = .importing(
            DesktopImportProgress(completed: 0, total: 0, bytesCopied: 0, totalBytes: 0)
        )

        let importer = makeDesktopImporter(for: location)
        let outcome = await Task.detached(priority: .utility) { [weak self] in
            Result {
                try importer.importAudioCache(
                    progress: { progress in
                        Task { @MainActor [weak self] in
                            self?.applyDesktopProgress(progress, generation: generation)
                        }
                    },
                    cancel: { cancellation.isCancelled }
                )
            }
        }.value

        // The index changed whatever happened next.
        reloadAfterDesktopImport()
        await refreshUsage()
        guard generation == desktopGeneration else { return }
        desktopCancellation = nil

        switch outcome {
        case let .success(result):
            desktopLocation = location
            desktopImport = .finished(result)
        case let .failure(error):
            desktopImport = Self.desktopState(for: error)
        }
    }

    /// Stops a running import after the song it is copying. Songs completed so
    /// far stay imported; a later import carries on from there.
    public func cancelDesktopImport() {
        desktopCancellation?.cancel()
    }

    /// Forgets the folder and cancels whatever runs (sign-out, account
    /// switch). The picked folder's access was never persisted.
    func resetDesktopImport() {
        desktopCancellation?.cancel()
        desktopCancellation = nil
        desktopGeneration &+= 1
        desktopLocation = nil
        desktopImport = Self.supportsDesktopImport ? .idle : .unavailable
    }

    // MARK: Scanning

    private func scanDesktopDownloads(at location: DesktopDataLocation) async {
        desktopGeneration &+= 1
        let generation = desktopGeneration
        desktopImport = .scanning

        let importer = makeDesktopImporter(for: location)
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try importer.scanAndPlan() }
        }.value
        guard generation == desktopGeneration else { return }

        switch outcome {
        case let .success(found):
            desktopLocation = location
            guard !found.scan.entries.isEmpty else {
                desktopImport = .empty(isPicked: location.isPicked)
                return
            }
            desktopImport = .ready(DesktopDownloadsSummary(
                songCount: found.scan.songCount,
                totalBytes: found.scan.totalBytes,
                importableCount: found.plan.pendingCount,
                importableBytes: found.plan.copyBytes,
                skipped: found.scan.skipped,
                isPicked: location.isPicked
            ))
        case let .failure(error):
            desktopLocation = nil
            desktopImport = Self.desktopState(for: error)
        }
    }

    private func makeDesktopImporter(for location: DesktopDataLocation) -> DesktopDownloadsImporter {
        var importer = DesktopDownloadsImporter(
            source: location,
            storage: audio.storageLayout,
            index: library.cacheMetaRepository(),
            now: now
        )
        if let desktopTransfer { importer.transfer = desktopTransfer }
        if let desktopAvailableCapacity { importer.availableCapacity = desktopAvailableCapacity }
        return importer
    }

    private func applyDesktopProgress(_ progress: DesktopImportProgress, generation: UInt64) {
        guard generation == desktopGeneration,
              case let .importing(current) = desktopImport,
              // Updates hop threads and may arrive out of order.
              progress.completed >= current.completed else { return }
        desktopImport = .importing(progress)
    }

    private static func desktopState(for error: Error) -> DesktopImportState {
        switch error as? DesktopImportError {
        case .sourceUnreadable:
            return .unreadable
        case let known?:
            return .failed(known)
        case nil:
            return .failed(.storageUnavailable)
        }
    }
}
