import Foundation
import MacRDPKit

/// One scheduled main-thread drain per session, with bounded batches so other
/// main-thread work gets a turn even after an input burst.
final class PendingInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = InputEventBuffer()
    private var scheduled = false

    func append(_ events: [RDPInputEvent]) -> Bool {
        lock.withLock {
            buffer.append(events)
            guard !scheduled, !buffer.isEmpty else { return false }
            scheduled = true
            return true
        }
    }

    func take() -> (events: [RDPInputEvent], more: Bool) {
        lock.withLock {
            let events = buffer.take()
            let more = !buffer.isEmpty
            scheduled = more
            return (events, more)
        }
    }
}
