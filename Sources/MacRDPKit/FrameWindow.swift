/// How many frames may be on their way to the client at once.
///
/// The client acknowledges a frame once it has decoded it, a network round
/// trip after it was sent. Allow too few and the frame rate stops at frames
/// ÷ round trip, with motion arriving in bursts: a few frames, then a pause
/// while the acknowledgements come back. Allow too many and frames queue up
/// when the network can't carry them, so the picture lags behind.
public enum FrameWindow {
    /// The virtual displays refresh at 60 Hz.
    static let frameTime = Duration.seconds(1) / 60
    /// Enough to keep a monitor at 60 fps through a 250 ms round trip.
    static let maxPerMonitor = 15

    /// - Parameters:
    ///   - aloneDelay: recent minimum acknowledgement delay, used as the
    ///     baseline for network and decoder latency. Zero until measured.
    ///   - delay: the same for all recent frames, which also counts any queue
    ///     building up.
    public static func limit(monitors: Int, aloneDelay: Duration, delay: Duration,
                             frameRate: Int = 60) -> Int {
        // A frame per monitor plus a little slack, which is plenty on a local network.
        let minimum = monitors + 2
        guard aloneDelay > .zero else { return minimum }
        // Enough frames to sustain the selected rate through the round trip.
        let interval = Duration.seconds(1) / max(1, frameRate)
        let perMonitor = min(Int((aloneDelay / interval).rounded(.up)) + 1, maxPerMonitor)
        // An ACK spike alone isn't evidence of a full video queue. Shrinking
        // this window as well as the byte budget caused stop-and-wait bursts.
        // SessionLink bounds byte pressure; retain enough frame slots for motion.
        return max(minimum, monitors * perMonitor)
    }
}
