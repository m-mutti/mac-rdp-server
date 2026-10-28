import Testing
@testable import MacRDPKit

struct VideoPacingTests {
    @Test func sharperRaisesTheBudgetWhilePreservingCongestionControl() {
        var pacing = VideoPacing()
        let balanced = pacing.bitrate(pixels: 1920 * 1080, monitors: 2)
        pacing.preset = .sharper
        let sharper = pacing.bitrate(pixels: 1920 * 1080, monitors: 2)
        #expect(sharper > balanced)
        for monitors in [1, 2, 4, 8, 16] {
            #expect(pacing.bitrate(pixels: 3840 * 2160, monitors: monitors) * monitors <=
                    VideoQuality.sharper.sessionBitrateLimit)
        }
        for second in 1...12 {
            pacing.update(now: Double(second), baselineMS: 55, delayMS: 300,
                          bytesInFlight: 300_000, byteLimit: 350_000,
                          acknowledgements: UInt64(second))
        }
        #expect(pacing.bitrate(pixels: 1920 * 1080, monitors: 2) < sharper)
        #expect(pacing.frameRate == 60)
        let factor = pacing.quality
        pacing.preset = .balanced
        #expect(pacing.quality == factor)
    }

    @Test func sustainedBytePressureReducesBitrateWithoutReducingMotionRate() {
        var pacing = VideoPacing()
        let original = pacing.bitrate(pixels: 1920 * 1080, monitors: 2)
        for second in 1...12 {
            pacing.update(now: Double(second), baselineMS: 55, delayMS: 300,
                          bytesInFlight: 300_000, byteLimit: 350_000,
                          acknowledgements: UInt64(second))
            #expect(pacing.frameRate == 60)
        }
        #expect(pacing.bitrate(pixels: 1920 * 1080, monitors: 2) < Int(Double(original) * 0.6))
        for second in 13...30 {
            // Fresh ACKs with little queued data mean delivery has caught up,
            // even if the delay estimate still contains earlier slow frames.
            pacing.update(now: Double(second), baselineMS: 55, delayMS: 180,
                          bytesInFlight: 1_000, byteLimit: 350_000,
                          acknowledgements: UInt64(second))
        }
        #expect(pacing.quality == 1)
    }

    @Test func ackJitterWithTinyFramesDoesNotThrottleTheDesktop() {
        var pacing = VideoPacing()
        for second in 1...30 {
            pacing.update(now: Double(second), baselineMS: 52, delayMS: 235,
                          bytesInFlight: 8_000, byteLimit: 262_144,
                          acknowledgements: UInt64(second))
        }
        #expect(pacing.quality == 1)
        #expect(pacing.frameRate == 60)
    }

    @Test func shortWindowTransitionDoesNotReduceQuality() {
        var pacing = VideoPacing()
        for second in 1...2 {
            pacing.update(now: Double(second), baselineMS: 52, delayMS: 298,
                          bytesInFlight: 300_000, byteLimit: 350_000,
                          acknowledgements: UInt64(second))
        }
        pacing.update(now: 3, baselineMS: 52, delayMS: 90, bytesInFlight: 2_000,
                      byteLimit: 350_000, acknowledgements: 3)
        #expect(pacing.quality == 1)
        #expect(pacing.frameRate == 60)
    }

    @Test func staleAcknowledgementsCannotBeReusedToThrottleOrRecover() {
        var pacing = VideoPacing()
        for second in 1...30 {
            pacing.update(now: Double(second), baselineMS: 52, delayMS: 298,
                          bytesInFlight: 300_000, byteLimit: 350_000, acknowledgements: 1)
        }
        #expect(pacing.quality == 1)
        for second in 31...40 {
            pacing.update(now: Double(second), baselineMS: 52, delayMS: 298,
                          bytesInFlight: 300_000, byteLimit: 350_000,
                          acknowledgements: UInt64(second))
        }
        let reduced = pacing.quality
        #expect(reduced < 1)
        for second in 41...80 {
            pacing.update(now: Double(second), baselineMS: 52, delayMS: 55,
                          bytesInFlight: 0, byteLimit: 350_000, acknowledgements: 40)
        }
        #expect(pacing.quality == reduced)
    }

    @Test func largeTransitionFramesHaveRoomToOverlapAndTheAllowanceDecays() {
        var pacing = VideoPacing()
        let normal = pacing.byteLimit(monitors: 2, baselineMS: 55, aggregateBitrate: 4_000_000, now: 1)
        pacing.recordFrame(bytes: 125 * 1024, now: 1)
        let burst = pacing.byteLimit(monitors: 2, baselineMS: 55, aggregateBitrate: 4_000_000, now: 1)
        #expect(burst > normal)
        #expect(burst > 2 * 125 * 1024)
        let afterIdle = pacing.byteLimit(monitors: 2, baselineMS: 55, aggregateBitrate: 4_000_000, now: 60)
        #expect(afterIdle == normal)
        pacing.recordFrame(bytes: 8_000_000, now: 61)
        #expect(pacing.byteLimit(monitors: 16, baselineMS: 1000,
                                aggregateBitrate: 20_000_000, now: 61) <= 2 * 1024 * 1024)
    }

    @Test func monitorBudgetsShareAnAggregateCeiling() {
        let pacing = VideoPacing()
        for monitors in [1, 2, 4, 8, 16] {
            let total = pacing.bitrate(pixels: 3840 * 2160, monitors: monitors) * monitors
            #expect(total <= 20_000_000)
        }
    }
}
