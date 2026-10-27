import Foundation

public enum TailscaleReadinessError: LocalizedError, Equatable {
    case loginRequired, approvalRequired, connectionTimedOut, subnetRoutesDisabled
    case missingSubnetRoute(String)
    case proxyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .loginRequired: "Sign in to Tailscale before connecting to this server."
        case .approvalRequired: "This Tailscale device is waiting for approval."
        case .connectionTimedOut: "Tailscale did not become ready in time."
        case .subnetRoutesDisabled: "Enable Accept Subnet Routes to reach this server through Tailscale."
        case let .missingSubnetRoute(host): "Tailscale has no approved subnet route to \(host)."
        case let .proxyUnavailable(reason): "The Tailscale proxy is unavailable: \(reason)"
        }
    }
}

enum TailscaleReadinessCheck { case ready, waiting(TailscaleReadinessError) }

/// Requests for the same destination share connection work, but each caller can
/// cancel its own wait immediately. The last waiter cancels the shared worker.
actor TailscaleReadinessGate {
    private struct Flight {
        let id: UUID
        var worker: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private var flights: [String: Flight] = [:]

    func waiterCount(for host: String) -> Int { flights[host]?.waiters.count ?? 0 }

    func wait(
        for host: String, timeout: Duration = .seconds(20), interval: Duration = .milliseconds(250),
        probe: @escaping @Sendable () async throws -> TailscaleReadinessCheck
    ) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flights[host] != nil {
                    flights[host]?.waiters[waiterID] = continuation
                    return
                }
                let flightID = UUID()
                flights[host] = Flight(id: flightID, waiters: [waiterID: continuation])
                flights[host]?.worker = Task {
                    let deadline = ContinuousClock.now.advanced(by: timeout)
                    var pending = TailscaleReadinessError.connectionTimedOut
                    do {
                        while true {
                            try Task.checkCancellation()
                            switch try await probe() {
                            case .ready:
                                finish(host, id: flightID, result: .success(()))
                                return
                            case let .waiting(reason): pending = reason
                            }
                            guard ContinuousClock.now < deadline else { throw pending }
                            try await Task.sleep(for: min(interval, ContinuousClock.now.duration(to: deadline)))
                        }
                    } catch { finish(host, id: flightID, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.cancel(host, waiterID: waiterID) }
        }
    }

    func cancelAll() {
        let old = flights
        flights.removeAll()
        for flight in old.values {
            flight.worker?.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private func cancel(_ host: String, waiterID: UUID) {
        guard let waiter = flights[host]?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flights[host]?.waiters.isEmpty == true {
            flights.removeValue(forKey: host)?.worker?.cancel()
        }
    }

    private func finish(_ host: String, id: UUID, result: Result<Void, Error>) {
        guard flights[host]?.id == id, let flight = flights.removeValue(forKey: host) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }
}
