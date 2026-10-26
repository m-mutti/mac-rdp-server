import Foundation
import MacRDPKit

/// Request/response exchanges over a session's WebAuthn channel. The client
/// answers in order and responses carry no request ID, so waiters queue up in
/// order; an abandoned request keeps its place, so its late answer is dropped
/// instead of being handed to the next request.
final class WebAuthnRelay: @unchecked Sendable {
    struct Disconnected: Error {}

    /// Only touched while holding the relay's lock.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<Data, Error>?
        var cancelled = false
    }

    private let link: SessionLink
    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var closed = false

    init(link: SessionLink) {
        self.link = link
    }

    /// Sends one MS-RDPEWA request message and returns the client's response message.
    func exchange(_ message: Data) async throws -> Data {
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let refusal: Error? = lock.withLock {
                    if closed { return Disconnected() }
                    if waiter.cancelled { return CancellationError() }
                    waiter.continuation = continuation
                    waiters.append(waiter)
                    return nil
                }
                if let refusal { return continuation.resume(throwing: refusal) }
                link.sendWebAuthn(message)
            }
        } onCancel: {
            let continuation = lock.withLock {
                waiter.cancelled = true
                defer { waiter.continuation = nil }
                return waiter.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// A response arrived from the client (FreeRDP's session thread).
    func deliver(_ response: Data) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            guard !waiters.isEmpty else { return nil }
            let waiter = waiters.removeFirst()
            defer { waiter.continuation = nil }
            return waiter.continuation
        }
        continuation?.resume(returning: response)
    }

    /// The session ended: nothing more will arrive.
    func close() {
        let pending = lock.withLock {
            closed = true
            defer { waiters.removeAll() }
            return waiters.compactMap(\.continuation)
        }
        for continuation in pending { continuation.resume(throwing: Disconnected()) }
    }
}
