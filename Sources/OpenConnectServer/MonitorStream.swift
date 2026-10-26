import CoreMedia
import CoreVideo
import Foundation
import OpenConnectKit

/// Captures one virtual display, encodes it and hands frames to the session.
///
/// Flow control: at most one frame per monitor sits in the encoder, and none
/// is started while the client is behind. Newer captures replace older ones
/// that are still waiting, so the client always catches up to "now".
final class MonitorStream: @unchecked Sendable {
    let index: Int
    private let generation: UInt32
    private let link: SessionLink
    private let lock = NSLock()
    private var encoder: H264Encoder?
    private var capture: DisplayCapture?
    private var busy = false
    private var pending: CVPixelBuffer?
    /// Last captured picture, replayed when the client asks for a refresh
    /// while the screen is idle (ScreenCaptureKit sends nothing then).
    private var latest: CVPixelBuffer?

    init(index: Int, monitor: VirtualMonitor, spec: MonitorSpec, generation: UInt32, link: SessionLink,
         profile: H264Encoder.Settings.Profile) throws {
        self.index = index
        self.generation = generation
        self.link = link

        var settings = H264Encoder.Settings()
        settings.profile = profile
        // Desktop video is mostly static; this caps bursts (scrolling, video) by resolution.
        settings.bitrate = min(max(spec.width * spec.height * 8, 8_000_000), 40_000_000)
        encoder = try H264Encoder(
            width: spec.width, height: spec.height, settings: settings,
            output: { [weak self] unit in self?.encoded(unit) },
            onDrop: { [weak self] in self?.finished() })
        // For HiDPI displays ScreenCaptureKit downsamples the 2x backing store
        // to the client's pixels, just like a scaled Retina mode.
        capture = DisplayCapture(
            displayID: monitor.displayID, pixelWidth: spec.width, pixelHeight: spec.height,
            onFrame: { [weak self] frame in self?.captured(frame.pixelBuffer) },
            onStop: { error in
                if let error { log("capture of monitor \(index + 1) stopped: \(error.localizedDescription)") }
            })
    }

    func start() async throws {
        try await capture?.start()
    }

    func stop() async {
        await capture?.stop()
        lock.withLock {
            pending = nil
            latest = nil
        }
    }

    /// Called when the client acknowledges frames.
    func pump() {
        let next: CVPixelBuffer? = lock.withLock {
            guard !busy, let frame = pending, link.hasCredit else { return nil }
            busy = true
            pending = nil
            return frame
        }
        guard let next, let encoder else { return }
        encoder.encode(next, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Client lost its picture: send a keyframe of what is on screen now.
    func refresh() {
        encoder?.requestKeyframe()
        lock.withLock {
            if pending == nil { pending = latest }
        }
        pump()
    }

    private func captured(_ buffer: CVPixelBuffer) {
        lock.withLock {
            latest = buffer
            pending = buffer
        }
        pump()
    }

    private func encoded(_ unit: H264Encoder.AccessUnit) {
        link.send(frame: unit.data, monitor: index, generation: generation)
        finished()
    }

    private func finished() {
        lock.withLock { busy = false }
        pump()
    }
}
