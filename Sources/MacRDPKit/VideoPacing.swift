import Foundation

public enum VideoQuality: String, CaseIterable, Sendable {
    case balanced, sharper

    public var sessionBitrateLimit: Int { self == .sharper ? 32_000_000 : 20_000_000 }
}

/// Keep motion at 60 Hz. Reduce bitrate only when fresh acknowledgements and
/// sustained byte pressure agree that a queue is growing, not for RTT jitter.
public struct VideoPacing: Sendable {
    public var preset: VideoQuality = .balanced
    public private(set) var quality = 1.0
    public let frameRate = 60
    private var lastUpdate = 0.0
    private var lastAcknowledgements: UInt64 = 0
    private var peakOutstandingBytes = 0
    private var congestedSamples = 0
    private var healthySamples = 0
    private var recentFrameBytes = 0.0
    private var lastFrameObservation = 0.0

    public init() {}

    public mutating func update(now: Double, baselineMS: Double, delayMS: Double,
                                bytesInFlight: Int, byteLimit: Int, acknowledgements: UInt64) {
        // Don't carry a burst observation across an idle period.
        if now - lastUpdate > 2 { peakOutstandingBytes = 0 }
        peakOutstandingBytes = max(peakOutstandingBytes, bytesInFlight)
        guard now - lastUpdate >= 1, baselineMS > 0, delayMS > 0,
              acknowledgements != lastAcknowledgements else { return }
        lastUpdate = now
        lastAcknowledgements = acknowledgements
        let peak = peakOutstandingBytes
        peakOutstandingBytes = bytesInFlight
        let pressure = peak >= max(128 * 1024, byteLimit * 3 / 4)
        let excess = max(0, delayMS - baselineMS)
        if pressure && excess > max(60, baselineMS * 0.5) {
            congestedSamples += 1
            healthySamples = 0
            // A window/Space transition is a short burst, not sustained load.
            if congestedSamples >= 3 {
                quality = max(0.35, quality * 0.85)
                congestedSamples = 0
            }
        } else {
            congestedSamples = 0
            if !pressure || excess < 35 {
                healthySamples += 1
                if healthySamples >= 2 {
                    quality = min(1, quality + 0.1)
                    healthySamples = 0
                }
            } else {
                healthySamples = 0
            }
        }
    }

    public mutating func recordFrame(bytes: Int, now: Double) {
        decayFrameSize(now: now)
        recentFrameBytes = max(recentFrameBytes, Double(bytes))
    }

    /// The normal bandwidth-delay allowance plus two observed large frames.
    /// This allowance doesn't collapse with quality or grow without a bound.
    public mutating func byteLimit(monitors: Int, baselineMS: Double,
                                    aggregateBitrate: Int, now: Double) -> Int {
        decayFrameSize(now: now)
        let seconds = max(0.05, baselineMS / 1000 + 0.03)
        let normal = Double(aggregateBitrate) * seconds / 8
        let burst = min(recentFrameBytes * 2, 1_048_576)
        let floor = 128 * 1024 * max(2, monitors)
        return min(2 * 1024 * 1024, max(floor, Int(normal + burst)))
    }

    private mutating func decayFrameSize(now: Double) {
        let elapsed = max(0, now - lastFrameObservation)
        recentFrameBytes *= exp(-elapsed / 5)
        lastFrameObservation = now
    }

    /// Bounds aggregate bitrate even when many displays animate at once.
    public func bitrate(pixels: Int, monitors: Int) -> Int {
        let ceiling = preset == .sharper
            ? min(max(pixels * 8, 6_000_000), 20_000_000)
            : min(max(pixels * 4, 4_000_000), 12_000_000)
        let share = min(ceiling, preset.sessionBitrateLimit / max(1, monitors))
        return max(500_000, Int(Double(share) * quality))
    }
}
