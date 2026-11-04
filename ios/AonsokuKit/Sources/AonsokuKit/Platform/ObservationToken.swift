import Foundation

/// Ends a platform observation when `cancel()` is called or when the token is
/// released, whichever comes first. Cancelling more than once is harmless.
final class ObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit { cancel() }
}
