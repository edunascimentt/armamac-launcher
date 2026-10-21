import Foundation
import Network

/// A single-peer UDP channel with async send/receive and per-read timeouts.
///
/// `NWConnection` is callback-based and not `Sendable`, so it is confined to this actor and
/// bridged to structured concurrency with continuations.
actor UDPSocket {
    enum SocketError: Error, LocalizedError {
        case timedOut
        case cancelled
        case setupFailed(String)
        case sendFailed(String)
        case receiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .timedOut: "The server did not answer in time."
            case .cancelled: "The query was cancelled."
            case let .setupFailed(reason): "Could not open a UDP socket: \(reason)"
            case let .sendFailed(reason): "Could not send the query: \(reason)"
            case let .receiveFailed(reason): "Could not read the reply: \(reason)"
            }
        }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let connectTimeout: Duration
    private var didStart = false
    private var isClosed = false
    /// Datagrams that arrived before anyone asked for them.
    private var inbox: [Data] = []

    /// The single pending reader, tagged so a late timeout cannot cancel a newer read.
    private struct Waiter {
        var token: UInt64
        var continuation: CheckedContinuation<Data, Error>
    }

    private var waiter: Waiter?
    private var nextToken: UInt64 = 0
    private var timeoutTask: Task<Void, Never>?

    init(
        host: String,
        port: UInt16,
        connectTimeout: Duration = .seconds(5),
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        self.connectTimeout = connectTimeout
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters.udp
        parameters.serviceClass = .responsiveData
        // Query traffic is short-lived; do not let the stack wait on a slow path.
        parameters.expiredDNSBehavior = .allow
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
        self.queue = queue
    }

    deinit {
        connection.forceCancel()
    }

    /// Brings the connection up, giving DNS and routing a bounded amount of time.
    ///
    /// Without a deadline an unresolvable host leaves the connection in `.preparing` or
    /// `.waiting` forever, which would pin a query slot for the life of the process.
    private func start() async throws {
        guard !didStart else { return }
        didStart = true

        let deadline = connectTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // `resumed` makes resumption single-shot, so the deadline closure is left to
            // fire harmlessly rather than being cancelled.
            let resumed = LockedFlag()
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(deadline.milliseconds))) {
                if resumed.take() {
                    continuation.resume(
                        throwing: SocketError.setupFailed("timed out while connecting")
                    )
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.take() { continuation.resume() }
                case let .failed(error):
                    if resumed.take() {
                        continuation.resume(
                            throwing: SocketError.setupFailed(error.localizedDescription)
                        )
                    }
                case let .waiting(error):
                    // For UDP, "waiting" means no route or DNS failed; there is nothing to
                    // wait for on a fire-and-forget query socket.
                    if resumed.take() {
                        continuation.resume(
                            throwing: SocketError.setupFailed(error.localizedDescription)
                        )
                    }
                case .cancelled:
                    if resumed.take() { continuation.resume(throwing: SocketError.cancelled) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        pump()
    }

    /// Keeps a receive posted at all times so datagrams are never dropped between reads.
    private nonisolated func pump() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            Task { await self.deliver(data: data, error: error) }
        }
    }

    private func deliver(data: Data?, error: NWError?) {
        guard !isClosed else { return }
        if let data, !data.isEmpty {
            if let waiter {
                self.waiter = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                waiter.continuation.resume(returning: data)
            } else {
                inbox.append(data)
            }
        } else if let error, let waiter {
            self.waiter = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            waiter.continuation.resume(
                throwing: SocketError.receiveFailed(error.localizedDescription)
            )
            return
        }
        if error == nil { pump() }
    }

    func send(_ payload: Data) async throws {
        try await start()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SocketError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Waits for the next datagram, throwing `.timedOut` if none arrives in time.
    ///
    /// The timeout and cancellation both resolve the *stored* continuation rather than
    /// racing tasks: a cancelled child task would never resume its continuation, which
    /// would hang the caller forever.
    func receive(timeout: Duration) async throws -> Data {
        try await start()
        if !inbox.isEmpty { return inbox.removeFirst() }

        let token = nextToken
        nextToken &+= 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                    return
                }
                if waiter != nil {
                    // Callers are serialised through the actor; a second reader is a bug.
                    continuation.resume(throwing: SocketError.receiveFailed("concurrent read"))
                    return
                }
                waiter = Waiter(token: token, continuation: continuation)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(token: token)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(token: token) }
        }
    }

    /// Fails the pending read once its deadline passes.
    private func expire(token: UInt64) {
        guard let waiter, waiter.token == token else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: SocketError.timedOut)
    }

    private func abandon(token: UInt64) {
        guard let waiter, waiter.token == token else { return }
        self.waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        waiter.continuation.resume(throwing: SocketError.cancelled)
    }

    /// Send a request and wait for one reply, retrying on timeout.
    func request(_ payload: Data, timeout: Duration, retries: Int = 1) async throws -> Data {
        var lastError: Error = SocketError.timedOut
        for attempt in 0...max(0, retries) {
            do {
                try Task.checkCancellation()
                try await send(payload)
                return try await receive(timeout: timeout)
            } catch let error as SocketError where error.isRetryable && attempt < retries {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: SocketError.cancelled)
        }
        connection.stateUpdateHandler = nil
        connection.forceCancel()
    }
}

private extension UDPSocket.SocketError {
    var isRetryable: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

/// Tiny thread-safe one-shot flag, used to make continuation resumption single-shot.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// Returns true exactly once.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

extension Duration {
    /// Whole milliseconds, for APIs that predate `Duration`.
    var milliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
