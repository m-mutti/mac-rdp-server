import Dispatch
import Testing
import MacRDPKit
@testable import MacRDPHost

struct PendingInputTests {
    @Test func schedulesOneDrainForAnInputBurst() {
        let input = PendingInput()
        #expect(input.append([.move(.zero)]))
        #expect(!input.append([.move(.init(x: 5, y: 6))]))
        let batch = input.take()
        #expect(batch.events == [.move(.init(x: 5, y: 6))])
        #expect(!batch.more)
        #expect(input.append([.wheel(vertical: 120, horizontal: 0)]))
    }

    @Test func concurrentProducersDoNotLoseKeyEvents() {
        let input = PendingInput()
        DispatchQueue.concurrentPerform(iterations: 1024) { i in
            _ = input.append([.text(UInt16(i), down: true)])
        }
        var keys: Set<UInt16> = []
        var count = 0
        while true {
            let batch = input.take()
            #expect(batch.events.count <= 128)
            for event in batch.events {
                if case let .text(code, _) = event { keys.insert(code) }
                count += 1
            }
            if !batch.more { break }
            #expect(!input.append([]))
        }
        #expect(count == 1024)
        #expect(keys.count == 1024)
        #expect(input.append([.text(1, down: false)]))
    }
}
