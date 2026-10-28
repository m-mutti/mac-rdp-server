import CoreGraphics
import Testing
@testable import MacRDPKit

struct InputEventBufferTests {
    private func move(_ x: Int) -> RDPInputEvent { .move(CGPoint(x: x, y: 0)) }

    @Test func hoverBurstKeepsTheLatestPosition() {
        var buffer = InputEventBuffer()
        for i in 0..<10_000 { buffer.append([move(i)]) }
        #expect(buffer.take() == [move(9_999)])
        #expect(buffer.isEmpty)
    }

    @Test func keysClicksAndScrollingSeparateMovementGroups() {
        var buffer = InputEventBuffer()
        let key = RDPInputEvent.key(scancode: 30, extended: false, down: true)
        let wheel = RDPInputEvent.wheel(vertical: 120, horizontal: 0)
        let down = RDPInputEvent.button(.left, down: true, at: .zero)
        let up = RDPInputEvent.button(.left, down: false, at: .zero)
        buffer.append([move(1), move(2), key, move(3), move(4), wheel, down, move(5), move(6), up, move(7), move(8)])
        #expect(buffer.take() == [move(2), key, move(4), wheel, down, move(5), move(6), up, move(8)])
    }

    @Test func dragPathsRemainIntactAcrossDrains() {
        var buffer = InputEventBuffer()
        buffer.append([.button(.left, down: true, at: .zero), move(1)])
        #expect(buffer.take().count == 2)
        buffer.append([move(2), move(3)])
        #expect(buffer.take() == [move(2), move(3)])
        buffer.append([.button(.left, down: false, at: .zero), move(4), move(5)])
        #expect(buffer.take() == [.button(.left, down: false, at: .zero), move(5)])
    }

    @Test func boundedBatchesPreserveEveryKeyInOrder() {
        var buffer = InputEventBuffer()
        let events = (0..<1000).map { RDPInputEvent.text(UInt16($0), down: true) }
        buffer.append(events)
        var received: [RDPInputEvent] = []
        while !buffer.isEmpty {
            let batch = buffer.take()
            #expect(batch.count <= 128)
            received += batch
        }
        #expect(received == events)
        buffer.append([move(1), move(2)])
        #expect(buffer.take(limit: .max) == [move(2)])
    }
}
