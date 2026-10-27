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
    ///   - aloneDelay: how long the client takes to acknowledge a frame sent
    ///     while no other was in flight, which is the network and its decoder
    ///     alone. Zero until the first acknowledgement.
    ///   - delay: the same for all recent frames, which also counts any queue
    ///     building up.
    public static func limit(monitors: Int, aloneDelay: Duration, delay: Duration) -> Int {
        // A frame per monitor plus a little slack, which is plenty on a local network.
        let minimum = monitors + 2
        guard aloneDelay > .zero else { return minimum }
        // Enough frames to keep each monitor at 60 fps through the round trip.
        var perMonitor = min(Int((aloneDelay / frameTime).rounded(.up)) + 1, maxPerMonitor)
        // More than three frames' worth of queue means the network is full,
        // so send only about as fast as frames are getting through.
        if delay - aloneDelay > frameTime * 3 {
            perMonitor = Int(Double(perMonitor) * (aloneDelay / delay))
        }
        return max(minimum, monitors * perMonitor)
    }
}
