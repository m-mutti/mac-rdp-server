import Testing
@testable import MacRDPKit

struct FrameWindowTests {
    func limit(_ monitors: Int, alone: Int, all: Int) -> Int {
        FrameWindow.limit(monitors: monitors, aloneDelay: .milliseconds(alone), delay: .milliseconds(all))
    }

    @Test func keepsTheLocalNetworkWindowUntilMeasured() {
        #expect(limit(1, alone: 0, all: 0) == 3)
        #expect(limit(2, alone: 4, all: 5) == 4)
    }

    @Test func coversTheRoundTripAt60fps() {
        // Through a relay frames take ~95 ms, so six are in the air at 60 fps.
        #expect(limit(1, alone: 95, all: 100) == 7)
        #expect(limit(2, alone: 95, all: 100) == 14)
        #expect(limit(1, alone: 1000, all: 1000) == FrameWindow.maxPerMonitor)
    }

    @Test func shrinksWhenAQueueBuilds() {
        #expect(limit(1, alone: 95, all: 140) == 7)
        #expect(limit(1, alone: 95, all: 160) == 4)
        #expect(limit(1, alone: 95, all: 400) == 3)
    }
}
