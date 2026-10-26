import CRDPServer
import Foundation
import MacRDPConnectKit

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
    private var maxInFlight: UInt32 = 3

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
            return mrc_session_frames_in_flight(handle) < maxInFlight
        }
    }

    func send(frame: Data, monitor index: Int, generation: UInt32) {
        lock.withLock {
            guard let handle else { return }
            _ = frame.withUnsafeBytes { raw in
                mrc_session_send_h264(handle, generation, UInt32(index),
                                     raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
            }
        }
    }

    func setPointer(_ cursor: CursorImage?) {
        lock.withLock {
            guard let handle else { return }
            guard let cursor else {
                mrc_session_set_pointer(handle, nil, 0, 0, 0, 0)
                return
            }
            _ = cursor.bgra.withUnsafeBytes { raw in
                mrc_session_set_pointer(handle, raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                       UInt32(cursor.width), UInt32(cursor.height),
                                       UInt32(cursor.hotX), UInt32(cursor.hotY))
            }
        }
    }

    func resetLayout(_ layout: MonitorLayout, generation: UInt32) {
        let monitors = layout.monitors.map(mrc_monitor.init)
        lock.withLock {
            guard let handle else { return }
            // A frame per monitor in flight plus a little slack keeps latency to ~1 frame.
            maxInFlight = UInt32(layout.monitors.count + 2)
            _ = monitors.withUnsafeBufferPointer {
                mrc_session_reset_layout(handle, generation, $0.baseAddress, UInt32($0.count))
            }
        }
    }

    func setMonitorCount(_ count: Int) {
        lock.withLock { maxInFlight = UInt32(count + 2) }
    }

    func close() {
        lock.withLock {
            guard let handle else { return }
            mrc_session_close(handle)
        }
    }
}

extension mrc_monitor {
    init(_ spec: MonitorSpec) {
        self.init(x: Int32(spec.x), y: Int32(spec.y), width: UInt32(spec.width), height: UInt32(spec.height),
                  is_primary: spec.isPrimary ? 1 : 0, scale_percent: UInt32(spec.scalePercent))
    }
}

extension MonitorSpec {
    init(_ m: mrc_monitor) {
        self.init(x: Int(m.x), y: Int(m.y), width: Int(m.width), height: Int(m.height),
                  isPrimary: m.is_primary != 0, scalePercent: Int(m.scale_percent))
    }
}
