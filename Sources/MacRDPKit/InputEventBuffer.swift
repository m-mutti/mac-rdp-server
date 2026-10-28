import CoreGraphics

/// FIFO input batches. Consecutive hover positions can replace one another,
/// but keys, clicks, scrolling and drag paths must retain their ordering.
public struct InputEventBuffer: Sendable {
    private var events: [RDPInputEvent] = []
    private var readIndex = 0
    private var heldButtons: Set<CGMouseButton.RawValue> = []

    public init() {}
    public var isEmpty: Bool { readIndex == events.count }

    public mutating func append(_ incoming: [RDPInputEvent]) {
        for event in incoming {
            if case .move = event, heldButtons.isEmpty, !isEmpty,
               case .move = events.last! {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
            if case let .button(button, down, _) = event {
                if down { heldButtons.insert(button.cgButton.rawValue) }
                else { heldButtons.remove(button.cgButton.rawValue) }
            }
        }
    }

    public mutating func take(limit: Int = 128) -> [RDPInputEvent] {
        guard limit > 0, !isEmpty else { return [] }
        let end = readIndex + min(events.count - readIndex, limit)
        let batch = Array(events[readIndex..<end])
        readIndex = end
        if isEmpty {
            events.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 256 && readIndex >= events.count / 2 {
            events.removeFirst(readIndex)
            readIndex = 0
        }
        return batch
    }
}
