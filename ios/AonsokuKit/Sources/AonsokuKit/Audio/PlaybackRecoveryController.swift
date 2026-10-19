import AVFoundation
import Foundation

protocol PlaybackRecoveryDelegate: AnyObject {
    func recoverySeek(_ controller: PlaybackRecoveryController, to time: CMTime, generation: Int)
    func recoveryReload(_ controller: PlaybackRecoveryController, generation: Int, savedPosition: CMTime)
    func recoveryExhausted(_ controller: PlaybackRecoveryController, generation: Int)
    func recoverySetBuffering(_ controller: PlaybackRecoveryController, isBuffering: Bool)
    func recoveryDidBegin(_ controller: PlaybackRecoveryController)
    func recoveryDidSucceed(_ controller: PlaybackRecoveryController)
}

enum RecoveryState: Equatable {
    case idle
    case level1(attempt: Int)
    case level2(attempt: Int)
    case gaveUp
}

enum RecoverySourceKind {
    case stream
    case radio
    case nativeFile
}

class PlaybackRecoveryController {
    typealias RecoveryScheduler = (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> DispatchWorkItem

    weak var delegate: PlaybackRecoveryDelegate?

    private(set) var state: RecoveryState = .idle
    private(set) var generation: Int = 0

    private let level1MaxAttempts = 3
    private let level2MaxAttempts = 2
    private let level1BaseDelay: TimeInterval = 2.0
    private let level2BaseDelay: TimeInterval = 3.0
    private let foregroundProgressTimeout: TimeInterval = 10.0
    private let backgroundProgressTimeout: TimeInterval = 20.0
    private let likelyToKeepUpDebounceInterval: TimeInterval = 1.5

    private var savedPosition: CMTime = .zero
    private var sourceKind: RecoverySourceKind = .stream
    private var isBackground = false

    private var recoveryTimer: DispatchWorkItem?
    private var progressMonitorTimer: DispatchSourceTimer?
    private var likelyToKeepUpDebounceTimer: DispatchWorkItem?
    private let recoveryScheduler: RecoveryScheduler

    private var lastProgressTime: CMTime = .zero
    private var lastProgressAdvanceDate: Date?
    private var isMonitoringProgress = false

    init(recoveryScheduler: @escaping RecoveryScheduler = { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }) {
        self.recoveryScheduler = recoveryScheduler
    }

    // MARK: - Public API

    func triggerRecovery(currentTime: CMTime, generation: Int, sourceKind: RecoverySourceKind) {
        guard self.generation == generation || state == .idle else { return }

        if state == .idle {
            self.generation = generation
            self.sourceKind = sourceKind
            savedPosition = currentTime
            delegate?.recoveryDidBegin(self)
            delegate?.recoverySetBuffering(self, isBuffering: true)
        } else if recoveryTimer != nil {
            return
        }

        switch sourceKind {
        case .radio:
            escalateRadio()
        case .nativeFile:
            escalateToLevel2()
        case .stream:
            escalateStream()
        }
    }

    func reportProgress(at time: CMTime, generation: Int) {
        guard generation == self.generation || state == .idle else { return }

        let seconds = CMTimeGetSeconds(time)
        let lastSeconds = CMTimeGetSeconds(lastProgressTime)

        if abs(seconds - lastSeconds) > 0.01 {
            lastProgressTime = time
            lastProgressAdvanceDate = Date()

            if state != .idle {
                handleRecoverySuccess()
            }
        }
    }

    func reportPlaybackResumed(generation: Int) {
        guard generation == self.generation else { return }
        guard state != .idle else { return }
        handleRecoverySuccess()
    }

    func reportLikelyToKeepUp(generation: Int) {
        guard generation == self.generation else { return }
        guard state != .idle else { return }

        likelyToKeepUpDebounceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.likelyToKeepUpDebounceTimer = nil
        }
        likelyToKeepUpDebounceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + likelyToKeepUpDebounceInterval, execute: work)
    }

    func reportUserPause() {
        stopProgressMonitoring()
        guard state != .idle else { return }
        reset()
    }

    func reportUserSeek() {
        guard state != .idle else { return }
        reset()
    }

    func reloadDidComplete(success: Bool, generation: Int) {
        guard generation == self.generation, case .level2 = state else { return }
        if !success {
            escalateToLevel2()
        }
    }

    func setBackground(_ isBackground: Bool) {
        self.isBackground = isBackground
    }

    func startProgressMonitoring(generation: Int, sourceKind: RecoverySourceKind) {
        stopProgressMonitoring()
        self.generation = generation
        self.sourceKind = sourceKind
        lastProgressAdvanceDate = Date()
        isMonitoringProgress = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.checkProgressTimeout()
        }
        timer.resume()
        progressMonitorTimer = timer
    }

    func stopProgressMonitoring() {
        progressMonitorTimer?.cancel()
        progressMonitorTimer = nil
        isMonitoringProgress = false
    }

    func reset() {
        cancelRecoveryTimer()
        likelyToKeepUpDebounceTimer?.cancel()
        likelyToKeepUpDebounceTimer = nil
        state = .idle
        savedPosition = .zero
    }

    // MARK: - Private: Escalation

    private func escalateStream() {
        switch state {
        case .idle, .level1:
            let attempt = nextLevel1Attempt()
            if let attempt {
                scheduleLevel1(attempt: attempt)
            } else {
                escalateToLevel2()
            }
        case .level2:
            let attempt = nextLevel2Attempt()
            if let attempt {
                scheduleLevel2(attempt: attempt)
            } else {
                giveUp()
            }
        case .gaveUp:
            break
        }
    }

    private func escalateRadio() {
        switch state {
        case .idle, .level1:
            let attempt = nextLevel1Attempt()
            if let attempt {
                scheduleLevel1(attempt: attempt)
            } else {
                giveUp()
            }
        case .level2, .gaveUp:
            giveUp()
        }
    }

    private func escalateToLevel2() {
        let attempt = nextLevel2Attempt()
        if let attempt {
            scheduleLevel2(attempt: attempt)
        } else {
            giveUp()
        }
    }

    private func nextLevel1Attempt() -> Int? {
        let current: Int
        if case .level1(let a) = state { current = a } else { current = 0 }
        let next = current + 1
        return next <= level1MaxAttempts ? next : nil
    }

    private func nextLevel2Attempt() -> Int? {
        let current: Int
        if case .level2(let a) = state { current = a } else { current = 0 }
        let next = current + 1
        return next <= level2MaxAttempts ? next : nil
    }

    // MARK: - Private: Scheduling

    private func scheduleLevel1(attempt: Int) {
        cancelRecoveryTimer()
        state = .level1(attempt: attempt)

        let delay = level1BaseDelay * pow(2.0, Double(attempt - 1))
        let gen = generation

        let work = recoveryScheduler(delay) { [weak self] in
            guard let self, self.generation == gen, self.state == .level1(attempt: attempt) else { return }
            self.recoveryTimer = nil
            self.delegate?.recoverySeek(self, to: self.savedPosition, generation: gen)
        }
        recoveryTimer = work
    }

    private func scheduleLevel2(attempt: Int) {
        cancelRecoveryTimer()
        state = .level2(attempt: attempt)

        let baseDelay = isBackground ? level2BaseDelay * 2.0 : level2BaseDelay
        let delay = baseDelay * pow(2.0, Double(attempt - 1))
        let gen = generation

        let work = recoveryScheduler(delay) { [weak self] in
            guard let self, self.generation == gen, self.state == .level2(attempt: attempt) else { return }
            self.recoveryTimer = nil
            self.delegate?.recoveryReload(self, generation: gen, savedPosition: self.savedPosition)
        }
        recoveryTimer = work
    }

    private func giveUp() {
        cancelRecoveryTimer()
        state = .gaveUp
        let gen = generation
        delegate?.recoverySetBuffering(self, isBuffering: false)
        delegate?.recoveryExhausted(self, generation: gen)
    }

    // MARK: - Private: Success

    private func handleRecoverySuccess() {
        cancelRecoveryTimer()
        likelyToKeepUpDebounceTimer?.cancel()
        likelyToKeepUpDebounceTimer = nil
        state = .idle
        savedPosition = .zero
        delegate?.recoverySetBuffering(self, isBuffering: false)
        delegate?.recoveryDidSucceed(self)
    }

    // MARK: - Private: Progress Timeout

    private func checkProgressTimeout() {
        guard state == .idle else { return }
        guard let lastAdvance = lastProgressAdvanceDate else { return }

        let timeout = isBackground ? backgroundProgressTimeout : foregroundProgressTimeout
        let elapsed = Date().timeIntervalSince(lastAdvance)

        if elapsed >= timeout {
            triggerRecovery(currentTime: lastProgressTime, generation: generation, sourceKind: sourceKind)
        }
    }

    // MARK: - Private: Timers

    private func cancelRecoveryTimer() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
    }
}
