import Foundation

class PlaybackStatePersistence {
    let repository: PlaybackStateRepository

    private let persistQueue = DispatchQueue(label: "com.aonsoku.PlaybackPersistence", qos: .utility)
    private var debounceTimer: DispatchWorkItem?
    private var progressTimer: DispatchSourceTimer?
    private var lastSavedProgress: Double = 0
    private var pendingProgress: Double = 0
    private var fullStateDirty = false
    private var stateProvider: (() -> PlaybackPersistState?)?

    private let fullStateDebounceInterval: TimeInterval = 0.5
    private let progressSaveInterval: TimeInterval = 5.0

    init(repository: PlaybackStateRepository) {
        self.repository = repository
    }

    func setStateProvider(_ provider: @escaping () -> PlaybackPersistState?) {
        self.stateProvider = provider
    }

    func markStateDirty() {
        fullStateDirty = true
        scheduleFullStateSave()
    }

    func updateProgress(_ time: Double) {
        pendingProgress = time
    }

    func flushNow(wait: Bool = false) {
        debounceTimer?.cancel()
        debounceTimer = nil

        if wait {
            persistQueue.sync { performFullSave() }
        } else {
            persistQueue.async { [weak self] in
                self?.performFullSave()
            }
        }
    }

    func startProgressTracking() {
        stopProgressTracking()

        let timer = DispatchSource.makeTimerSource(queue: persistQueue)
        timer.schedule(deadline: .now() + progressSaveInterval, repeating: progressSaveInterval)
        timer.setEventHandler { [weak self] in
            self?.saveProgressIfNeeded()
        }
        timer.resume()
        progressTimer = timer
    }

    func stopProgressTracking() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    // MARK: - Private

    private func scheduleFullStateSave() {
        debounceTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.persistQueue.async {
                self?.performFullSave()
            }
        }
        debounceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fullStateDebounceInterval, execute: work)
    }

    private func performFullSave() {
        guard let state = stateProvider?() else { return }
        fullStateDirty = false
        lastSavedProgress = state.currentTime

        do {
            try repository.save(state)
        } catch {
            NativeLogger.shared.error("Failed to save playback state: \(error)", source: "Persistence")
        }
    }

    private func saveProgressIfNeeded() {
        let progress = pendingProgress
        guard abs(progress - lastSavedProgress) > 0.5 else { return }
        lastSavedProgress = progress

        if fullStateDirty {
            performFullSave()
            return
        }

        do {
            try repository.saveProgress(progress)
        } catch {
            NativeLogger.shared.error("Failed to save progress: \(error)", source: "Persistence")
        }
    }
}
