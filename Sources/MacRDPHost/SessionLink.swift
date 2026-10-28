import CRDPServer
import Foundation
import MacRDPKit

func log(_ message: String) {
    let stamp = Date.now.formatted(Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        timeZone: .current, calendar: .current))
    FileHandle.standardError.write(Data("\(stamp) [host] \(message)\n".utf8))
}

/// The Swift side's handle on one C session. The C session is freed right
/// after `session_ended`, so every call goes through `lock` and becomes a
/// no-op once `detach()` has run.
final class SessionLink: @unchecked Sendable {
    /// Identifies the C session in callbacks, which pass its address.
    let id: Int
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var monitorCount = 1
    private var pacing = VideoPacing()
    private var reservations: [UUID: Int] = [:]
    private var lastPacingLog = 0.0

    struct VideoBudget: Sendable {
        let id: UUID
        let bitrate: Int
        let frameRate: Int
    }

    init(_ handle: OpaquePointer) {
        id = Int(bitPattern: handle)
        self.handle = handle
    }

    func detach() {
        lock.withLock { handle = nil }
    }

    func setVideoQuality(_ quality: VideoQuality) {
        lock.withLock {
            pacing.preset = quality
            lastPacingLog = 0
        }
    }

    /// Reserve credit before encoding, so concurrent monitors cannot all
    /// spend the same slot. Already encoded reference frames are never dropped.
    func reserveVideo(pixels: Int) -> VideoBudget? {
        lock.withLock {
            guard let handle else { return nil }
            var state = mrs_video_state()
            mrs_session_get_video_state(handle, &state)
            let now = ProcessInfo.processInfo.systemUptime
            let bitrate = pacing.bitrate(pixels: pixels, monitors: monitorCount)
            let aggregate = min(pacing.preset.sessionBitrateLimit, bitrate * monitorCount)
            let byteLimit = pacing.byteLimit(monitors: monitorCount, baselineMS: state.baseline_ms,
                                             aggregateBitrate: aggregate, now: now)
            let bytes = Int(state.bytes) + reservations.values.reduce(0, +)
            pacing.update(now: now, baselineMS: state.baseline_ms, delayMS: state.delay_ms,
                          bytesInFlight: Int(state.bytes), byteLimit: byteLimit,
                          acknowledgements: state.acknowledgements)
            let limit = FrameWindow.limit(monitors: monitorCount, aloneDelay: .milliseconds(state.baseline_ms),
                                          delay: .milliseconds(state.delay_ms), frameRate: pacing.frameRate)
            if now - lastPacingLog >= 5 {
                lastPacingLog = now
                log("pacing: \(pacing.preset.rawValue), target \(pacing.frameRate) fps/monitor, quality \(Int(pacing.quality * 100))%, "
                    + "\(bytes)/\(byteLimit) video bytes outstanding, \(limit) frame slots")
            }
            guard Int(state.frames) + reservations.count < limit, bytes < byteLimit else { return nil }
            let budget = VideoBudget(id: UUID(), bitrate: pacing.bitrate(pixels: pixels, monitors: monitorCount),
                                     frameRate: pacing.frameRate)
            reservations[budget.id] = max(1, budget.bitrate / budget.frameRate / 8)
            return budget
        }
    }

    func cancelVideo(_ budget: VideoBudget) {
        lock.withLock { _ = reservations.removeValue(forKey: budget.id) }
    }

    func send(frame: Data, monitor index: Int, generation: UInt32, budget: VideoBudget) -> Bool {
        lock.withLock {
            guard reservations.removeValue(forKey: budget.id) != nil, let handle else { return false }
            let sent = frame.withUnsafeBytes { raw in
                mrs_session_send_h264(handle, generation, UInt32(index),
                                     raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            } == 0
            if sent { pacing.recordFrame(bytes: frame.count, now: ProcessInfo.processInfo.systemUptime) }
            return sent
        }
    }

    func setPointer(_ cursor: CursorImage?) {
        lock.withLock {
            guard let handle else { return }
            guard let cursor else {
                mrs_session_set_pointer(handle, nil, 0, 0, 0, 0)
                return
            }
            _ = cursor.bgra.withUnsafeBytes { raw in
                mrs_session_set_pointer(handle, raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                       UInt32(cursor.width), UInt32(cursor.height),
                                       UInt32(cursor.hotX), UInt32(cursor.hotY))
            }
        }
    }

    func resetLayout(_ layout: MonitorLayout, generation: UInt32) {
        let monitors = layout.monitors.map(mrs_monitor.init)
        lock.withLock {
            guard let handle else { return }
            monitorCount = layout.monitors.count
            _ = monitors.withUnsafeBufferPointer {
                mrs_session_reset_layout(handle, generation, $0.baseAddress, UInt32($0.count))
            }
        }
    }

    func setMonitorCount(_ count: Int) {
        lock.withLock { monitorCount = count }
    }

    func sendWebAuthn(_ message: Data) {
        lock.withLock {
            guard let handle else { return }
            _ = message.withUnsafeBytes { raw in
                mrs_session_webauthn_send(handle, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            }
        }
    }

    func clipboardOffer(_ formats: [(id: UInt32, name: String?)]) {
        lock.withLock {
            guard let handle else { return }
            let names = formats.map { $0.name.flatMap { strdup($0) } }
            defer { names.forEach { free($0) } }
            let list = zip(formats, names).map { mrs_clip_format(id: $0.0.id, name: UnsafePointer($0.1)) }
            _ = list.withUnsafeBufferPointer {
                mrs_session_clipboard_offer(handle, $0.baseAddress, UInt32($0.count))
            }
        }
    }

    /// False once the session is gone.
    func clipboardFetch(_ id: UInt32) -> Bool {
        lock.withLock {
            guard let handle else { return false }
            return mrs_session_clipboard_fetch(handle, id) == 0
        }
    }

    /// Answers Windows' paste; nil reports that the Mac clipboard couldn't provide it.
    func clipboardSend(_ data: Data?) {
        lock.withLock {
            guard let handle else { return }
            guard let data else {
                mrs_session_clipboard_send(handle, nil, 0)
                return
            }
            _ = data.withUnsafeBytes { raw in
                mrs_session_clipboard_send(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
            }
        }
    }

    func close() {
        lock.withLock {
            guard let handle else { return }
            mrs_session_close(handle)
        }
    }
}

extension mrs_monitor {
    init(_ spec: MonitorSpec) {
        self.init(x: Int32(spec.x), y: Int32(spec.y), width: UInt32(spec.width), height: UInt32(spec.height),
                  is_primary: spec.isPrimary ? 1 : 0, scale_percent: UInt32(spec.scalePercent))
    }
}

extension MonitorSpec {
    init(_ m: mrs_monitor) {
        self.init(x: Int(m.x), y: Int(m.y), width: Int(m.width), height: Int(m.height),
                  isPrimary: m.is_primary != 0, scalePercent: Int(m.scale_percent))
    }
}
