import CoreMedia
import CoreVideo
import Foundation
import MacRDPKit

/// One newest waiting capture per monitor. StreamSet serializes submissions;
/// SessionLink reserves frame and byte credits before work enters the encoder.
final class MonitorStream: @unchecked Sendable {
    let index: Int
    private let generation: UInt32
    private let link: SessionLink
    private let pixels: Int
    private let lock = NSLock()
    private let encodingLock = NSLock()
    private var encoder: H264Encoder?
    private var capture: DisplayCapture?
    private var stopped = false
    private var busy = false
    private var budget: SessionLink.VideoBudget?
    private var nextSubmission = 0.0
    private var encodeStarted = 0.0
    private var appliedBitrate = 0
    private var appliedFrameRate = 0
    private var pending: Picture?
    private var latest: Picture?
    private var capturedCount = 0, replacedCount = 0, encodedCount = 0
    private var encodeMS = 0.0, waitMS = 0.0
    private var lastStats = ProcessInfo.processInfo.systemUptime

    private struct Picture {
        let buffer: CVPixelBuffer
        let received: Double
    }

    init(index: Int, monitor: VirtualMonitor, spec: MonitorSpec, generation: UInt32, link: SessionLink,
         profile: H264Encoder.Settings.Profile) throws {
        self.index = index
        self.generation = generation
        self.link = link
        pixels = spec.width * spec.height
        var settings = H264Encoder.Settings()
        settings.profile = profile
        settings.bitrate = VideoPacing().bitrate(pixels: pixels, monitors: 1)
        encoder = try H264Encoder(
            width: spec.width, height: spec.height, settings: settings,
            output: { [weak self] unit in self?.completed(unit) },
            onDrop: { [weak self] in self?.completed(nil) })
        capture = DisplayCapture(
            displayID: monitor.displayID, pixelWidth: spec.width, pixelHeight: spec.height,
            onFrame: { [weak self] frame in self?.captured(frame.pixelBuffer) },
            onStop: { error in
                if let error { log("capture of monitor \(index + 1) stopped: \(error.localizedDescription)") }
            })
    }

    func start(displays: DisplayCapture.Displays) async throws {
        try await capture?.start(displays: displays)
    }

    func stop() async {
        lock.withLock {
            stopped = true
            pending = nil
            latest = nil
        }
        await capture?.stop()
        // Drain on the video queue before HostSession releases the stream,
        // ensuring every reservation is returned even during a layout change.
        let encoder = self.encoder
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.encodingLock.withLock { encoder?.flush() }
                continuation.resume()
            }
        }
    }

    /// Called only by StreamSet's serial video queue, never on the RDP thread.
    func pump() {
        encodingLock.lock()
        defer { encodingLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let work: (Picture, SessionLink.VideoBudget)? = lock.withLock {
            if now - lastStats >= 5 {
                if capturedCount > 0 || encodedCount > 0 {
                    let count = Double(max(1, encodedCount))
                    log("monitor \(index + 1): \(capturedCount) captured, \(encodedCount) encoded, "
                        + "\(replacedCount) superseded, encode \(Int(encodeMS / count)) ms, "
                        + "waiting \(Int(waitMS / count)) ms")
                }
                capturedCount = 0; encodedCount = 0; replacedCount = 0
                encodeMS = 0; waitMS = 0; lastStats = now
            }
            guard !stopped, !busy, now >= nextSubmission, let picture = pending,
                  let reserved = link.reserveVideo(pixels: pixels) else { return nil }
            busy = true
            budget = reserved
            pending = nil
            encodeStarted = now
            waitMS += max(0, now - picture.received) * 1000
            let interval = 1 / Double(reserved.frameRate)
            nextSubmission = now - nextSubmission > interval ? now + interval : nextSubmission + interval
            return (picture, reserved)
        }
        guard let (picture, reserved) = work, let encoder else { return }
        if reserved.bitrate != appliedBitrate || reserved.frameRate != appliedFrameRate {
            if encoder.setBitrate(reserved.bitrate, frameRate: reserved.frameRate) {
                appliedBitrate = reserved.bitrate
                appliedFrameRate = reserved.frameRate
            }
        }
        encoder.encode(picture.buffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func refresh() {
        encoder?.requestKeyframe()
        lock.withLock {
            guard !stopped else { return }
            if pending == nil, let latest {
                pending = Picture(buffer: latest.buffer, received: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func captured(_ buffer: CVPixelBuffer) {
        lock.withLock {
            guard !stopped else { return }
            capturedCount += 1
            if pending != nil { replacedCount += 1 }
            let picture = Picture(buffer: buffer, received: ProcessInfo.processInfo.systemUptime)
            latest = picture
            pending = picture
        }
    }

    private func completed(_ unit: H264Encoder.AccessUnit?) {
        let completion: (SessionLink.VideoBudget, Bool)? = lock.withLock {
            guard let budget else { return nil }
            self.budget = nil
            if unit != nil {
                encodedCount += 1
                encodeMS += (ProcessInfo.processInfo.systemUptime - encodeStarted) * 1000
            }
            return (budget, !stopped)
        }
        guard let (budget, active) = completion else { return }
        if active, let unit {
            if !link.send(frame: unit.data, monitor: index, generation: generation, budget: budget) {
                encoder?.requestKeyframe()
            }
        } else {
            link.cancelVideo(budget)
        }
        lock.withLock { busy = false }
    }
}
