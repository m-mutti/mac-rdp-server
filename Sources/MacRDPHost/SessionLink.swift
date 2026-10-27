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

    init(_ handle: OpaquePointer) {
        id = Int(bitPattern: handle)
        self.handle = handle
    }

    func detach() {
        lock.withLock { handle = nil }
    }

    /// Room for another frame without building latency.
    var hasCredit: Bool {
        lock.withLock {
            guard let handle else { return false }
            var alone = 0.0, all = 0.0
            mrs_session_ack_delay(handle, &alone, &all)
            let limit = FrameWindow.limit(monitors: monitorCount, aloneDelay: .milliseconds(alone),
                                          delay: .milliseconds(all))
            return mrs_session_frames_in_flight(handle) < limit
        }
    }

    func send(frame: Data, monitor index: Int, generation: UInt32) {
        lock.withLock {
            guard let handle else { return }
            _ = frame.withUnsafeBytes { raw in
                mrs_session_send_h264(handle, generation, UInt32(index),
                                     raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            }
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
