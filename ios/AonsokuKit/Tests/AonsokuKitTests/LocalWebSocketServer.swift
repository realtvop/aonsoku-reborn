import Foundation
import Network

/// A WebSocket server on the loopback interface, so the realtime transport
/// can be tested against a real connection without any network access.
///
/// It records the ticket of every `hello` envelope it receives. It answers
/// pings unless told otherwise: with `answersPings` off the connection stays
/// open and the server keeps reading, but nothing comes back, which is how a
/// connection that died while the machine slept looks from the client.
final class LocalWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "aonsoku.tests.local-websocket-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var closedConnections: Set<ObjectIdentifier> = []
    private var pings = 0
    private var answering = true
    private var tickets: [String] = []
    private var boundPort: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolWebSocket.Options(),
            at: 0
        )
        listener = try NWListener(using: parameters)
    }

    deinit {
        stop()
    }

    /// Starts listening and returns once the port is known.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedFailure()
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw LocalWebSocketServerError.didNotStart
        }
        if let error = failure.get() { throw error }
        guard let port = listener.port?.rawValue else {
            throw LocalWebSocketServerError.didNotStart
        }
        lock.withLock { boundPort = port }
    }

    /// Stops listening and drops every connection.
    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            let open = connections
            connections = []
            return open
        }
        for connection in open { connection.cancel() }
    }

    /// The port the server listens on, once started.
    var port: UInt16 {
        lock.withLock { boundPort }
    }

    /// The address of the server, without a path.
    var url: String {
        "ws://127.0.0.1:\(port)"
    }

    /// Whether pings get a pong. On by default.
    var answersPings: Bool {
        get { lock.withLock { answering } }
        set { lock.withLock { answering = newValue } }
    }

    /// Connections accepted so far, closed ones included.
    var connectionCount: Int {
        lock.withLock { connections.count }
    }

    /// Connections the client has closed or that failed.
    var closedConnectionCount: Int {
        lock.withLock { closedConnections.count }
    }

    /// Pings received so far, answered or not.
    var pingCount: Int {
        lock.withLock { pings }
    }

    /// The ticket of each `hello` envelope received, in order.
    var helloTickets: [String] {
        lock.withLock { tickets }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.markClosed(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if error != nil {
                self.markClosed(connection)
                return
            }
            let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .ping:
                self.receivedPing(data, on: connection)
            case .text:
                self.receivedText(data)
            case .close:
                self.markClosed(connection)
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func receivedPing(_ payload: Data?, on connection: NWConnection) {
        let shouldAnswer = lock.withLock { () -> Bool in
            pings += 1
            return answering
        }
        guard shouldAnswer else { return }
        let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [pong]
        )
        connection.send(
            content: payload,
            contentContext: context,
            isComplete: true,
            completion: .idempotent
        )
    }

    private func receivedText(_ data: Data?) {
        guard let data,
              let envelope = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              envelope["type"] as? String == "hello",
              let ticket = envelope["ticket"] as? String else { return }
        lock.withLock { tickets.append(ticket) }
    }

    private func markClosed(_ connection: NWConnection) {
        _ = lock.withLock {
            closedConnections.insert(ObjectIdentifier(connection))
        }
    }
}

enum LocalWebSocketServerError: Error {
    case didNotStart
}

private final class LockedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) { lock.withLock { self.error = error } }
    func get() -> Error? { lock.withLock { error } }
}
